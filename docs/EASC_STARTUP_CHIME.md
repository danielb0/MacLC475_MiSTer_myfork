# The startup chime and the sound chip's identity

The core played the Mac II chime (four wavetable voices) because `rtl/easc.sv`
answered 0 at its version register, `$50F14800`. The LC 475 ROM then takes the
path for the original Apple Sound Chip. The chip now answers `$B0` and has the
registers the ROM's `$B0` path uses, including the CD-XA decoder the chime
needs.

Sources:

- **ROM**: the LC 475 ROM, MD5 `76FAB51D93F024D805FAFD8F5C8F46A3`, base
  `$40800000`. Addresses below are in that image.
- **HO**: *Macintosh Hardware Overview*, Apple, February 1991, "Sound Output
  Hardware", pp. 44-45 (Batman, the enhanced sound chip).
- **EST**: a reasoned estimate where neither says.

## What the ROM does at startup

The boot beep is at `$408BD250`, reached from `$40845C0A`.

| Version at `$800` | Path |
|---|---|
| `$00` | `$40807052`: the Mac II chime, wavetable mode, four voices |
| exactly `$B0` | a `snd ` at `$408C2722`, or the one at `$408BD4C4` if PRAM `$10` is `$A8` and PRAM `$89` bit 1 is set |
| any other non-zero | a `snd ` at `$408C67BE`: raw 8-bit, 22254 Hz, 31178 samples |

The two `$B0` sounds are compressed: sampled-sound header `encode = $FE`,
22050 Hz, `compressionID = 6`, `packetSize = 120` bits, 1096 and 1399 packets.
That is CD-XA ADPCM, 15 bytes for 28 samples. For them the ROM:

1. runs the sound setup at `$40804266` (gains, interrupt masks, FIFO clear,
   `$801 = 1`, rate `$812F`, coefficients, `$F08/$F28 = $80`);
2. writes `rate * $FFFF / 44100` to `$F04` and `$F24` (`$408BD342`);
3. writes `$80 | mode` to `$F08` and `$F28`, mode 1 for `compressionID` 5 and
   2 for 6 (`$408BD35A`), and reads `$F08` back;
4. writes the **compressed** bytes, each to FIFO A and FIFO B, one byte every
   time `$804` bit 2 is set (`$408BD3B2`);
5. waits for `$804` bit 3, then runs the setup again.

So with `$B0` the decoder must be in the chip. HO lists CD-XA decompression
and sample rate conversion among Batman's additions.

The first compressed sound and the raw sound are the same chime: decoded with
the standard CD-XA coefficients, low nibble first, `$408C2722` matches
`$408C67BE` sample for sample (correlation 0.9998, residual under one 8-bit
step). That comparison is what fixes the nibble order and the header layout.

The four error chimes (`$40845C1C`) are synthesised by the ROM and written to
the FIFOs as raw bytes; they need no decoder.

## Why `$B0`

- `$408042E8`: for `(version & $F0) == $B0` the ROM programs the `$F00`
  block. The code for decoder kind `$0D`, the table at `$408A8680` with this
  machine's addresses, is inside that branch (`$40804328`). So the chip is a
  `$Bx` part. (ROM)
- The ROM names three `$Bx` values: `$B0`, `$BB`, `$BC`. Its register test
  gives only `$B0` the `$F08/$F28` test (`$4084871A`) and the idle status
  `$0F` (`$40849D74`); the kind-`$0D` code writes the `$F20` block directly
  (`$40804344`). `$B0` is the estimate that fits. No Apple document at hand
  states the value. (EST)

The same ROM code is in the Quadra 700/900 ROM with only the compressed
sounds, and in the Mac IIvx ROM with only the raw one, so the split is by
chip, not by machine.

## Registers and what each rests on

"ch" is `$00` for FIFO A and `$20` for FIFO B.

| Register | Behaviour | Basis |
|---|---|---|
| `$800` | `$B0` | above |
| `$801` | bits 1:0 stored; 1 = FIFO mode; no wavetable mode | ROM test mask `$03` (`$4084871A`); HO: Batman removes the wavetable modes |
| `$803` bit 7 | clears both FIFOs | ROM `$40845C90` |
| `$804` | live: bit 0 A half-empty, 1 A empty, 2 B half-empty, 3 B empty | ROM `$40849D74` (idle = `$0F`), `$408BD3B2`, `$408BD3D2` |
| `$806` | bits 7:5, eight volume steps | ROM test mask `$E0`, `$408042E4` |
| `$80A` | bits 1:0 stored, no function | ROM test mask `$01`; bit 0 is record enable in the ROM's input test |
| `$F00+ch`, `$F02+ch` | write and read pointers, read-only | EST; the ROM only saves and restores them (`$408B4D08`) |
| `$F04+ch` | sample rate, `rate * 65536 / 44100`; `$812F` after reset | ROM `$408BD342`, `$40804376`; reset value EST |
| `$F06+ch`, `$F07+ch` | this FIFO's gain into left and right; `$7F` full, taken as gain/128 | ROM `$408042F8`, `$4088C490`; HO (mixing and panning); scale EST |
| `$F08+ch` | bits 1:0: 0 raw, non-zero CD-XA; bit 7 stored; a write restarts the decoder | ROM `$408BD35A`, test values at `$4084871A`; restart EST |
| `$F09+ch` | bit 0 = 1 masks the FIFO's interrupt; 1 then 0 raises it again below half | ROM `$40845C7E`, `$40849ECC`, `$40871B84` |
| `$F10-$F17+ch` | CD-XA coefficients, fixed at `$0000 $003C $CC73 $C962` | ROM `$40804382` always writes these; fixed to save logic (EST) |

Interrupt: an edge when a pop takes a FIFO below half, cleared by reading
`$804` or by masking, only in FIFO mode (EST, kept from the previous
revision, which documents why a level hangs Mac OS).

## Not implemented

- Sound input. The ROM's input test (`$40849F4E`, `$80A = 3`) cannot pass.
- The chip's interpolation to 44.1 kHz: a FIFO is popped at its own rate and
  the sample held.
- Writable CD-XA coefficients; a difference between modes 1, 2 and 3.
- Writable FIFO pointers.

## Logic

One 16x10 multiplier is shared by the decoder, the mixer and the volume. The
four wavetable voices and the two volume multipliers are removed. Estimated
net change: within about 60 ALMs of the previous revision either way, one DSP
block instead of two, the same four M10K blocks. Not compiled.

## Verification

`tests/run_easc.sh` (Verilator): the ROM's register test values, the setup
sequence and its read-back, raw FIFO order, rate, status bits, mixing and
volume, the interrupt as the ROM's FIFO test uses it, and 16800 CD-XA samples
per channel from pseudo-random packets against a reference model. Planted
faults in the coefficients, the shift, the saturation and the nibble order
are caught.

With `CHIME=<hex bytes of the ROM sound>` the bench plays the ROM's chime the
way the ROM does. All 30688 samples per channel match the reference, and the
44.1 kHz output correlates 0.9997 with the ROM's raw copy.

Not verified without the board: that the ROM reaches this path on the core
(the bench drives the chip alone, not the CPU running the ROM), how the chime
sounds through the core's audio output, and Mac OS sound. The System's Sound
Manager will now drive the chip as a `$B0` part instead of as the original
chip, and its code was not examined.
