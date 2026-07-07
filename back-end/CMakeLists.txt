cmake_minimum_required(VERSION 2.8.7)

project(back-end)

add_subdirectory(manager)
add_subdirectory(llvm-translator)

include(ExternalProject)

# -fno-exceptions: KLEE disables exceptions only when `llvm-config --cxxflags`
# advertises -fno-exceptions (see its cmake/find_llvm.cmake -> LLVM_ENABLE_EH).
# Stock LLVM 3.4 does; the LLVM we build from source in the Dockerfile does not,
# so force it here. Without it KLEE compiles with exceptions, Boost never defines
# BOOST_NO_EXCEPTIONS, and crete-replayer's boost::throw_exception override (which
# only exists under BOOST_NO_EXCEPTIONS) matches no declaration.
# RTTI is deliberately left ON (LLVM is built with LLVM_REQUIRES_RTTI=ON in the
# Dockerfile): crete-replayer serializes with Boost.Serialization, which needs
# typeid/dynamic_cast, so -fno-rtti is not an option here.
set(KLEE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-exceptions -I${CMAKE_SOURCE_DIR}/lib/include/ -I${CMAKE_BINARY_DIR}/lib/boost/boost-prefix/src/boost_1_59_0 -DCRETE_CONFIG=1")
set(KLEE_C_FLAGS "${CMAKE_C_FLAGS} -I${CMAKE_SOURCE_DIR}/lib/include/ -I${CMAKE_BINARY_DIR}/lib/boost/boost-prefix/src/boost_1_59_0 -DCRETE_CONFIG=1")
# -I/usr/include/glib-2.0/ -I/usr/lib/x86_64-linux-gnu/glib-2.0/include/
set(KLEE_LD_FLAGS "-L${CMAKE_BINARY_DIR}/bin -L${CMAKE_BINARY_DIR}/bin/boost")

execute_process(COMMAND which llvm-config-3.4
  OUTPUT_VARIABLE LLVMCONFIG_PATH
  OUTPUT_STRIP_TRAILING_WHITESPACE)

ExternalProject_Add(
        klee-1.4.0

	SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/klee-1.4.0
	BUILD_IN_SOURCE 0

        DOWNLOAD_COMMAND ""
	UPDATE_COMMAND ""

	CMAKE_ARGS
        -DLLVM_CONFIG_BINARY=${LLVMCONFIG_PATH}
        -DCMAKE_CXX_COMPILER=clang++-3.4
        -DCMAKE_C_COMPILER=clang-3.4
        -DCMAKE_CXX_FLAGS=${KLEE_CXX_FLAGS}
        -DCMAKE_C_FLAGS=${KLEE_C_FLAGS}
        -DCMAKE_EXE_LINKER_FLAGS=${KLEE_LD_FLAGS}
        -DBUILD_SHARED_LIBS:BOOL=OFF -DENABLE_PYTHON_INTERFACE:BOOL=OFF
        -DENABLE_SOLVER_STP=ON
        -DENABLE_SYSTEM_TESTS=OFF
        -DENABLE_UNIT_TESTS=OFF
        -DENABLE_KLEE_ASSERTS=FALSE

        INSTALL_COMMAND
        ln -sf
        ${CMAKE_CURRENT_BINARY_DIR}/klee-1.4.0-prefix/src/klee-1.4.0-build/bin/klee
        ${CMAKE_BINARY_DIR}/bin/crete-klee-1.4.0

        BUILD_ALWAYS 1
	)

add_dependencies(klee-1.4.0 stp-2.1.2 crete_test_case boost)
