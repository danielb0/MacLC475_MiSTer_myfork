#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$(pwd)
source_dir="$root/local/Main_MiSTer"
tool_name=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
tool_root="$root/local/tools"
tool_bin="$tool_root/$tool_name/bin"

for program in git make curl tar xz; do
    command -v "$program" >/dev/null || {
        echo "Missing WSL prerequisite: $program" >&2
        exit 1
    }
done
if [ ! -f "$source_dir/Makefile" ]; then
    echo "Missing Main checkout: $source_dir" >&2
    exit 1
fi
git -C "$source_dir" apply --reverse --check "$root/patches/Main_MiSTer-q605.patch"
git -C "$source_dir" apply --reverse --check "$root/patches/Main_MiSTer-swim2.patch"

if [ ! -x "$tool_bin/arm-none-linux-gnueabihf-gcc" ]; then
    mkdir -p "$tool_root"
    archive="$tool_root/$tool_name.tar.xz"
    echo 'Downloading the Arm GCC 10.2 toolchain used by Main.'
    curl --fail --location --retry 3 \
        "https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/$tool_name.tar.xz" \
        --output "$archive.part"
    mv "$archive.part" "$archive"
    tar -xJf "$archive" -C "$tool_root"
fi
PATH="$tool_bin:$PATH"
export PATH
arm-none-linux-gnueabihf-gcc --version | head -n 1

cd "$source_dir"
make -j"${JOBS:-2}"
test -s bin/MiSTer
echo "Built: $source_dir/bin/MiSTer"
sha256sum bin/MiSTer
