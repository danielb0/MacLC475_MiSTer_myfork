#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p local/tests
source_dir=local/Main_MiSTer
c++ -std=gnu++14 -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE \
    -Wall -Wextra -Werror -I"$source_dir" \
    tests/test_main_swim2.cpp "$source_dir/support/mac/swim2.cpp" \
    -Wl,--wrap=fseeko64,--wrap=fwrite,--wrap=fflush,--wrap=fsync,--wrap=fstat64,--wrap=fread,--wrap=ferror \
    -o local/tests/test_main_swim2
for core in MacLC475 MACLC475_TRACE MacQuadra605; do
    local/tests/test_main_swim2 "$core"
done
