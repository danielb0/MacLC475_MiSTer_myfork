"""Decode the opt-in SWIM II UART trace (version 1)."""
import argparse
import re
import sys
from pathlib import Path

EVENTS = ("write-start", "write-end", "write-error", "decoded", "committed",
          "decode-reject", "save-request", "save-retired", "storage-fault",
          "mount", "release", "guest-reset", "save-ack-high", "save-ack-low")


def unpack(hex_text):
    value = int(hex_text, 16)
    fields = {}
    for name, width in (("version", 4), ("status", 8), ("error", 8), ("dropped", 16),
                        ("host_lba", 32), ("commit_addr", 22), ("decode_addr", 22),
                        ("context", 32), ("clocks", 32), ("events", 16)):
        fields[name] = value & ((1 << width) - 1)
        value >>= width
    if fields["version"] != 1:
        raise ValueError(f"unsupported trace version {fields['version']}")
    return fields


def format_record(fields, clock_hz):
    events, context, status = fields["events"], fields["context"], fields["status"]
    labels = [name for bit, name in enumerate(EVENTS) if events & (1 << bit)]
    if events >> len(EVENTS):
        labels.append(f"unknown={events >> len(EVENTS):X}")
    track, head, anchor = (context >> 9) & 127, (context >> 8) & 1, (context >> 3) & 31
    valid, busy = (context >> 2) & 1, (context >> 1) & 1
    mode, setup = context >> 24, (context >> 16) & 255
    text = (f"t={fields['clocks'] / clock_hz:.6f} clocks={fields['clocks']:08X} "
            f"{','.join(labels) or 'heartbeat'} CHS={track}/{head}/{anchor} "
            f"anchor={valid} busy={busy} mode={mode:02X} setup={setup:02X}")
    if events & 1 and valid and not (setup & 64):
        spt = 18 if status & 4 else 9
        text += f" anchor_lba={(track * 2 + head) * spt + anchor - 1}"
    for bit, name in ((3, "decode_addr"), (4, "commit_addr")):
        if events & (1 << bit):
            text += f" {name}={fields[name]:06X} lba={fields[name] // 512}"
    if events & 0x31C0:
        text += f" host_lba={fields['host_lba']}"
    return text + f" error={fields['error']:02X} status={status:02X} dropped={fields['dropped']}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--clock-hz", type=int, default=25_000_000)
    args = parser.parse_args()
    if args.clock_hz <= 0:
        parser.error("--clock-hz must be positive")
    malformed = frames = losses = 0
    for line in args.capture.read_text(encoding="ascii", errors="replace").splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"W([0-9A-Fa-f]{48})", line)
        if not match:
            malformed += 1
            continue
        try:
            fields = unpack(match[1])
        except ValueError as error:
            parser.error(str(error))
        print(format_record(fields, args.clock_hz))
        frames += 1
        losses = max(losses, fields["dropped"])
    if not frames:
        parser.error("no complete SWIM II trace frames")
    if malformed or losses:
        print(f"Incomplete capture: {malformed} malformed lines; maximum reported drops {losses}.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
