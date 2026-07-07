#!/bin/sh
# Make Boost 1.59's bundled Boost.Build engine (b2/bjam) compilable with a modern
# GCC (14/15+). The engine is 2015-era C that relies on implicit function
# declarations / implicit int / int<->pointer conversions, which GCC 14 promoted
# from warnings to hard errors. It is built in two stages, each with its own
# hardcoded gcc flags that ignore $CFLAGS, so both must be relaxed:
#
#   * build.sh  -- compiles the bootstrap jam0 (hardcodes `BOOST_JAM_CC=gcc`).
#   * build.jam -- jam0 then uses this to compile the real b2 (gcc toolset flags).
#
# Run from the Boost source root (ExternalProject PATCH_COMMAND cwd).
set -e

LENIENT='-Wno-implicit-function-declaration -Wno-implicit-int -Wno-int-conversion -fcommon'

sed -i "s|^    BOOST_JAM_CC=gcc\$|    BOOST_JAM_CC=\"gcc ${LENIENT}\"|" \
    tools/build/src/engine/build.sh

sed -i "s|: -pedantic -fno-strict-aliasing|: -pedantic -fno-strict-aliasing ${LENIENT}|g" \
    tools/build/src/engine/build.jam
