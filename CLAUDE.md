# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What CRETE is

CRETE is a binary-level concolic (concrete + symbolic) testing framework for automated
test-case generation and bug detection. It works on unmodified binaries (proprietary
programs, closed-source libraries, kernel modules) with no source or debug info required.
It runs the target inside an instrumented QEMU VM to capture a concrete execution trace,
then replays that trace symbolically through KLEE to generate new test cases.

Original project: SVL-PSU/crete-dev (Portland State University). See `user_manual.md` for
the full build/run walkthrough and `README.md` for the FASE 2018 paper.

## Building

Out-of-source CMake build. C++11 required; the toolchain is pinned to **LLVM/Clang 3.4**
(KLEE and the QEMU LLVM translator depend on it). Boost, KLEE, STP, and QEMU are all
built as CMake `ExternalProject`s. The Boost version is **1.59.0** (`lib/boost/` —
`boost_1_59_0`); it must be referenced consistently across the root `CMakeLists.txt`,
`lib/boost/CMakeLists.txt`, `back-end/CMakeLists.txt`,
`back-end/llvm-translator/CMakeLists.txt`, and `front-end/CMakeLists.txt` (the last three
hardcode the `boost_1_59_0` source path in their `--extra-cflags`/`-I` flags).

### Docker build (recommended on a modern host)

The native build below assumes the pinned toolchain (clang-3.4, cmake < 4, python2) is
already on the host — which no current distro ships. The **`Dockerfile` is the reproducible
build**: it builds LLVM/Clang 3.4 from source, back-fills gcc-4.8 / python2.7 from the
trusty pool, and applies the modern-toolchain adaptations needed for these 2014–2015
sources.

```bash
docker build -t crete .   # everything into /crete-build/bin
```

**If you touch the build, read `CRETE_FIXES.md` first.** It documents every adaptation and,
more importantly, the *systemic* mismatches behind them — the libstdc++ dual-ABI split
(everything must be `-D_GLIBCXX_USE_CXX11_ABI=0` to match clang-3.4/gcc-4.8), GCC-14+ hard
errors, glibc modernization (`sysmacros`, `SIGUNUSED`, `termio`, ISOC23 macros), and
LLVM/KLEE RTTI/EH coupling. Changes to the toolchain versions or Boost version will almost
certainly re-trigger some of these.

### Native build

```bash
mkdir ../crete-build && cd ../crete-build
CXX=clang++-3.4 cmake ../crete
make -j$(nproc)          # builds everything into crete-build/bin
```

Guest utilities are built separately, *inside the guest VM*, from `front-end/guest/`:

```bash
mkdir guest-build && cd guest-build && cmake ../guest && make
```

There is no lint step and no unit-test target in the default build. Regression tests
(`test/`) are `EXCLUDE_FROM_ALL` — build them explicitly with `make crete-test-*` targets
or run `test/regression/coreutils-6.10/{prepare-test.sh,run-test.sh}`.

## Architecture

CRETE splits into a **front-end** (concrete tracing, runs the target) and a **back-end**
(symbolic execution + orchestration). They communicate over TCP; a run is driven by three
back-end daemons plus a guest agent.

### Front-end (`front-end/`)
- `qemu-2.3/` — a patched QEMU 2.3 (`crete-qemu-2.3-system-x86_64`). Instrumented to
  capture the binary-level execution trace via custom opcodes and dynamic taint analysis.
  Built with `--enable-tcg-interpreter`.
- `guest/` — utilities compiled and run *inside the guest OS*:
  - `util/run/` → `crete-run`, the guest agent that reads the XML config, marks
    args/files/stdin as concolic, and hands control to the CRETE-instrumented QEMU.
  - `util/tc-replay/` → replays generated test cases.
  - `kernel-modules/` — kprobe-based modules for tracing kernel APIs / drivers.
  - `lib/` — guest-side copies of the shared libs (asio, boost, test-case, vm-comm, …).

### Back-end (`back-end/`)
- `klee-1.4.0/` — git submodule, a CRETE-specific KLEE fork. Symbolically re-executes the
  captured trace. Built as an ExternalProject, installed as `crete-klee` / `crete-klee-1.4.0`.
- `llvm-translator/` — translates the QEMU-captured trace into self-contained LLVM bitcode
  that KLEE consumes (`crete-llvm-translator-qemu-2.3-x86_64`).
- `manager/` — the three orchestration daemons (thin `*_ui.cpp` wrappers over `lib/cluster`):
  - `dispatch/` → `crete-dispatch`, the coordinator; owns the trace/test-case pools and
    scheduling, tracks coverage (`coverage.cpp`).
  - `vm-node/` → `crete-vm-node`, manages concrete QEMU VM instances (must launch from the
    same dir as `crete-qemu`).
  - `svm-node/` → `crete-svm-node`, manages symbolic (KLEE) executor instances.

### Shared libraries (`lib/`, headers in `lib/include/crete/`)
Everything under the `crete::` namespace. Key pieces:
- `cluster/` — the actual dispatch / vm-node / svm-node logic. The daemons in
  `back-end/manager` are just UIs; behavior lives here, largely as Boost.MSM state machines
  (`*_fsm.cpp`).
- `test-case/`, `elf-reader/`, `proc-reader/`, `logger/`, `asio/` — test-case
  serialization, ELF/`/proc` parsing, logging, and the ASIO-based transport used between
  nodes.
- `replay-preload/` — LD_PRELOAD shim for test-case replay.

### Run model (see `user_manual.md` §4)
1. In the guest, `crete-run -c crete.xml` waits for the back-end. The XML config declares
   the target `<exec>` and which `<args>`/`<files>`/`<stdin>` are `concolic`.
2. On the host, start `crete-dispatch`, `crete-vm-node`, and `crete-svm-node` (each with its
   own XML config). Dispatch coordinates: vm-node produces concrete traces, svm-node feeds
   them through the llvm-translator + KLEE to emit new test cases, loop until the
   trace/test-case/time interval budget is exhausted.

Config files throughout are XML; example configs live in `test/regression/` and
`misc/scripts/`.

## Conventions & gotchas
- The pinned LLVM 3.4 / Clang 3.4 and QEMU 2.3 versions are load-bearing — do not casually
  bump them.
- ASLR must be disabled in the guest (program addresses must be stable across iterations).
- Snapshot-based QEMU boot is the normal workflow; boot commands (memory, image) must match
  exactly between `savevm` and `loadvm`, and cannot cross kvm/non-kvm modes.
- `CRETE-VERSION` is generated at build time from `git rev-parse --short HEAD` and copied
  into `front-end/guest/`; don't hand-edit it.
- `debian-package/` + the CPack config in the root `CMakeLists.txt` produce a `.deb`.
- The KLEE fork isn't vendored — the `Dockerfile` clones it (pinned SHA) and `sed`-patches
  it in place for modern make/glibc. Edits to KLEE source must go in that Dockerfile step,
  not the working tree.
- Everything CRETE links must share the **old** libstdc++ `std::string` ABI. The Dockerfile
  builds LLVM and Boost with `-D_GLIBCXX_USE_CXX11_ABI=0`; if you add another
  modern-GCC-built dependency, pin it the same way or its `std::string` symbols won't link.
- The CRETE daemons load Boost's shared libs from the build tree, not a system path — the
  Dockerfile sets `LD_LIBRARY_PATH=/crete-build/bin/boost:/crete-build/bin` for runtime.
