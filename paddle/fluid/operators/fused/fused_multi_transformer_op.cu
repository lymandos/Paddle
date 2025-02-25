/* Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
 * Copyright (c) 2011-2021, NVIDIA CORPORATION.  All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */
// This file has been adapted from FasterTransformer file:
// https://github.com/NVIDIA/FasterTransformer/blob/v4.0/fastertransformer/cuda/masked_multihead_attention.cu
// We add License in the head.

#include <cuda_fp16.h>
#include <float.h>
#include <cub/cub.cuh>
#include "paddle/fluid/framework/op_registry.h"
#include "paddle/fluid/framework/operator.h"
#include "paddle/fluid/platform/device/gpu/gpu_device_function.h"
#include "paddle/fluid/platform/device/gpu/gpu_dnn.h"

#include "paddle/fluid/operators/elementwise/elementwise_add_op.h"
#include "paddle/phi/kernels/funcs/math_function.h"

#include "paddle/fluid/operators/fused/attention_layer_norm.h"
#include "paddle/fluid/operators/fused/attn_gemm.h"
#include "paddle/fluid/operators/fused/fmha_ref.h"
#include "paddle/fluid/operators/fused/fused_dropout_helper.h"

#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
#include "paddle/fluid/platform/collective_helper.h"
#include "paddle/fluid/platform/device/gpu/nccl_helper.h"
#endif

namespace paddle {
namespace operators {

using Tensor = framework::Tensor;

// for debug
// #define _DEBUG_FUSED_MULTI_TRANSFORMER

template <typename T>
static void AllReduce(framework::Tensor &tensor,  // NOLINT
                      const int ring_id,
                      const platform::CUDADeviceContext &ctx) {
  if (ring_id == -1) return;
#if defined(PADDLE_WITH_NCCL) || defined(PADDLE_WITH_RCCL)
  auto dtype =
      platform::ToNCCLDataType(framework::TransToProtoVarType(tensor.dtype()));
  int64_t numel = tensor.numel();
  const void *sendbuff = tensor.data<T>();
  auto place = ctx.GetPlace();
  void *recvbuff = tensor.mutable_data<T>(place);
  auto comm = platform::NCCLCommContext::Instance().Get(ring_id, place);
  auto stream = ctx.stream();
  PADDLE_ENFORCE_GPU_SUCCESS(platform::dynload::ncclAllReduce(
      sendbuff, recvbuff, numel, dtype, ncclSum, comm->comm(), stream));
#else
  PADDLE_THROW(platform::errors::Unimplemented(
      "PaddlePaddle should compile with NCCL or RCCL when used tensor model "
      "parallel op."));
#endif
}

namespace {

namespace plat = paddle::platform;
using float16 = plat::float16;

#define MMHA_USE_FP32_ACUM_FOR_LOGITS
#define MMHA_USE_FP32_ACUM_FOR_OUT

template <typename T>
struct Masked_multihead_attention_params {
  // output buffer, [B, 1(seq_len), num_head * dim_head]
  T *out;
  // qkv_out, [B, 1(seq_len), 3, num_head * dim_head]
  const T *qkv;
  // bias, [3, num_head, dim_head]
  const T *qkv_bias;
  // TODO(wangxi): optimize with input_lengths and max_input_len?
  // [bsz, 1, 1, time_step(cache_seq_length)+1]
  const T *attn_mask;

  // [2, B, num_head, max_seq_len(valid cache_seq_len), dim_head]
  // k [B, num_head, dim_head/x, max_seq_len, x], that is `seq_len` first
  // v [B, num_head, max_seq_len, dim_head]
  T *cache_kv;

  int batch_size;
  int num_head;
  int timestep;  // cache_seq_length
  int max_seq_length;

  // 1.f / sqrt(Dh)
  float inv_sqrt_dh;
};

struct Float8_ {
  float2 x;
  float2 y;
  float2 z;
  float2 w;
};

// clang-format off

template <typename T, int Dh> struct Qk_vec_ {};
template <> struct Qk_vec_<float,    32> { using Type = float;    };
template <> struct Qk_vec_<float,    64> { using Type = float2;   };
template <> struct Qk_vec_<float,   128> { using Type = float4;   };
template <> struct Qk_vec_<float16,  32> { using Type = uint32_t; };
template <> struct Qk_vec_<float16,  64> { using Type = uint32_t; };
template <> struct Qk_vec_<float16, 128> { using Type = uint2;    };

template <typename T, int THREADS_PER_KEY> struct K_vec_ {};
template <> struct K_vec_<float,   4> { using Type = float;    };
template <> struct K_vec_<float,   2> { using Type = float2;   };
template <> struct K_vec_<float,   1> { using Type = float4;   };
template <> struct K_vec_<float16, 4> { using Type = uint32_t; };
template <> struct K_vec_<float16, 2> { using Type = uint2;    };
template <> struct K_vec_<float16, 1> { using Type = uint4;    };

template <typename T, int V_VEC_SIZE> struct V_vec_ {};
template <> struct V_vec_<float,   1> { using Type = float;    };
template <> struct V_vec_<float,   2> { using Type = float2;   };
template <> struct V_vec_<float,   4> { using Type = float4;   };
template <> struct V_vec_<float16, 2> { using Type = uint32_t; };
template <> struct V_vec_<float16, 4> { using Type = uint2;    };
template <> struct V_vec_<float16, 8> { using Type = uint4;    };

#ifdef MMHA_USE_FP32_ACUM_FOR_OUT
template <typename T> struct V_vec_acum_fp32_ {};
// template <> struct V_vec_acum_fp32_<float>  { using Type = float;  };
// template <> struct V_vec_acum_fp32_<float2> { using Type = float2; };
template <> struct V_vec_acum_fp32_<float4> { using Type = float4; };
// template <> struct V_vec_acum_fp32_<uint32_t> { using Type = float2;   };
// template <> struct V_vec_acum_fp32_<uint2   > { using Type = Float4_;  };
template <> struct V_vec_acum_fp32_<uint4> { using Type = Float8_; };
#endif

// clang-format on

inline __device__ float half_to_float(uint16_t h) {
  float f;
  asm volatile("cvt.f32.f16 %0, %1;\n" : "=f"(f) : "h"(h));
  return f;
}

inline __device__ float2 half2_to_float2(uint32_t v) {
  uint16_t lo, hi;
  asm volatile("mov.b32 {%0, %1}, %2;\n" : "=h"(lo), "=h"(hi) : "r"(v));
  return make_float2(half_to_float(lo), half_to_float(hi));
}

inline __device__ uint32_t float2_to_half2(float2 f) {
  union {
    uint32_t u32;
    uint16_t u16[2];
  } tmp;
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 800
  asm volatile("cvt.rn.f16x2.f32 %0, %1, %2;\n"
               : "=r"(tmp.u32)
               : "f"(f.y), "f"(f.x));
#else
  asm volatile("cvt.rn.f16.f32 %0, %1;\n" : "=h"(tmp.u16[0]) : "f"(f.x));
  asm volatile("cvt.rn.f16.f32 %0, %1;\n" : "=h"(tmp.u16[1]) : "f"(f.y));
#endif
  return tmp.u32;
}

inline __device__ float add(float a, float b) { return a + b; }

inline __device__ float2 add(float2 a, float2 b) {
  float2 c;
  c.x = add(a.x, b.x);
  c.y = add(a.y, b.y);
  return c;
}

inline __device__ float4 add(float4 a, float4 b) {
  float4 c;
  c.x = add(a.x, b.x);
  c.y = add(a.y, b.y);
  c.z = add(a.z, b.z);
  c.w = add(a.w, b.w);
  return c;
}

inline __device__ uint16_t add(uint16_t a, uint16_t b) {
  uint16_t c;
  asm volatile("add.f16 %0, %1, %2;\n" : "=h"(c) : "h"(a), "h"(b));
  return c;
}

inline __device__ uint32_t add(uint32_t a, uint32_t b) {
  uint32_t c;
  asm volatile("add.f16x2 %0, %1, %2;\n" : "=r"(c) : "r"(a), "r"(b));
  return c;
}

inline __device__ uint2 add(uint2 a, uint2 b) {
  uint2 c;
  c.x = add(a.x, b.x);
  c.y = add(a.y, b.y);
  return c;
}

inline __device__ uint4 add(uint4 a, uint4 b) {
  uint4 c;
  c.x = add(a.x, b.x);
  c.y = add(a.y, b.y);
  c.z = add(a.z, b.z);
  c.w = add(a.w, b.w);
  return c;
}

inline __device__ float2 add(uint32_t a, float2 fb) {
  float2 fa = half2_to_float2(a);
  return add(fa, fb);
}

inline __device__ Float8_ add(uint4 a, Float8_ fb) {
  Float8_ fc;
  fc.x = add(a.x, fb.x);
  fc.y = add(a.y, fb.y);
  fc.z = add(a.z, fb.z);
  fc.w = add(a.w, fb.w);
  return fc;
}

template <typename Acc, typename A, typename B>
inline __device__ Acc mul(A a, B b);

template <>
inline __device__ float mul<float, float>(float a, float b) {
  return a * b;
}

template <>
inline __device__ float2 mul(float2 a, float2 b) {
  float2 c;
  c.x = a.x * b.x;
  c.y = a.y * b.y;
  return c;
}

template <>
inline __device__ float4 mul(float4 a, float4 b) {
  float4 c;
  c.x = a.x * b.x;
  c.y = a.y * b.y;
  c.z = a.z * b.z;
  c.w = a.w * b.w;
  return c;
}

template <>
inline __device__ uint16_t mul(uint16_t a, uint16_t b) {
  uint16_t c;
  asm volatile("mul.f16 %0, %1, %2;\n" : "=h"(c) : "h"(a), "h"(b));
  return c;
}

template <>
inline __device__ uint32_t mul(uint32_t a, uint32_t b) {
  uint32_t c;
  asm volatile("mul.f16x2 %0, %1, %2;\n" : "=r"(c) : "r"(a), "r"(b));
  return c;
}

template <>
inline __device__ uint2 mul(uint2 a, uint2 b) {
  uint2 c;
  c.x = mul<uint32_t, uint32_t, uint32_t>(a.x, b.x);
  c.y = mul<uint32_t, uint32_t, uint32_t>(a.y, b.y);
  return c;
}

template <>
inline __device__ uint4 mul(uint4 a, uint4 b) {
  uint4 c;
  c.x = mul<uint32_t, uint32_t, uint32_t>(a.x, b.x);
  c.y = mul<uint32_t, uint32_t, uint32_t>(a.y, b.y);
  c.z = mul<uint32_t, uint32_t, uint32_t>(a.z, b.z);
  c.w = mul<uint32_t, uint32_t, uint32_t>(a.w, b.w);
  return c;
}

inline __device__ float sum(float v) { return v; }
inline __device__ float sum(float2 v) { return v.x + v.y; }
inline __device__ float sum(float4 v) { return v.x + v.y + v.z + v.w; }
inline __device__ float sum(uint16_t v) { return half_to_float(v); }
inline __device__ float sum(uint32_t v) {
  float2 tmp = half2_to_float2(v);
  return tmp.x + tmp.y;
}

inline __device__ float sum(uint2 v) {
  uint32_t c = add(v.x, v.y);
  return sum(c);
}

inline __device__ float sum(uint4 v) {
  uint32_t c = add(v.x, v.y);
  c = add(c, v.z);
  c = add(c, v.w);
  return sum(c);
}

template <typename T>
inline __device__ float dot(T a, T b) {
  return sum(mul<T, T, T>(a, b));
}

template <typename A, typename T>
inline __device__ float dot(T a, T b) {
  return sum(mul<A, T, T>(a, b));
}

inline __device__ constexpr uint32_t shfl_mask(int threads) {
  return threads == 32 ? uint32_t(-1) : (1u << threads) - 1u;
}

template <typename T>
inline __device__ __host__ T div_up(T m, T n) {
  return (m + n - 1) / n;
}

inline __device__ float fma(float a, float b, float c) { return a * b + c; }

inline __device__ float2 fma(float2 a, float2 b, float2 c) {
  float2 d;
  d.x = fma(a.x, b.x, c.x);
  d.y = fma(a.y, b.y, c.y);
  return d;
}

inline __device__ float4 fma(float4 a, float4 b, float4 c) {
  float4 d;
  d.x = fma(a.x, b.x, c.x);
  d.y = fma(a.y, b.y, c.y);
  d.z = fma(a.z, b.z, c.z);
  d.w = fma(a.w, b.w, c.w);
  return d;
}

inline __device__ uint32_t fma(uint32_t a, uint32_t b, uint32_t c) {
  uint32_t d;
  asm volatile("fma.rn.f16x2 %0, %1, %2, %3;\n"
               : "=r"(d)
               : "r"(a), "r"(b), "r"(c));
  return d;
}

inline __device__ uint2 fma(uint2 a, uint2 b, uint2 c) {
  uint2 d;
  d.x = fma(a.x, b.x, c.x);
  d.y = fma(a.y, b.y, c.y);
  return d;
}

inline __device__ uint4 fma(uint4 a, uint4 b, uint4 c) {
  uint4 d;
  d.x = fma(a.x, b.x, c.x);
  d.y = fma(a.y, b.y, c.y);
  d.z = fma(a.z, b.z, c.z);
  d.w = fma(a.w, b.w, c.w);
  return d;
}

inline __device__ float2 fma(float a, float2 b, float2 c) {
  float2 d;
  d.x = fma(a, b.x, c.x);
  d.y = fma(a, b.y, c.y);
  return d;
}

inline __device__ float4 fma(float a, float4 b, float4 c) {
  float4 d;
  d.x = fma(a, b.x, c.x);
  d.y = fma(a, b.y, c.y);
  d.z = fma(a, b.z, c.z);
  d.w = fma(a, b.w, c.w);
  return d;
}

inline __device__ Float8_ fma(float a, Float8_ b, Float8_ c) {
  Float8_ d;
  d.x = fma(a, b.x, c.x);
  d.y = fma(a, b.y, c.y);
  d.z = fma(a, b.z, c.z);
  d.w = fma(a, b.w, c.w);
  return d;
}

inline __device__ uint32_t h0_h0(uint16_t a) {
  uint32_t b;
  asm volatile("mov.b32 %0, {%1, %1};" : "=r"(b) : "h"(a));
  return b;
}

inline __device__ uint32_t fma(uint16_t a, uint32_t b, uint32_t c) {
  return fma(h0_h0(a), b, c);
}

inline __device__ uint2 fma(uint16_t a, uint2 b, uint2 c) {
  uint32_t s = h0_h0(a);
  uint2 d;
  d.x = fma(s, b.x, c.x);
  d.y = fma(s, b.y, c.y);
  return d;
}

inline __device__ uint4 fma(uint16_t a, uint4 b, uint4 c) {
  uint32_t s = h0_h0(a);
  uint4 d;
  d.x = fma(s, b.x, c.x);
  d.y = fma(s, b.y, c.y);
  d.z = fma(s, b.z, c.z);
  d.w = fma(s, b.w, c.w);
  return d;
}

inline __device__ float cast_to_float(float u) { return u; }

inline __device__ float2 cast_to_float(float2 u) { return u; }

inline __device__ float4 cast_to_float(float4 u) { return u; }

inline __device__ Float8_ cast_to_float(uint4 u) {
  Float8_ tmp;
  tmp.x = half2_to_float2(u.x);
  tmp.y = half2_to_float2(u.y);
  tmp.z = half2_to_float2(u.z);
  tmp.w = half2_to_float2(u.w);
  return tmp;
}

template <int THREADS_PER_KEY, typename K_vec, int N>
inline __device__ float qk_dot_(const K_vec (&q)[N], const K_vec (&k)[N]) {
  K_vec qk_vec = mul<K_vec, K_vec, K_vec>(q[0], k[0]);
#pragma unroll
  for (int ii = 1; ii < N; ++ii) {
    qk_vec = fma(q[ii], k[ii], qk_vec);
  }

  float qk = sum(qk_vec);
#pragma unroll
  for (int mask = THREADS_PER_KEY / 2; mask >= 1; mask /= 2) {
    qk += __shfl_xor_sync(uint32_t(-1), qk, mask);
  }
  return qk;
}

template <typename T, int THREADS_PER_KEY>
struct Qk_dot {
  template <typename K_vec, int N>
  static inline __device__ float dot(const K_vec (&q)[N], const K_vec (&k)[N]) {
    return qk_dot_<THREADS_PER_KEY>(q, k);
  }
};

template <int WARPS_PER_BLOCK, int WARP_SIZE = 32>
inline __device__ float block_sum(float *red_smem, float sum) {
  int warp = threadIdx.x / WARP_SIZE;
  int lane = threadIdx.x % WARP_SIZE;

#pragma unroll
  for (int mask = WARP_SIZE / 2; mask >= 1; mask /= 2) {
    sum += __shfl_xor_sync(uint32_t(-1), sum, mask);
  }

  if (lane == 0) {
    red_smem[warp] = sum;
  }
  __syncthreads();

  if (lane < WARPS_PER_BLOCK) {
    sum = red_smem[lane];
  }

#pragma unroll
  for (int mask = WARPS_PER_BLOCK / 2; mask >= 1; mask /= 2) {
    sum += __shfl_xor_sync(uint32_t(-1), sum, mask);
  }

  return __shfl_sync(uint32_t(-1), sum, 0);
}

inline __device__ void convert_from_float(float &dst, float src) {  // NOLINT
  dst = src;
}

inline __device__ void convert_from_float(float4 &dst, float4 src) {  // NOLINT
  dst = src;
}

inline __device__ void convert_from_float(plat::float16 &dst,  // NOLINT
                                          float src) {
  dst = static_cast<plat::float16>(src);
}

inline __device__ void convert_from_float(uint4 &dst, Float8_ src) {  // NOLINT
  dst.x = float2_to_half2(src.x);
  dst.y = float2_to_half2(src.y);
  dst.z = float2_to_half2(src.z);
  dst.w = float2_to_half2(src.w);
}

inline __device__ void zero(uint16_t &dst) { dst = uint16_t(0); }  // NOLINT

template <typename T>
inline __device__ void zero(T &dst) {  // NOLINT
  constexpr int WORDS = sizeof(T) / 4;
  union {
    T raw;
    uint32_t words[WORDS];
  } tmp;
#pragma unroll
  for (int ii = 0; ii < WORDS; ++ii) {
    tmp.words[ii] = 0u;
  }
  dst = tmp.raw;
}

template <typename T, int Dh, int THREADS_PER_KEY, int THREADS_PER_VALUE,
          int THREADS_PER_BLOCK>
__global__ void masked_multihead_attention_kernel(
    Masked_multihead_attention_params<T> params) {
  static_assert(Dh % THREADS_PER_KEY == 0, "");
  static_assert(Dh % THREADS_PER_VALUE == 0, "");

  constexpr int WARP_SIZE = 32;
  constexpr int WARPS_PER_BLOCK = THREADS_PER_BLOCK / WARP_SIZE;

  extern __shared__ char smem_[];

  float *qk_smem = reinterpret_cast<float *>(smem_);

  char *logits_smem_ = smem_;
  // fp32 accum for logits
  float *logits_smem = reinterpret_cast<float *>(logits_smem_);

  T *out_smem = reinterpret_cast<T *>(smem_);

  __shared__ float red_smem[WARPS_PER_BLOCK * 2];
  __shared__ T q_smem[Dh];

  const int bi = blockIdx.y;
  const int hi = blockIdx.x;
  const int bhi = bi * params.num_head + hi;
  const int tid = threadIdx.x;

  float qk_max = -FLT_MAX;

  // qkv [B, S=1, 3, num_head, head_dim]
  int qkv_base_offset = bi * 3 * params.num_head * Dh + hi * Dh;

  using Qk_vec = typename Qk_vec_<T, Dh>::Type;
  constexpr int QK_VEC_SIZE = sizeof(Qk_vec) / sizeof(T);
  static_assert(Dh % QK_VEC_SIZE == 0 && Dh / QK_VEC_SIZE <= WARP_SIZE, "");
  constexpr int QK_VECS_PER_WARP = Dh / QK_VEC_SIZE;

  // cache_k, [B, num_head, head_dim / x, max_seq_len, x]
  // x == 4/8 for FP32/FP16, 128bit, 16Byte
  constexpr int QK_ELTS_IN_16B = 16 / sizeof(T);
  constexpr int QK_VECS_IN_16B = 16 / sizeof(Qk_vec);

  const T *q_base = params.qkv;
  const T *k_base = params.qkv + params.num_head * Dh;
  const T *q_bias_base = params.qkv_bias;
  const T *k_bias_base = params.qkv_bias + params.num_head * Dh;

  if (tid < QK_VECS_PER_WARP) {
    int qk_offset = qkv_base_offset + tid * QK_VEC_SIZE;
    int qk_bias_offset = hi * Dh + tid * QK_VEC_SIZE;

    Qk_vec q = *reinterpret_cast<const Qk_vec *>(&q_base[qk_offset]);
    Qk_vec k = *reinterpret_cast<const Qk_vec *>(&k_base[qk_offset]);

    Qk_vec q_bias =
        *reinterpret_cast<const Qk_vec *>(&q_bias_base[qk_bias_offset]);
    Qk_vec k_bias =
        *reinterpret_cast<const Qk_vec *>(&k_bias_base[qk_bias_offset]);

    q = add(q, q_bias);
    // TODO(wangxi): See this https://github.com/microsoft/unilm/issues/510
    //   we may not require k_bias.
    k = add(k, k_bias);

    *reinterpret_cast<Qk_vec *>(&q_smem[tid * QK_VEC_SIZE]) = q;

    int co = tid / QK_VECS_IN_16B;
    int ci = (tid % QK_VECS_IN_16B) * QK_VEC_SIZE;
    int offset = bhi * params.max_seq_length * Dh +
                 co * params.max_seq_length * QK_ELTS_IN_16B +
                 params.timestep * QK_ELTS_IN_16B + ci;
    *reinterpret_cast<Qk_vec *>(&params.cache_kv[offset]) = k;

    float qk = dot<Qk_vec, Qk_vec>(q, k);
#pragma unroll
    for (int mask = QK_VECS_PER_WARP / 2; mask >= 1; mask /= 2) {
      qk += __shfl_xor_sync(shfl_mask(QK_VECS_PER_WARP), qk, mask);
    }

    qk *= params.inv_sqrt_dh;
    if (tid == 0) {
      // NOTE(wangxi): mask must be 0.0
      // T mask = params.attn_mask[
      //    bi * (params.timestep + 1) + params.timestep];
      // qk += static_cast<float>(mask);
      qk_max = qk;
      qk_smem[params.timestep] = qk;
    }
  }
  __syncthreads();

#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
  if (bi == 0 && hi == 0 && tid == 0) {
    printf("=======q_out=======\n");
    for (int i = 0; i < Dh; ++i) printf("%f ", static_cast<float>(q_smem[i]));
    printf("\n");
  }
  __syncthreads();
#endif

  using K_vec = typename K_vec_<T, THREADS_PER_KEY>::Type;
  constexpr int K_VEC_SIZE = sizeof(K_vec) / sizeof(T);
  static_assert(Dh % K_VEC_SIZE == 0, "");
  constexpr int K_ELTS_PER_THREAD = Dh / THREADS_PER_KEY;
  constexpr int K_VECS_PER_THREAD = K_ELTS_PER_THREAD / K_VEC_SIZE;

  int ko = tid / THREADS_PER_KEY;
  int ki = (tid % THREADS_PER_KEY) * K_VEC_SIZE;

  K_vec q[K_VECS_PER_THREAD];
#pragma unroll
  for (int i = 0; i < K_VECS_PER_THREAD; ++i) {
    q[i] = *reinterpret_cast<const K_vec *>(
        &q_smem[ki + i * THREADS_PER_KEY * K_VEC_SIZE]);
  }

  constexpr int K_PER_ITER = THREADS_PER_BLOCK / THREADS_PER_KEY;
  constexpr int K_PER_WARP = WARP_SIZE / THREADS_PER_KEY;

  T *k_cache = &params.cache_kv[bhi * params.max_seq_length * Dh + ki];
  int ti_end = div_up(params.timestep, K_PER_WARP) * K_PER_WARP;

  for (int ti = ko; ti < ti_end; ti += K_PER_ITER) {
    K_vec k[K_VECS_PER_THREAD];
#pragma unroll
    for (int ii = 0; ii < K_VECS_PER_THREAD; ++ii) {
      int jj = ii * params.max_seq_length + ti;
      if (ti < params.timestep) {
        k[ii] = *reinterpret_cast<const K_vec *>(&k_cache[jj * QK_ELTS_IN_16B]);
      }
    }

    float qk = Qk_dot<T, THREADS_PER_KEY>::dot(q, k) * params.inv_sqrt_dh;

    // bool is_mask = false;
    if (ti < params.timestep && tid % THREADS_PER_KEY == 0) {
      // qk_max = is_mask ? qk_max : fmaxf(qk_max, qk);
      T mask = params.attn_mask[bi * (params.timestep + 1) + ti];
      qk += static_cast<float>(mask);
      qk_max = fmaxf(qk_max, qk);

      qk_smem[ti] = qk;
    }
  }

#pragma unroll
  for (int mask = WARP_SIZE / 2; mask >= THREADS_PER_KEY; mask /= 2) {
    qk_max = fmaxf(qk_max, __shfl_xor_sync(uint32_t(-1), qk_max, mask));
  }

  const int warp = tid / WARP_SIZE;
  const int lane = tid % WARP_SIZE;

  if (lane == 0) {
    red_smem[warp] = qk_max;
  }

  __syncthreads();

  qk_max = lane < WARPS_PER_BLOCK ? red_smem[lane] : -FLT_MAX;
#pragma unroll
  for (int mask = WARPS_PER_BLOCK / 2; mask >= 1; mask /= 2) {
    qk_max = fmaxf(qk_max, __shfl_xor_sync(uint32_t(-1), qk_max, mask));
  }

  qk_max = __shfl_sync(uint32_t(-1), qk_max, 0);

#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
  if (bi == 0 && hi == 0 && tid == 0) {
    printf("=======qk_out=======\n");
    for (int i = 0; i <= params.timestep; ++i) printf("%f ", qk_smem[i]);
    printf("qk_max=%f\n", qk_max);
  }
  __syncthreads();
#endif

  float sum = 0.f;
  for (int ti = tid; ti <= params.timestep; ti += THREADS_PER_BLOCK) {
    // bool is_mask = false;
    // float logit = is_mask ? 0.f : __expf(qk_smem[ti] - qk_max);
    float logit = __expf(qk_smem[ti] - qk_max);
    sum += logit;
    qk_smem[ti] = logit;
  }

  sum = block_sum<WARPS_PER_BLOCK>(&red_smem[WARPS_PER_BLOCK], sum);

  // FIXME(wangxi): need add 1.e-6f?
  float inv_sum = __fdividef(1.f, sum + 1.e-6f);
  for (int ti = tid; ti <= params.timestep; ti += THREADS_PER_BLOCK) {
    convert_from_float(logits_smem[ti], qk_smem[ti] * inv_sum);
  }
  __syncthreads();

  constexpr int V_VEC_SIZE = Dh / THREADS_PER_VALUE;
  using V_vec = typename V_vec_<T, V_VEC_SIZE>::Type;

  int vo = tid / THREADS_PER_VALUE;
  int vi = (tid % THREADS_PER_VALUE) * V_VEC_SIZE;

  T *v_cache = &params.cache_kv[params.batch_size * params.num_head *
                                    params.max_seq_length * Dh +
                                bhi * params.max_seq_length * Dh + vi];

#ifdef MMHA_USE_FP32_ACUM_FOR_OUT
  using V_vec_acum = typename V_vec_acum_fp32_<V_vec>::Type;
#else
  using V_vec_acum = V_vec;
#endif

  V_vec_acum out;
  zero(out);

  constexpr int V_PER_ITER = THREADS_PER_BLOCK / THREADS_PER_VALUE;
  for (int ti = vo; ti < params.timestep; ti += V_PER_ITER) {
    V_vec v = *reinterpret_cast<const V_vec *>(&v_cache[ti * Dh]);
#if defined(MMHA_USE_FP32_ACUM_FOR_LOGITS)
    float logit = logits_smem[ti];
    out = fma(logit, cast_to_float(v), out);
#else
    T logit = logits_smem[ti];
    // Update the partial sums.
    out = fma(logit, v, out);
#endif
  }

#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
  if (bi == 0 && hi == 0 && tid == 0) {
    printf("======logits_out=====\n");
    for (int i = 0; i <= params.timestep; ++i) printf("%f ", logits_smem[i]);
    printf("\n");
  }
  __syncthreads();
#endif

  if (vo == (params.timestep % V_PER_ITER)) {
    V_vec v = *reinterpret_cast<const V_vec *>(
        &params.qkv[2 * params.num_head * Dh + qkv_base_offset + vi]);
    V_vec v_bias = *reinterpret_cast<const V_vec *>(
        &params.qkv_bias[2 * params.num_head * Dh + hi * Dh + vi]);
    v = add(v, v_bias);
    *reinterpret_cast<V_vec *>(&v_cache[params.timestep * Dh]) = v;

#if defined(MMHA_USE_FP32_ACUM_FOR_LOGITS)
    out = fma(logits_smem[params.timestep], cast_to_float(v), out);
#else
    out = fma(logits_smem[params.timestep], v, out);
#endif
  }

  __syncthreads();

#pragma unroll
  for (int active_groups = V_PER_ITER; active_groups >= 2; active_groups /= 2) {
    int midpoint = active_groups / 2;

    if (vo >= midpoint && vo < active_groups) {
#ifdef MMHA_USE_FP32_ACUM_FOR_OUT
      convert_from_float(
          *reinterpret_cast<V_vec *>(&out_smem[(vo - midpoint) * Dh + vi]),
          out);
#else
      *reinterpret_cast<V_vec *>(&out_smem[(vo - midpoint) * Dh + vi]) = out;
#endif
    }
    __syncthreads();
    if (vo < midpoint) {
      out = add(*reinterpret_cast<const V_vec *>(&out_smem[vo * Dh + vi]), out);
    }
    __syncthreads();
  }

  if (vo == 0) {
#ifdef MMHA_USE_FP32_ACUM_FOR_OUT
    convert_from_float(*reinterpret_cast<V_vec *>(&params.out[bhi * Dh + vi]),
                       out);
#else
    *reinterpret_cast<V_vec *>(&params.out[bhi * Dh + vi]) = out;
#endif
  }

#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
  __syncthreads();
  if (bi == 0 && hi == 0 && tid == 0) {
    printf("======fmha_out=====\n");
    for (int i = 0; i < Dh; ++i)
      printf("%f ", static_cast<float>(params.out[i]));
    printf("\n");
  }
#endif
}

template <typename T>
inline size_t smem_size_in_bytes(
    const Masked_multihead_attention_params<T> &params, int dim_head,
    int threads_per_value, int threads_per_block) {
  size_t qk_sz = div_up(params.timestep + 1, 4) * 16;
  size_t logits_sz = 0;

#ifndef MMHA_USE_FP32_ACUM_FOR_LOGITS
  if (sizeof(T) != 4) {
    logits_sz = div_up(params.max_seq_length, 4) * 4 * sizeof(T);
  }
#endif
  size_t softmax_sz = qk_sz + logits_sz;

  int rows_per_red = threads_per_block / threads_per_value;
  size_t red_sz = rows_per_red * dim_head * sizeof(T) / 2;

  return max(softmax_sz, red_sz);
}

#define MMHA_LAUNCH_KERNEL(T, Dh, THDS_PER_KEY, THDS_PER_VALUE,          \
                           THDS_PER_BLOCK, stream)                       \
  size_t smem_sz =                                                       \
      smem_size_in_bytes<T>(params, Dh, THDS_PER_VALUE, THDS_PER_BLOCK); \
  dim3 grid(params.num_head, params.batch_size);                         \
  masked_multihead_attention_kernel<                                     \
      T, Dh, THDS_PER_KEY, THDS_PER_VALUE,                               \
      THDS_PER_BLOCK><<<grid, THDS_PER_BLOCK, smem_sz, stream>>>(params)

template <typename T, int Dh>
void fmha_launch_kernel(const Masked_multihead_attention_params<T> &params,
                        const cudaStream_t &stream) {
  constexpr int THREADS_PER_VALUE = Dh * sizeof(T) / 16;
  if (params.timestep < 32) {
    MMHA_LAUNCH_KERNEL(T, Dh, 4, THREADS_PER_VALUE, 64, stream);
  } else if (params.timestep < 2048) {
    MMHA_LAUNCH_KERNEL(T, Dh, 2, THREADS_PER_VALUE, 128, stream);
  } else {
    MMHA_LAUNCH_KERNEL(T, Dh, 1, THREADS_PER_VALUE, 256, stream);
  }
}

template <typename T>
void fmha(const platform::CUDADeviceContext &dev_ctx, const Tensor &qkv_tensor,
          const Tensor &qkv_bias_tensor, const Tensor &src_mask_tensor,
          Tensor *cache_kv_tensor, Tensor *out_tensor, int batch_size,
          int max_seq_length, int num_head, int dim_head, int timestep,
          float inv_sqrt_dh) {
  Masked_multihead_attention_params<T> params;
  params.out = out_tensor->data<T>();
  params.qkv = qkv_tensor.data<T>();
  params.qkv_bias = qkv_bias_tensor.data<T>();
  params.attn_mask = src_mask_tensor.data<T>();
  params.cache_kv = cache_kv_tensor->data<T>();

  params.batch_size = batch_size;
  params.num_head = num_head;
  params.timestep = timestep;
  params.max_seq_length = max_seq_length;
  params.inv_sqrt_dh = inv_sqrt_dh;

  switch (dim_head) {
    case 32:
      fmha_launch_kernel<T, 32>(params, dev_ctx.stream());
      break;
    case 64:
      fmha_launch_kernel<T, 64>(params, dev_ctx.stream());
      break;
    case 128:
      fmha_launch_kernel<T, 128>(params, dev_ctx.stream());
      break;
    default:
      PADDLE_THROW(platform::errors::Unimplemented(
          "dim_head = %d is unsupport, only support "
          "dim_head = 32, 64 or 128 for now.",
          dim_head));
  }
}

// NOTE: simd with 16Bytes(128bit), float is 4, float16 is 8
constexpr int VEC_16B = 16;

template <typename T>
__global__ void write_cache_k_kernel(T *cache_k, const T *k, const int num_head,
                                     const int dim_head, const int seq_len,
                                     const int max_seq_len) {
  const int bi = blockIdx.y;
  const int hi = blockIdx.z;
  constexpr int X_ELEMS = VEC_16B / sizeof(T);

  // [bsz, num_head, seq_len, dim_head/x, x]
  auto k_src = reinterpret_cast<const uint4 *>(
      k + bi * num_head * seq_len * dim_head + hi * seq_len * dim_head);
  // [bsz, num_head, dim_head/x, max_seq_len, x]
  auto k_dst = reinterpret_cast<uint4 *>(
      cache_k + bi * num_head * max_seq_len * dim_head +
      hi * max_seq_len * dim_head);

  const int out_idx = blockIdx.x * blockDim.x + threadIdx.x;
  // vec size
  int dim_head_div_x = dim_head / X_ELEMS;

  // FIXME(wangxi): num_head is not need?
  // if (out_idx >= num_head * dim_head_div_x * max_seq_len) return;
  if (out_idx >= dim_head_div_x * max_seq_len) return;

  int idx = out_idx;
  const int k_seq_len_id = idx % max_seq_len;
  // idx = (idx - k_seq_len_id) / max_seq_len;
  idx = idx / max_seq_len;
  const int k_vec_id = idx % dim_head_div_x;

  if (k_seq_len_id < seq_len) {
    k_dst[out_idx] = k_src[k_seq_len_id * dim_head_div_x + k_vec_id];
  }
}

template <typename T>
__global__ void write_cache_v_kernel(T *cache_v, const T *v, const int num_head,
                                     const int dim_head, const int seq_len,
                                     const int max_seq_len) {
  const int bi = blockIdx.y;
  const int hi = blockIdx.z;

  // [bsz, num_head, seq_len, dim_head/x, x]
  auto v_src = reinterpret_cast<const uint4 *>(
      v + bi * num_head * seq_len * dim_head + hi * seq_len * dim_head);
  // [bsz, num_head, max_seq_len, dim_head/x, x]
  auto v_dst = reinterpret_cast<uint4 *>(
      cache_v + bi * num_head * max_seq_len * dim_head +
      hi * max_seq_len * dim_head);

  const int idx = blockIdx.x * blockDim.x + threadIdx.x;
  constexpr int X_ELEMS = VEC_16B / sizeof(T);
  const int dim_head_div_x = dim_head / X_ELEMS;

  if (idx >= dim_head_div_x * seq_len) return;

  v_dst[idx] = v_src[idx];
}

template <typename T>
void write_cache_kv(const platform::CUDADeviceContext &dev_ctx, T *cache_k,
                    T *cache_v, const T *k, const T *v, const int bsz,
                    const int num_head, const int seq_len,
                    const int max_seq_len, const int dim_head) {
  constexpr int block_sz = 128;
  constexpr int x = VEC_16B / sizeof(T);

  assert(dim_head % x == 0);
  PADDLE_ENFORCE_EQ(
      dim_head % x, 0,
      platform::errors::PreconditionNotMet(
          "dim_head=%d must be divisible by vec_size=%d", dim_head, x));

  int max_size = max_seq_len * dim_head / x;
  int size = seq_len * dim_head / x;
  dim3 grid(div_up(max_size, block_sz), bsz, num_head);
  dim3 grid_v(div_up(size, block_sz), bsz, num_head);

  // transpose [bsz, num_head, seq_len, dim_head/x, x]->
  // [bsz, num_head, dim_head/x, max_seq_len, x]
  write_cache_k_kernel<<<grid, block_sz, 0, dev_ctx.stream()>>>(
      cache_k, k, num_head, dim_head, seq_len, max_seq_len);

  // copy [bsz, num_head, seq_len, dim_head/x, x]->
  // [bsz, num_head, max_seq_len, dim_head/x, x]
  write_cache_v_kernel<<<grid_v, block_sz, 0, dev_ctx.stream()>>>(
      cache_v, v, num_head, dim_head, seq_len, max_seq_len);
}

}  // namespace

template <typename T>
class FusedMultiTransformerOpKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    using U = LayerNormParamType<T>;
    auto place = ctx.GetPlace();
    auto &dev_ctx = ctx.cuda_device_context();

    auto *time_step = ctx.Input<Tensor>("TimeStep");
    // 0. input
    auto *input_x = ctx.Input<Tensor>("X");
    const auto input_x_dims = input_x->dims();
    int bsz = input_x_dims[0];
    int seq_len = input_x_dims[1];
    int dim_embed = input_x_dims[2];
    int bsz_seq = bsz * seq_len;

    // 1. layer norm
    const auto pre_layer_norm = ctx.Attr<bool>("pre_layer_norm");
    const float epsilon = ctx.Attr<float>("epsilon");
    auto ln_scales = ctx.MultiInput<Tensor>("LnScale");
    auto ln_biases = ctx.MultiInput<Tensor>("LnBias");

    auto ln_compute = AttnLayerNorm<T>(dev_ctx, epsilon, bsz_seq, dim_embed);
    Tensor ln_mean, ln_var;
    auto *ln_mean_data = ln_mean.mutable_data<U>({bsz_seq}, place);
    auto *ln_var_data = ln_var.mutable_data<U>({bsz_seq}, place);

    // 2. qkv
    // x: qkv's input [batch_size, seq_len, dim_embed]
    // y: qkv's weight: [3, num_head, dim_head, dim_embed]
    auto qkv_weights = ctx.MultiInput<Tensor>("QKVW");
    auto qkv_biases = ctx.MultiInput<Tensor>("QKVBias");
    const auto qkv_w_dims = qkv_weights[0]->dims();
    int num_head = qkv_w_dims[1];
    int dim_head = qkv_w_dims[2];
    int hidden_size = num_head * dim_head;
    int output_size = 3 * hidden_size;
    int input_size = dim_embed;

    bool compute_bias = qkv_biases.size() > 0 && time_step == nullptr;
    // (transA, transB, compute_bias) = (false, true, false)
    auto qkv_compute = AttnMatMul<T>(dev_ctx, false, true, bsz_seq, output_size,
                                     input_size, compute_bias);
    Tensor qkv_out;
    auto *qkv_out_data =
        qkv_out.mutable_data<T>({bsz, seq_len, 3, num_head, dim_head}, place);

    // 3. fmha
    AttnDropoutParam attn_param(true, "upscale_in_train", 0.0, true, true, 0,
                                nullptr);
    auto fmha_compute =
        FMHARef<T>(dev_ctx, bsz, seq_len, num_head, dim_head, attn_param);
    auto *src_mask = ctx.Input<Tensor>("SrcMask");
    auto cache_kvs = ctx.MultiInput<Tensor>("CacheKV");
    auto cache_kv_outs = ctx.MultiOutput<Tensor>("CacheKVOut");
    // auto *time_step = ctx.Input<Tensor>("TimeStep");

    auto out_seq_len = seq_len;
    if (time_step) {
      PADDLE_ENFORCE_EQ(time_step->place(), platform::CPUPlace(),
                        platform::errors::PreconditionNotMet(
                            "The place of input(TimeStep) must be CPUPlace."));
      // cache_seq_len
      int time_step_value = time_step->data<int>()[0];
      PADDLE_ENFORCE_GT(time_step_value, 0,
                        platform::errors::PreconditionNotMet(
                            "The value of time_step must > 0, but now is %d",
                            time_step_value));
      PADDLE_ENFORCE_EQ(
          seq_len, 1,
          platform::errors::PreconditionNotMet(
              "In decode stage, the seq_len of input must be 1, but now is %d",
              seq_len));
      out_seq_len += time_step_value;
    }

    Tensor transpose_out_2, qk_out;
    auto *transpose_out_2_data = transpose_out_2.mutable_data<T>(
        {3, bsz, num_head, seq_len, dim_head}, place);
    auto *qk_out_data =
        qk_out.mutable_data<T>({bsz, num_head, seq_len, out_seq_len}, place);

    Tensor src_mask_out, softmax_out;
    Tensor attn_dropout_mask_out, attn_dropout_out;
    Tensor qktv_out, fmha_out;
    auto *src_mask_out_data = src_mask_out.mutable_data<T>(
        {bsz, num_head, seq_len, out_seq_len}, place);
    auto *softmax_out_data = softmax_out.mutable_data<T>(
        {bsz, num_head, seq_len, out_seq_len}, place);

    auto *attn_dropout_mask_out_data = attn_dropout_mask_out.mutable_data<T>(
        {bsz, num_head, seq_len, out_seq_len}, place);
    auto *attn_dropout_data_data = attn_dropout_out.mutable_data<T>(
        {bsz, num_head, seq_len, out_seq_len}, place);

    auto *qktv_out_data =
        qktv_out.mutable_data<T>({bsz, num_head, seq_len, dim_head}, place);
    auto *fmha_out_data =
        fmha_out.mutable_data<T>({bsz, seq_len, num_head, dim_head}, place);

    // 4. out_linear
    auto out_linear_weights = ctx.MultiInput<Tensor>("OutLinearW");
    auto out_linear_biases = ctx.MultiInput<Tensor>("OutLinearBias");
    int ring_id = ctx.Attr<int>("ring_id");
    // (transA, transB, compute_bias) = (false, false, false)
    auto out_linear_compute = AttnMatMul<T>(dev_ctx, false, false, bsz_seq,
                                            dim_embed, hidden_size, false);

    // 5. ln(residual + bias)
    DropoutParam dropout_param2(true, 0, true, true, 0.0, nullptr, 0);
    FusedDropoutLayerNormHelper<T, uint8_t> fused_dropout_layernorm_helper(
        dev_ctx, bsz_seq, dim_embed, dropout_param2, epsilon);
    auto ffn_ln_scales = ctx.MultiInput<Tensor>("FFNLnScale");
    auto ffn_ln_biases = ctx.MultiInput<Tensor>("FFNLnBias");
    Tensor bias_dropout_residual_out, dropout_mask_out;
    auto *bias_dropout_residual_out_data =
        bias_dropout_residual_out.mutable_data<T>({bsz, seq_len, dim_embed},
                                                  place);
    auto *dropout_mask_out_data = dropout_mask_out.mutable_data<uint8_t>(
        {bsz, seq_len, dim_embed}, place);

    // 6. ffn matmul1
    auto ffn1_weights = ctx.MultiInput<Tensor>("FFN1Weight");
    auto ffn1_biases = ctx.MultiInput<Tensor>("FFN1Bias");
    auto ffn1_weight_dim = ffn1_weights[0]->dims();

    int dim_ffn = ffn1_weight_dim[1];
    auto ffn1_linear_compute = AttnMatMul<T>(dev_ctx, false, false, bsz_seq,
                                             dim_ffn, dim_embed, false);
    Tensor ffn1_out;
    auto *ffn1_out_data = ffn1_out.mutable_data<T>({bsz_seq, dim_ffn}, place);

    // 7. ffn act + bias
    DropoutParam ffn1_dropout_param(true, 0, true, true, 0.0, nullptr, 0);
    FusedDropoutHelper<T, uint8_t> fused_act_dropout_helper(
        dev_ctx, bsz_seq, dim_ffn, ffn1_dropout_param);
    Tensor ffn1_dropout_out, ffn1_dropout_mask;
    auto *ffn1_dropout_out_data =
        ffn1_dropout_out.mutable_data<T>({bsz_seq, dim_ffn}, place);
    auto *ffn1_dropout_mask_data =
        ffn1_dropout_mask.mutable_data<uint8_t>({bsz_seq, dim_ffn}, place);

    // 8. ffn2 matmul
    auto ffn2_weights = ctx.MultiInput<Tensor>("FFN2Weight");
    auto ffn2_biases = ctx.MultiInput<Tensor>("FFN2Bias");
    auto ffn2_linear_compute = AttnMatMul<T>(dev_ctx, false, false, bsz_seq,
                                             dim_embed, dim_ffn, false);

    // 9. ffn2 residual bias
    DropoutParam ffn2_dropout_param(true, 0, true, true, 0.0, nullptr, 0);
    FusedDropoutLayerNormHelper<T, uint8_t> ffn2_fused_dropout_helper(
        dev_ctx, bsz_seq, dim_embed, ffn2_dropout_param, epsilon);

    // calc
    auto *out = ctx.Output<Tensor>("Out");
    auto *from_data = out->mutable_data<T>(place);
    Tensor *from_tensor = out;
    Tensor tmp_out;
    auto *tmp_out_data =
        tmp_out.mutable_data<T>({bsz, seq_len, dim_embed}, place);

    auto *x_data = input_x->data<T>();
    Tensor *buf0 = nullptr;
    Tensor *buf1 = nullptr;

    // step0:  x   --> buf1
    // step1: buf1 --> buf0
    // step2: buf0 --> buf1
    int layers = qkv_weights.size();
    if (layers & 1) {
      // odd, set buf1 as out
      buf0 = &tmp_out;
      buf1 = out;
    } else {
      // even, set buf0 as out
      buf0 = out;
      buf1 = &tmp_out;
    }

    for (int i = 0; i < layers; ++i) {
      // step1. layer_norm
      if (i == 0 && pre_layer_norm) {
        auto *ln_scale_data = ln_scales[i]->data<U>();
        auto *ln_bias_data = ln_biases[i]->data<U>();
        // TODO(wangxi): can remove mean var in inference
        ln_compute.ComputeForward(x_data, ln_scale_data, ln_bias_data,
                                  buf1->data<T>(), ln_mean_data, ln_var_data);
      } else if (!pre_layer_norm) {
        PADDLE_THROW(platform::errors::Unimplemented(
            "Unimplemented post_layer_norm for now."));
      }
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step1";
#endif

      // step2. qkv
      const Tensor *qkv_bias = qkv_biases.size() > 0 ? qkv_biases[i] : nullptr;
      // NOTE: in decoder stage, bias is fused in fmha
      const Tensor *bias = time_step ? nullptr : qkv_bias;
      qkv_compute.ComputeForward(qkv_weights[i], buf1, bias, &qkv_out,
                                 &qkv_out);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step2";
#endif

      // step3. fmha
      const Tensor *cache_kv = cache_kvs.size() > 0 ? cache_kvs[i] : nullptr;
      Tensor *cache_kv_out = cache_kv ? cache_kv_outs[i] : nullptr;

      if (time_step) {  // generation decoder stage
        // [2, batch_size, num_head, max_seq_len, head_size]
        int max_seq_len = cache_kv->dims()[3];
        fmha<T>(dev_ctx, qkv_out, *qkv_bias, *src_mask, cache_kv_out, &fmha_out,
                bsz, max_seq_len, num_head, dim_head, time_step->data<int>()[0],
                1. / sqrt(dim_head));
      } else if (cache_kv_out) {  // generation context stage
        // TODO(wangxi): can remove dropout in inference
        fmha_compute.ComputeForward(
            qkv_out, nullptr, src_mask, &transpose_out_2, nullptr, &qk_out,
            &src_mask_out, &softmax_out, &attn_dropout_mask_out,
            &attn_dropout_out, &qktv_out, &fmha_out);
        // [3, bsz, num_head, seq_len, head_dim]
        T *qkv_data = transpose_out_2_data;
        int64_t q_size = bsz * seq_len * num_head * dim_head;
        int64_t k_size = q_size;
        const T *q_ptr = qkv_data;
        const T *k_ptr = q_ptr + q_size;
        const T *v_ptr = k_ptr + k_size;

        // [2, bsz, num_head, max_seq_len, head_dim]
        int max_seq_len = cache_kv_out->dims()[3];
        T *cache_kv_data = cache_kv_out->data<T>();
        int64_t cache_k_size = bsz * num_head * max_seq_len * dim_head;

        T *cache_k_ptr = cache_kv_data;
        T *cache_v_ptr = cache_kv_data + cache_k_size;

        write_cache_kv<T>(dev_ctx, cache_k_ptr, cache_v_ptr, k_ptr, v_ptr, bsz,
                          num_head, seq_len, max_seq_len, dim_head);
      } else {  // not generation
        // TODO(wangxi): can remove dropout in inference
        fmha_compute.ComputeForward(
            qkv_out, cache_kv, src_mask, &transpose_out_2, cache_kv_out,
            &qk_out, &src_mask_out, &softmax_out, &attn_dropout_mask_out,
            &attn_dropout_out, &qktv_out, &fmha_out);
      }
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step3";
#endif

      // step4. out_linear
      out_linear_compute.ComputeForward(out_linear_weights[i], &fmha_out,
                                        nullptr, buf1, nullptr);
      AllReduce<T>(*buf1, ring_id, dev_ctx);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step4";
#endif

      // step5. ln(residual + dropout(input + bias))
      if (pre_layer_norm) {
        auto *ln_scale_data = ffn_ln_scales[i]->data<U>();
        auto *ln_bias_data = ffn_ln_biases[i]->data<U>();
        auto *out_linear_bias_data = out_linear_biases[i]->data<T>();

        // inplace
        fused_dropout_layernorm_helper.LayernormResidualDropoutBias(
            dev_ctx, buf1->data<T>(), x_data, out_linear_bias_data,
            ln_scale_data, ln_bias_data, bias_dropout_residual_out_data,
            dropout_mask_out_data, buf1->data<T>(), ln_mean_data, ln_var_data);
      } else {
      }
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step5";
#endif

      // step6. ffn matmul1
      ffn1_linear_compute.ComputeForward(ffn1_weights[i], buf1, nullptr,
                                         &ffn1_out, nullptr);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step6";
#endif

      // step7. act bias
      // TODO(wangxi): remove dropout mask in inference
      fused_act_dropout_helper.DropoutActBias(
          dev_ctx, ffn1_out_data, ffn1_biases[i]->data<T>(), "gelu",
          ffn1_dropout_out_data, ffn1_dropout_mask_data);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step7";
#endif

      // step8. ffn matmul2
      ffn2_linear_compute.ComputeForward(ffn2_weights[i], &ffn1_dropout_out,
                                         nullptr, buf1, nullptr);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step8.0";
#endif

      AllReduce<T>(*buf1, ring_id, dev_ctx);
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step8.1";
#endif

      // step9. residual bias
      if (pre_layer_norm) {
        // TODO(wangxi): remove dropout mask in inference
        if (i < layers - 1) {
          auto *ln_scale_data = ln_scales[i + 1]->data<U>();
          auto *ln_bias_data = ln_biases[i + 1]->data<U>();
          ffn2_fused_dropout_helper.LayernormResidualDropoutBias(
              dev_ctx, buf1->data<T>(), bias_dropout_residual_out_data,
              ffn2_biases[i]->data<T>(), ln_scale_data, ln_bias_data,
              buf1->data<T>(), dropout_mask_out_data, buf0->data<T>(),
              ln_mean_data, ln_var_data);
        } else {
          ffn2_fused_dropout_helper.ResidualDropoutBias(
              dev_ctx, buf1->data<T>(), bias_dropout_residual_out_data,
              ffn2_biases[i]->data<T>(), buf1->data<T>(),
              dropout_mask_out_data);
        }
      } else {
      }
#ifdef _DEBUG_FUSED_MULTI_TRANSFORMER
      VLOG(0) << "step9";
#endif
      x_data = buf1->data<T>();
      std::swap(buf0, buf1);
    }
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
namespace plat = paddle::platform;
REGISTER_OP_CUDA_KERNEL(fused_multi_transformer,
                        ops::FusedMultiTransformerOpKernel<plat::float16>,
                        ops::FusedMultiTransformerOpKernel<float>);
