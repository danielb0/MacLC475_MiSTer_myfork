#!/usr/bin/env python3
"""Convert a raw CUDA ROM binary to the byte-per-line $readmemh format."""

import argparse
from pathlib import Path
import sys


ROM_SIZE = 4352
DEFAULT_INPUT = Path("cuda341s0788.bin")
DEFAULT_OUTPUT = Path("local/software/cuda341s0788.hex")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "binary", nargs="?", type=Path, default=DEFAULT_INPUT,
        help=f"raw 341S0788 ROM binary (default: {DEFAULT_INPUT})",
    )
    parser.add_argument(
        "output", nargs="?", type=Path, default=DEFAULT_OUTPUT,
        help=f"output byte-per-line hex file (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    try:
        data = args.binary.read_bytes()
    except OSError as error:
        parser.error(f"cannot read {args.binary}: {error}")

    if len(data) != ROM_SIZE:
        parser.error(
            f"{args.binary} is {len(data)} bytes; expected exactly {ROM_SIZE}"
        )

    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text("".join(f"{byte:02x}\n" for byte in data), encoding="ascii")
    except OSError as error:
        parser.error(f"cannot write {args.output}: {error}")

    print(f"Wrote {ROM_SIZE} bytes to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
