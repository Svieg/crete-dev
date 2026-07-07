# CRETE build fixes (Boost 1.59.0 on a modern toolchain)

This document records the changes made to build CRETE — which is pinned to
**LLVM/Clang 3.4**, **QEMU 2.3**, **KLEE 1.4.0**, **STP 2.1.2** and **Boost 1.59.0**
(all circa 2014–2015) — inside a Docker image based on current Ubuntu (GCC 15,
glibc ≥ 2.38). The project had a half-finished migration to Boost 1.88; that was
reverted back to **Boost 1.59.0** and the build pipeline was updated so the whole
tree compiles, links, and runs.

The build succeeds end to end (`docker build -t crete .`) and the resulting
daemons (`crete-dispatch`, `crete-vm-node`, `crete-svm-node`), the instrumented
QEMU, the LLVM translator, and KLEE all load and start.

---

## Recurring root causes

Most individual fixes are instances of a few systemic mismatches between the
2014-era sources and the modern host toolchain:

1. **libstdc++ dual ABI.** GCC 5 introduced the `std::__cxx11` `std::string`/`std::list`
   ABI, now the default. CRETE itself is compiled by **clang-3.4 against gcc-4.8's
   libstdc++, which only has the *old* ABI**. Anything built by the modern GCC that
   CRETE links against (LLVM, Boost) must be pinned to the old ABI
   (`-D_GLIBCXX_USE_CXX11_ABI=0`), or every `std::string` in its API becomes a
   link-time undefined reference.
2. **GCC 14+ hard errors.** Implicit function declarations, implicit `int`, and
   `int`↔pointer conversions are now errors, not warnings. Legacy C in STP/ABC,
   QEMU 2.3, and Boost 1.59's build engine trips over this.
3. **glibc modernization.** `major()`/`minor()`/`makedev()` moved to
   `<sys/sysmacros.h>`; `SIGUNUSED` and the SysV `struct termio` were dropped;
   `<string.h>` gained const-generic macros under `__GLIBC_USE(ISOC23)`.
4. **New libstdc++ headers under an old compiler.** clang-3.4 / g++-15 choking on
   `inline namespace`, `std::unary_function`, `std::auto_ptr`, etc.

---

## Boost: reverted 1.88 → 1.59.0

* Restored `lib/boost/boost_1_59_0.tar.bz2`, removed `boost_1_88_0.tar.bz2`.
* Reverted every `boost_1_88_0` → `boost_1_59_0` path reference in the root,
  `back-end`, `back-end/llvm-translator`, and `front-end` CMakeLists (back to the
  original `HEAD` versions).

Boost 1.88 required porting CRETE's own sources (`io_service`→`io_context`, the
vendored `boost::process`, `std::align` which gcc-4.8's libstdc++ lacks), which is
a much larger effort than a build fix — hence the revert.

---

## Fixes by area

### 1. LLVM 3.4 build — `Dockerfile`

Added two cmake options to the from-source LLVM build:

| Flag | Why |
|------|-----|
| `-D_GLIBCXX_USE_CXX11_ABI=0` (in `CMAKE_CXX_FLAGS`) | Old `std::string` ABI, to match the clang-3.4/gcc-4.8 consumers (translator, KLEE, CRETE libs). Otherwise `verifyModule`, `raw_fd_ostream`, … are undefined at link. |
| `-DLLVM_REQUIRES_RTTI=ON` | LLVM defaults to `-fno-rtti`. CRETE's KLEE replayer serializes with Boost.Serialization (needs `typeid`/`dynamic_cast`), so KLEE must keep RTTI, which means the LLVM it links must carry RTTI too — else `typeinfo for llvm::cl::Option` is undefined at link. **Note:** the 3.4 knob is `LLVM_REQUIRES_RTTI`; the later `LLVM_ENABLE_RTTI` name is silently ignored. |

### 2. Boost 1.59 build — `lib/boost/CMakeLists.txt` + `lib/boost/fix-boost-build-gcc15.sh` (new)

* Boost 1.59's bundled Boost.Build engine (`b2`) is 2015-era C that does not
  compile with GCC 15 (implicit decls/int are now errors). `fix-boost-build-gcc15.sh`
  relaxes the engine's **two** build stages (`build.sh` for the bootstrap `jam0`,
  `build.jam` for the real `b2`), wired in via `PATCH_COMMAND`.
* Libraries are built old-ABI and against an older standard:
  `./b2 toolset=gcc cxxflags=-D_GLIBCXX_USE_CXX11_ABI=0 cxxflags=-std=gnu++14 cxxflags=-fpermissive cxxflags=-w cflags=-fcommon cflags=-w`
  (`-std=gnu++14` keeps `std::auto_ptr`/`std::unary_function` that C++17 removed;
  `-fcommon` for the pre-GCC-10 C).

### 3. KLEE fork patches — `Dockerfile` (applied right after the KLEE clone)

KLEE 1.4.0 is a git clone made inside the image, so these are `sed` patches:

* **`runtime/CMakeLists.txt`** — the bitcode-runtime step clears MAKEFLAGS via
  `env MAKEFLAGS="" make`; modern CMake passes the `""` as literal quote characters,
  so make aborts with `invalid option -- '"'`. Changed to an unquoted `MAKEFLAGS=`.
* **`runtime/klee-libc/Makefile.cmake.bitcode`** — klee-libc reimplements
  `memchr`/`strchr`/`strrchr` with K&R definitions, which modern glibc turns into
  const-generic macros (under `__GLIBC_USE(ISOC23)`, enabled by the runtime's
  `-D_GNU_SOURCE`). Appended `-U_GNU_SOURCE` **for klee-libc only** (freestanding
  string routines don't need it; the POSIX runtime keeps `_GNU_SOURCE`).
* **`tools/klee-replay/file-creator.c`** — configures a pty with the SysV
  `struct termio` / `TCGETA` / `TCSETA`, which modern glibc dropped. Switched to
  `struct termios` / `TCGETS` / `TCSETS` (same fields used).

### 4. KLEE compile flags — `back-end/CMakeLists.txt`

* Added **`-fno-exceptions`** to `KLEE_CXX_FLAGS`. KLEE disables exceptions only
  when `llvm-config --cxxflags` advertises `-fno-exceptions` (its
  `cmake/find_llvm.cmake` → `LLVM_ENABLE_EH`). Stock LLVM 3.4 does; our from-source
  LLVM does not, so we force it. Without it, Boost never defines
  `BOOST_NO_EXCEPTIONS` and crete-replayer's `boost::throw_exception` override
  (which only exists under `BOOST_NO_EXCEPTIONS`) matches no declaration.
* RTTI is intentionally **left on** (see the LLVM `LLVM_REQUIRES_RTTI=ON` above),
  because Boost.Serialization needs it.

### 5. Front-end QEMU — `front-end/CMakeLists.txt`

* `--disable-guest-agent` and `--disable-virtfs` — both `qga/commands-posix.c` and
  `hw/9pfs/virtio-9p.c` call `major()`/`minor()`/`makedev()` without
  `<sys/sysmacros.h>` and fail to *link* on glibc ≥ 2.28. Neither feature is used
  by CRETE, so they are not built.
* `-D_GLIBCXX_USE_CXX11_ABI=0` added to **`--extra-cflags`** (not `--extra-cxxflags`).
  The front-end QEMU's `rules.mak` rebuilds `QEMU_CXXFLAGS` from `QEMU_CFLAGS` at
  build time, discarding `--extra-cxxflags`; routing the ABI define through
  `--extra-cflags` (a no-op for the C files) reliably reaches the C++ compiles, so
  `runtime-dump/*` link against the old-ABI Boost libs instead of emitting
  `std::__cxx11` references.

### 6. Front-end QEMU C++ sources — `front-end/qemu-2.3/runtime-dump/*.cpp`

Added `#undef inline` after the QEMU `extern "C"` header block (before the Boost
includes) in `runtime-dump.cpp`, `custom-instructions.cpp`, `tci_analyzer.cpp`,
`crete-debug.cpp`. QEMU's `osdep.h` does `#define inline __attribute__((always_inline)) __inline__`
under `__OPTIMIZE__`; that macro leaked into modern libstdc++ headers, which use
`inline namespace` (`__cxx11`, `_V2`), breaking the C++ standard library parse.

### 7. Shared header — `lib/include/crete/common.h`

Added a fallback `#define SIGUNUSED SIGSYS` (guarded, plus `#include <signal.h>`).
`SIGUNUSED` (historically 31 == `SIGSYS`) was removed from glibc's `<signal.h>`;
several CRETE exit-code range checks still use it as the upper signal bound.

### 8. Runtime library path — `Dockerfile`

Added `ENV LD_LIBRARY_PATH=/crete-build/bin/boost:/crete-build/bin`. The CRETE
daemons are dynamically linked against the Boost 1.59 shared libs, which live in
the build tree (`bin/boost` → `…/stage/lib`) rather than a system path; without
this the daemons fail to load `libboost_thread.so.1.59.0` at startup.

---

## Changed / added files

**Modified (tracked):**
- `Dockerfile`
- `back-end/CMakeLists.txt`
- `front-end/CMakeLists.txt`
- `lib/boost/CMakeLists.txt`
- `lib/include/crete/common.h`
- `front-end/qemu-2.3/runtime-dump/{runtime-dump,custom-instructions,tci_analyzer,crete-debug}.cpp`

**Added:**
- `lib/boost/fix-boost-build-gcc15.sh`
- `lib/boost/boost_1_59_0.tar.bz2` (restored)

**Removed:**
- `lib/boost/boost_1_88_0.tar.bz2`

---

## Verification

```bash
docker build -t crete .          # completes at 100%, exit 0
```

Produced binaries in `/crete-build/bin` (all load their shared libs):
`crete-dispatch`, `crete-vm-node`, `crete-svm-node`,
`crete-qemu-2.3-system-x86_64`, `crete-llvm-translator-qemu-2.3-{i386,x86_64}`,
`crete-klee-1.4.0`.

```bash
docker run --rm crete /crete-build/bin/crete-dispatch   # reaches normal arg parsing, no loader error
```
