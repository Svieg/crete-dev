cmake_minimum_required(VERSION 2.8.7)

project(boost)

include(ExternalProject)

ExternalProject_Add(
	boost

        SOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/boost-prefix/src/boost_1_59_0
	BUILD_IN_SOURCE 1

        DOWNLOAD_DIR ${CMAKE_CURRENT_BINARY_DIR}
	URL ${CMAKE_CURRENT_SOURCE_DIR}/boost_1_59_0.tar.bz2
        URL_MD5 6aa9a5c6a4ca1016edd0ed1178e3cb87
	UPDATE_COMMAND ""

	# Boost 1.59's bundled Boost.Build engine is 2015-era C that does not compile
	# with a modern GCC (implicit function decls / int are now hard errors). Relax
	# the engine's two build stages before bootstrapping.
	PATCH_COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/fix-boost-build-gcc15.sh

	CONFIGURE_COMMAND
        ./bootstrap.sh --with-libraries=atomic,filesystem,log,program_options,random,serialization,system,test,thread

	# cxxflags:
	#   -D_GLIBCXX_USE_CXX11_ABI=0  Build with the old libstdc++ std::string ABI.
	#       b2 defaults to the modern system GCC (gcc5+ std::__cxx11 ABI), but every
	#       CRETE consumer of these libs is compiled by clang-3.4 against gcc-4.8's
	#       libstdc++ (old ABI only), as is LLVM (see Dockerfile). A mismatch turns
	#       each std::string in a compiled Boost lib's API (e.g. boost::serialization)
	#       into a link-time undefined reference.
	#   -std=gnu++14  Boost 1.59 uses std::auto_ptr / std::unary_function, dropped in
	#       C++17 (the modern GCC default), so pin an older standard.
	#   -fpermissive -w  Downgrade the remaining legacy-code errors from the new GCC.
	# cflags -fcommon: Boost 1.59's C predates GCC 10's -fno-common default.
	BUILD_COMMAND ./b2 -j7 toolset=gcc
        cxxflags=-D_GLIBCXX_USE_CXX11_ABI=0 cxxflags=-std=gnu++14 cxxflags=-fpermissive cxxflags=-w
        cflags=-fcommon cflags=-w

	INSTALL_COMMAND ln -sf ${CMAKE_CURRENT_BINARY_DIR}/boost-prefix/src/boost_1_59_0/stage/lib ${CMAKE_BINARY_DIR}/bin/boost
	)
