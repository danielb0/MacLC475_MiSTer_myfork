"""Check trace decoding against the UART fixture and malformed captures."""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/decode_swim2_trace.py"
spec = importlib.util.spec_from_file_location("swim2_trace", SCRIPT)
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)

# The HDL fixture's known UART output, including simultaneous events.
golden = "2159000000041234567848D15A3456789ABCDEF0000A55A1"
fields = trace.unpack(golden)
assert fields == dict(version=1, status=0x5a, error=0xa5, dropped=0, host_lba=0x89abcdef,
                      commit_addr=0x234567, decode_addr=0x123456, context=0x12345678,
                      clocks=4, events=0x2159)
text = trace.format_record(fields, 25_000_000)
for item in ("write-start", "decoded", "committed", "save-request", "storage-fault",
             "save-ack-low", "host_lba=2309737967", "error=A5", "dropped=0"):
    assert item in text, (item, text)

with tempfile.TemporaryDirectory(dir=ROOT / "local/tests") as directory:
    assert Path(directory).resolve().is_relative_to(ROOT / "local/tests")
    capture = Path(directory) / "capture.txt"

    def decode(contents):
        capture.write_text(contents, encoding="ascii")
        return subprocess.run([sys.executable, str(SCRIPT), str(capture)], capture_output=True, text=True)

    result = decode("W" + golden + "\r\n")
    assert result.returncode == 0 and "decoded" in result.stdout and not result.stderr
    result = decode("partial\nW" + golden + "\n")
    assert result.returncode == 1 and "1 malformed" in result.stderr
    result = decode("W" + f"{int(golden, 16) | (7 << 20):048X}" + "\n")
    assert result.returncode == 1 and "drops 7" in result.stderr
    result = decode("W" + golden[:-1] + "2\n")
    assert result.returncode != 0 and "unsupported trace version 2" in result.stderr
    result = decode("W1234\n")
    assert result.returncode != 0 and "no complete" in result.stderr

capture = ROOT / "local/tests/swim2_trace_capture.txt"
if capture.exists():
    result = subprocess.run([sys.executable, str(SCRIPT), str(capture)], capture_output=True, text=True)
    assert result.returncode == 1 and "maximum reported drops" in result.stderr
    assert len(result.stdout.splitlines()) == 130
print("PASS: SWIM II trace decoder, UART fixture, field order, malformed/version/loss handling")
