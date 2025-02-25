if (NOT WITH_INFRT)
    return()
endif()

option(INFRT_WITH_PHI  "Compile INFRT with PHI"    ON)
option(INFRT_WITH_GPU  "Compile INFRT with GPU"    OFF)
option(INFRT_WITH_TRT  "Compile INFRT with TensorRT"    OFF)

#TODO(xiaowei) remove fluid
include_directories(${PADDLE_SOURCE_DIR}/paddle/fluid/platform)

if(WITH_GPU)
  set(INFRT_WITH_GPU ON)
endif()

if (INFRT_WITH_PHI)
  add_definitions("-DINFRT_WITH_PHI")

  # TODO(wilber): Now Infrt gpu/trt depends on phi's components, Modify compile dependency options later.
  if (INFRT_WITH_GPU)
    add_definitions("-DINFRT_WITH_GPU")
    if (INFRT_WITH_TRT)
      add_definitions("-DINFRT_WITH_TRT")
    endif()
  endif()
endif()

# compile flags
set(INFRT_FLAGS -Wno-comment)
foreach(flag ${INFRT_FLAGS})
  safe_set_cflag(CMAKE_C_FLAGS ${flag})
  safe_set_cxxflag(CMAKE_CXX_FLAGS ${flag})
endforeach()

set(INFRT_SOURCE_DIR "${PADDLE_SOURCE_DIR}/paddle/infrt" )
set(INFRT_BINARY_DIR "${PADDLE_BINARY_DIR}/paddle/infrt" )
set(INFRT_TEST_TARGETS CACHE INTERNAL "")
include(infrt_lib)

set(infrt_src CACHE INTERNAL "" FORCE)

# Gather headers for library publish.
function(core_gather_headers)
    file(GLOB includes LIST_DIRECTORIES false RELATIVE ${CMAKE_SOURCE_DIR} *.h)

    foreach(header ${includes})
        set(core_includes "${core_includes};${header}" CACHE INTERNAL "")
    endforeach()
endfunction()

function(gather_srcs SRC_GROUP)
    set(options)
    set(oneValueArgs)
    set(multiValueArgs "SRCS")
    cmake_parse_arguments(prefix "" "" "${multiValueArgs}" ${ARGN})
    foreach(cpp ${prefix_SRCS})
        set(${SRC_GROUP} "${${SRC_GROUP}};${CMAKE_CURRENT_SOURCE_DIR}/${cpp}" CACHE INTERNAL "")
    endforeach()
endfunction()

# This method is similar to the global cc_test, but discard the huge amount default dependencies those are
# not needed by INFRT.
function(cc_test_tiny TARGET_NAME)
  if(WITH_TESTING)
    set(options SERIAL)
    set(oneValueArgs "")
    set(multiValueArgs SRCS DEPS ARGS)
    cmake_parse_arguments(cc_test_tiny "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    add_executable(${TARGET_NAME} ${cc_test_tiny_SRCS})
    get_property(os_dependency_modules GLOBAL PROPERTY OS_DEPENDENCY_MODULES)
    target_link_libraries(${TARGET_NAME} ${cc_test_tiny_DEPS} ${os_dependency_modules} infrt_gtest_main gtest )
    add_dependencies(${TARGET_NAME} ${cc_test_tiny_DEPS} infrt_gtest_main gtest extern_gtest)

    add_test(NAME ${TARGET_NAME}
      COMMAND ${TARGET_NAME} "${cc_test_tiny_ARGS}"
            WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
    if (${cc_test_tiny_SERIAL})
      set_property(TEST ${TARGET_NAME} PROPERTY RUN_SERIAL 1)
    endif()
    set(INFRT_TEST_TARGETS ${INFRT_TEST_TARGETS} ${TARGET_NAME} CACHE INTERNAL "")
  endif()

endfunction()

if (WITH_TESTING)
    cc_library(infrt_gtest_main SRCS gtest_main.cc DEPS gtest glog gflags)
endif()


add_subdirectory(api)
add_subdirectory(backends)
add_subdirectory(common)
add_subdirectory(dialect)
add_subdirectory(host_context)
add_subdirectory(kernel)
add_subdirectory(tensor)
add_subdirectory(support)
add_subdirectory(external_kernels)
add_subdirectory(paddle)
add_subdirectory(tests)


# MLIR td file generations
set(infrt_mlir_incs
        basic_kernels_inc
        test_kernels_inc
        tensor_shape_inc
        dense_tensor_inc
        pd_extra_ops_inc
        trt_ops_inc
        )

if (INFRT_WITH_PHI)
    set(phi_libs phi)
    set(infrt_mlir_incs ${infrt_mlir_incs}
        MLIRinfrt_phi_tensorIncGen
        MLIRinfrt_phi_baseIncGen
        )
endif()

cc_library(infrt SHARED SRCS ${infrt_src} DEPS glog boost ${mlir_libs} ${phi_libs} paddle_framework_proto infrt_naive)
cc_library(infrt_static SRCS ${infrt_src} DEPS glog boost ${mlir_libs} ${phi_libs} paddle_framework_proto)
add_dependencies(infrt ${infrt_mlir_incs} mlir-headers)

add_custom_target(test_infrt_exec DEPENDS ${INFRT_TEST_TARGETS})
