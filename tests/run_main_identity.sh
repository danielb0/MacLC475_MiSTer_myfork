#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p local/tests
source_dir=local/Main_MiSTer
c++ -std=gnu++14 -D_FILE_OFFSET_BITS=64 -D_LARGEFILE64_SOURCE \
    -Wall -Wextra -Werror -ffunction-sections -fdata-sections -I"$source_dir" \
    tests/test_main_q605.cpp "$source_dir/support/mac/mac.cpp" \
    -Wl,--gc-sections -o local/tests/test_main_identity
local/tests/test_main_identity
