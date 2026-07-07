# syntax=docker/dockerfile:1
#
# Build image for CRETE on the latest Ubuntu. Requires BuildKit (default on
# modern Docker) for the apt cache mounts:
#
#   docker build -t crete .
#
# CRETE is pinned to LLVM/Clang 3.4 (KLEE and the QEMU LLVM translator depend on
# it). Ubuntu 14.04 (trusty) was the last release that packaged llvm-3.4, but
# trusty is now ESM-only and gone from the public archives, so `apt-get install
# clang-3.4` is no longer possible. Instead we build LLVM/Clang 3.4 from source
# on top of the current Ubuntu, and back-fill the handful of legacy runtime bits
# the old toolchain still needs from the (still-hosted) trusty package pool.

FROM ubuntu:latest

# --- Base build tooling + CRETE's library deps (see user_manual.md §2.1) -------
# build-essential's gcc/g++ compiles LLVM 3.4 and QEMU. Everything version-
# sensitive (clang-3.4, cmake, python2, the C++ stdlib clang-3.4 links against)
# is provided in the steps below.
RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        libcap-dev \
        flex \
        bison \
        libelf-dev \
        git \
        libtool \
        libpixman-1-dev \
        minisat \
        zlib1g-dev \
        libglib2.0-dev \
        libncurses-dev \
        python3 \
        wget \
        ca-certificates \
        xz-utils \
        file \
        pkg-config

# --- CMake 3.16.9 --------------------------------------------------------------
# The distro CMake is 4.x, which removed compatibility with
# cmake_minimum_required() < 3.5. LLVM 3.4, KLEE 1.4.0, STP and QEMU all declare
# older minimums and fail to configure with it, so install an older CMake ahead
# of the system one on PATH.
ARG CMAKE_VERSION=3.16.9
RUN wget -qO- "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-Linux-x86_64.tar.gz" \
    | tar --strip-components=1 -xz -C /usr/local

# --- Legacy runtime shims from the trusty package pool -------------------------
# old-releases.ubuntu.com no longer serves trusty's dists/ index, but its shared
# pool still hosts the individual .deb files, so we fetch what we need directly
# and unpack it with dpkg-deb (no dependency resolution, no apt).
#
#  * gcc-4.8 C++ headers/libs: clang-3.4 cannot parse Ubuntu's current libstdc++
#    (its headers use C++23 constructs). clang auto-selects the newest GCC
#    install it recognises (<= 4.x), so dropping 4.8's libstdc++ in place makes
#    clang++-3.4 usable again. It still links the ABI-compatible system
#    libstdc++.so.6 at runtime, so no libstdc++ downgrade is needed.
#  * python2.7: QEMU 2.3's configure rejects Python 3.
ARG POOL=http://old-releases.ubuntu.com/ubuntu/pool/main
ARG GCC48=4.8.3-12ubuntu3
ARG PY27=2.7.16-2ubuntu0.2
RUN set -eux; cd /tmp; \
    for u in \
      "$POOL/g/gcc-4.8/gcc-4.8-base_${GCC48}_amd64.deb" \
      "$POOL/g/gcc-4.8/libgcc-4.8-dev_${GCC48}_amd64.deb" \
      "$POOL/g/gcc-4.8/libstdc++-4.8-dev_${GCC48}_amd64.deb" \
      "$POOL/p/python2.7/libpython2.7-minimal_${PY27}_amd64.deb" \
      "$POOL/p/python2.7/python2.7-minimal_${PY27}_amd64.deb" \
      "$POOL/p/python2.7/libpython2.7-stdlib_${PY27}_amd64.deb" \
      "$POOL/p/python2.7/python2.7_${PY27}_amd64.deb" ; do \
        wget -q "$u"; \
    done; \
    for d in *.deb; do dpkg-deb -x "$d" /; done; \
    rm -f /tmp/*.deb; \
    ln -sf /usr/bin/python2.7 /usr/local/bin/python2; \
    ln -sf /usr/bin/python2.7 /usr/local/bin/python

# --- Build LLVM + Clang 3.4 from source ----------------------------------------
# LLVM 3.4 (2014) predates modern toolchains. The current libstdc++ refuses C++98
# outright, so build in gnu++11 and force-include the headers newer libstdc++ no
# longer drags in transitively; -fpermissive / -w downgrade the resulting
# legacy-code diagnostics from the new GCC. X86-only Release build, installed to
# /opt/llvm-3.4; CRETE looks the toolchain up by the versioned names below.
#
# -D_GLIBCXX_USE_CXX11_ABI=0 is load-bearing: this build uses the modern GCC,
# whose default libstdc++ std::string is the gcc5+ std::__cxx11 ABI. CRETE itself
# (and the QEMU translator/KLEE that link against LLVM) is compiled by clang-3.4
# against gcc-4.8's libstdc++, which only has the old std::string ABI. Building
# LLVM with the new ABI makes every std::string in its public API (verifyModule,
# raw_fd_ostream, ...) a link-time undefined reference for those consumers, so
# pin LLVM to the old ABI to match. Boost (lib/boost) is pinned the same way.
#
# LLVM_REQUIRES_RTTI=ON (the 3.4 knob; LLVM_ENABLE_RTTI is a later name and is
# silently ignored here): LLVM defaults to -fno-rtti, but CRETE's KLEE replayer
# serializes with Boost.Serialization (needs typeid/dynamic_cast) and so must be
# built with RTTI; KLEE then requires the LLVM it links to also carry RTTI, else
# references like `typeinfo for llvm::cl::Option` are undefined at link.
ARG LLVM_VERSION=3.4.2
RUN set -eux; cd /tmp; \
    wget -q "https://releases.llvm.org/${LLVM_VERSION}/llvm-${LLVM_VERSION}.src.tar.gz"; \
    wget -q "https://releases.llvm.org/${LLVM_VERSION}/cfe-${LLVM_VERSION}.src.tar.gz"; \
    tar xf "llvm-${LLVM_VERSION}.src.tar.gz"; \
    tar xf "cfe-${LLVM_VERSION}.src.tar.gz"; \
    mv "llvm-${LLVM_VERSION}.src" llvm; \
    mv "cfe-${LLVM_VERSION}.src" llvm/tools/clang; \
    printf '#include <cstdint>\n#include <cstddef>\n#include <cstdio>\n#include <cstdlib>\n#include <cstring>\n#include <climits>\n#include <limits>\n#include <unistd.h>\n#include <sys/types.h>\n' > /tmp/force.h; \
    mkdir llvm-build; cd llvm-build; \
    cmake -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_REQUIRES_RTTI=ON \
        -DCMAKE_INSTALL_PREFIX=/opt/llvm-3.4 \
        -DCMAKE_C_FLAGS="-w" \
        -DCMAKE_CXX_FLAGS="-std=gnu++11 -D_GLIBCXX_USE_CXX11_ABI=0 -w -fpermissive -include /tmp/force.h" \
        /tmp/llvm; \
    make -j"$(nproc)"; \
    make install; \
    ln -sf /opt/llvm-3.4/bin/clang       /usr/local/bin/clang-3.4; \
    ln -sf /opt/llvm-3.4/bin/clang++     /usr/local/bin/clang++-3.4; \
    ln -sf /opt/llvm-3.4/bin/llvm-config /usr/local/bin/llvm-config-3.4; \
    clang-3.4 --version; llvm-config-3.4 --version; \
    cd /; rm -rf /tmp/llvm /tmp/llvm-build /tmp/*.src.tar.gz /tmp/force.h

WORKDIR /crete

# Fetch the git submodules (pinned to the SHAs recorded in the parent repo) in
# their own layer so they are not re-cloned every time the source changes.
# .gitmodules:
#   back-end/klee-1.4.0                    -> likebreath/klee
#   misc/util/tc-replay/check-exploitable  -> likebreath/exploitable
RUN git clone https://github.com/likebreath/klee.git back-end/klee-1.4.0 \
      && git -C back-end/klee-1.4.0 checkout c3a71c005dc7c8b0eb75e81a6fb49a23eb18e5df \
      && git clone https://github.com/likebreath/exploitable.git misc/util/tc-replay/check-exploitable \
      && git -C misc/util/tc-replay/check-exploitable checkout 338fe44b50e09f598f6c4ab9f97b56b74c88dcb7 \
      # KLEE's bitcode-runtime build step clears MAKEFLAGS via `env MAKEFLAGS="" make`.
      # Modern CMake passes the "" through as literal quote characters, so make ends
      # up with MAKEFLAGS='""' and aborts every (recursive) invocation with
      # `invalid option -- '"'`. Use an unquoted empty assignment instead.
      && sed -i 's/MAKEFLAGS=""/MAKEFLAGS=/' back-end/klee-1.4.0/runtime/CMakeLists.txt \
      # klee-libc reimplements memchr/strchr/strrchr with K&R definitions. Modern
      # glibc's <string.h> makes those identifiers const-generic macros (guarded by
      # __GLIBC_USE(ISOC23), which the runtime's -D_GNU_SOURCE turns on), so the
      # definitions fail to parse. These freestanding string routines do not need
      # _GNU_SOURCE, so undefine it for klee-libc only (the POSIX runtime keeps it).
      && sed -i '/LLVMCC.Flags += -D__NO_INLINE__/ s/$/ -U_GNU_SOURCE/' \
           back-end/klee-1.4.0/runtime/klee-libc/Makefile.cmake.bitcode \
      # klee-replay's file-creator.c configures a pty with the old SysV `struct termio`
      # / TCGETA / TCSETA, which modern glibc no longer provides. Switch to the current
      # `struct termios` / TCGETS / TCSETS (same fields are used).
      && sed -i 's/struct termio mode;/struct termios mode;/; s/TCGETA, &mode/TCGETS, \&mode/; s/TCSETA, &mode/TCSETS, \&mode/' \
           back-end/klee-1.4.0/tools/klee-replay/file-creator.c

# The source tree. The empty submodule dirs in the context do not clobber the
# clones above (Docker COPY merges, it does not delete).
COPY . /crete

# The `crete-version` CMake target shells out to `git rev-parse HEAD`. .git is
# excluded from the build context, so stand up a throwaway repo to satisfy it.
RUN git init -q \
      && git -c user.email=build@crete -c user.name=crete commit -q --allow-empty -m docker

# Build everything into /crete-build/bin. Boost/QEMU/KLEE/STP are CMake/autoconf
# ExternalProjects; the top-level make is parallelised across all cores (the
# nested boost/qemu builds use their own hardcoded -j7).
#
# GCC 14+ promoted several legacy-C constructs (implicit function declarations,
# implicit int, int<->pointer conversions) from warnings to hard errors by
# default. STP 2.1.2's bundled ABC and QEMU 2.3 predate that, so relax those
# back to warnings via CFLAGS -- CMake seeds CMAKE_C_FLAGS from $CFLAGS and QEMU's
# configure merges it, so this reaches the nested ExternalProject builds.
ENV CFLAGS="-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch"
RUN mkdir -p /crete-build \
      && cd /crete-build \
      && CXX=clang++-3.4 cmake /crete \
      && make -j"$(nproc)"

# The CRETE binaries are dynamically linked against the Boost 1.59 shared libs,
# which live in the build tree (bin/boost -> .../stage/lib) rather than a standard
# system path. Put that on the runtime loader path so the daemons can start.
ENV LD_LIBRARY_PATH="/crete-build/bin/boost:/crete-build/bin"

WORKDIR /crete-build
