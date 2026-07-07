cmake_minimum_required(VERSION 2.8.7)

project(front-end)

include(ExternalProject)

ExternalProject_Add(
	qemu-2.3

	SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/qemu-2.3
	BUILD_IN_SOURCE 1

        DOWNLOAD_COMMAND ""
	UPDATE_COMMAND ""

	CONFIGURE_COMMAND
        ./configure
        --enable-tcg-interpreter
        --target-list=i386-softmmu,x86_64-softmmu
        # QEMU's own guest agent (qemu-ga) is not used by CRETE and is not
        # installed below. Its commands-posix.c calls major()/minor() without
        # <sys/sysmacros.h>; glibc 2.28+ moved those out of <sys/types.h>, so it
        # fails to link on a modern host. Just don't build it.
        --disable-guest-agent
        # virtfs/9p (hw/9pfs/virtio-9p.c) uses major()/minor()/makedev() without
        # <sys/sysmacros.h> and hits the same glibc 2.28+ link failure as qemu-ga.
        # CRETE does not use 9p host/guest file sharing, so don't build it.
        --disable-virtfs
        # This QEMU's C++ files (runtime-dump/*) include Boost 1.59 headers and link
        # the compiled Boost libs, which are built for the old libstdc++ std::string
        # ABI; compiled here by the modern system g++ (new __cxx11 ABI by default),
        # they would otherwise emit undefined references to the old-ABI Boost symbols.
        # Pin the old ABI. This goes in --extra-cflags, not --extra-cxxflags, because
        # this QEMU rebuilds QEMU_CXXFLAGS from QEMU_CFLAGS at build time (rules.mak),
        # discarding --extra-cxxflags; the define is a harmless no-op for the C files.
        "--extra-cflags=-D_GLIBCXX_USE_CXX11_ABI=0 -I${CMAKE_SOURCE_DIR}/lib/include -I${CMAKE_BINARY_DIR}/lib/boost/boost-prefix/src/boost_1_59_0"
        "--extra-ldflags=-L${CMAKE_BINARY_DIR}/bin -L${CMAKE_BINARY_DIR}/bin/boost"

	BUILD_COMMAND make -j7

	INSTALL_COMMAND
        ln -sf ${CMAKE_CURRENT_SOURCE_DIR}/qemu-2.3/i386-softmmu/crete-qemu-2.3-system-i386 ${CMAKE_BINARY_DIR}/bin/crete-qemu-2.3-system-i386 &&
        ln -sf ${CMAKE_CURRENT_SOURCE_DIR}/qemu-2.3/x86_64-softmmu/crete-qemu-2.3-system-x86_64 ${CMAKE_BINARY_DIR}/bin/crete-qemu-2.3-system-x86_64
	)

add_dependencies(qemu-2.3 crete_test_case boost)

add_custom_target(qemu-2.3-remake ALL
  COMMAND  make -j7
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/qemu-2.3
  DEPENDS qemu-2.3)
