# Hardware coverage and expansion review

Assessed 2026-11-05 at `a0f7575`, branch `diag/swim2-trace`.
Source review, existing Quartus reports, and the fresh checks below; no new
Quartus build or MiSTer hardware testing. No implementation changed.

## Conclusion

The major machine blocks are integrated, but the machine is not fully
implemented or fully qualified. SWIM II and PrimeTime have functional paths
and explicit fidelity gaps. The largest resource constraint is on-chip RAM.
An Apple IIe card remains plausible with external memory; an all-BRAM card
cannot be added to the present memory allocation.

## Coverage

| Area | Implemented | Missing or unqualified |
| --- | --- | --- |
| LC040 | Integer CPU, caches, MMU, LC040 exception adaptation and machine bus integration | Directed execution passes below; not exhaustive instruction/cycle fidelity. V-Integer failure and real-machine performance remain unexplained. No FPU is intentional. |
| MEMCjr | Bank mapping, memory top, six-bit holding latch, RAM/ROM/VRAM transactions | Config/refresh/test registers retain values without programming physical timing or SDRAM refresh (`rtl/memcjr.sv:27-93`). Real LC475 wait-state/performance comparison pending. |
| PrimeTime | I/O decode, byte steering, VIA1, pseudo-VIA interrupt aggregation, SCSI pseudo-DMA, SWIM II integration, sound playback | Config registers are scratch readback (`rtl/iosb.sv:291-304,994-1014`); pseudo-VIA DFAC-related outputs ignored (`:983`). Not a complete timing/configuration model. |
| Video / Antelope | CLUT, 1/2/4/8-bit pixels, framebuffer base/stride, monitor sense and VBL; 640x480 and 512x384 scanout | No 16-bit pixel path. CRTC parameters are stored without driving scan timing; cursor/animation line registers do not generate their corresponding events (`rtl/dafb.sv:216-237,318-325,350-372`). VRAM is compacted and aliased, not independent 512 KiB storage (`MacLC475.sv:1055-1105`). |
| Sound / DFAC | Stereo FIFO playback, four-voice wavetable, refill IRQ and volume | No recording/input buffer path; `rtl/easc.sv:73-87` has outputs but no audio input. Classic ASC identification avoids an unimplemented extended interface (`:44-46`). Fixed sample-rate enable (`:221-224`); clock register is stored/read back only (`:198,300`). CUDA I2C is disconnected (`rtl/iosb.sv:184`). |
| CUDA / ADB / RTC | Firmware-running HC05, GPIO/timers, VIA handshakes, ADB keyboard/mouse, PRAM host persistence | Broader reset, time, input-device and persistence qualification pending. Some physical board signals are tied inactive (`rtl/iosb.sv:174-184`). |
| SCC / serial | Register model, UART-backed paths, baud generation and loopback | No LocalTalk synchronous reception; printer RX tied high (`rtl/scc.v:1022`, `MacLC475.sv:708`). External clock/status behavior simplified. Serial/MIDI hardware qualification pending. |
| SCSI | Controller registers/FIFO/counts, selection/transfer phases, pseudo-DMA, virtual HDD/CD targets | Virtual target implementation rather than a physical SCSI bus (`rtl/ncr53c96.sv:2-7`). Supported operations/error recovery need qualification; not every bus mode or arbitrary target is modeled. |
| Expansion | Address decoding rejects absent devices | No PDS/card target or active expansion-slot interrupt source (`rtl/lc475.sv:605-623`, `rtl/iosb.sv:258`). |

PrimeTime contains SWIM II, VIAs, I/O steering and sound logic; SCC and SCSI
are separate chips. Apple documents sound input plus stereo output buffers
and Antelope 16-bit color. It explicitly excludes 24-bit pixels, so lack of
24-bit color is not a missing LC475 feature. See Apple's
[LC475/Quadra605 developer note](https://leopard-adc.pepas.com/documentation/Hardware/Developer_Notes/Macintosh_CPUs-68K_Desktop/Mac_LC_475_Quadra_605.pdf),
printed pages 24-26.

Ethernet and MT32-pi are disabled optional enhancements, not missing stock
LC475 hardware. SCC comments about missing ESCC extensions alone do not
establish a stock-machine defect: Apple's note identifies an 8530 SCC.

## SWIM II

Implemented: register/FIFO/handshake/error logic, parameter RAM, drive
selection/sense/motor/tach/index/write protection, MFM and zoned GCR codecs,
SDRAM image buffering, checked host reads, committed writes, explicit host
save results, retries and persistence-aware eject/replacement.
The loader accepts exact raw 400K/800K/720K/1.44M payload sizes
(`rtl/swim2_loader.sv:52-53`).

Remaining limits:

- On-hardware HFS catalog corruption is unresolved. A referenced node at
  LBA 30 remains zero; this locates incomplete data, not the failing layer.
  Capture instructions and evidence: `docs/SWIM2_TRACE.md:3-18`.
- Decoded-byte media model rather than physical flux/read-separator behavior.
  RDDATA, phase input, zero counter and short/long cell inputs are constants;
  early/late write outputs are disconnected
  (`rtl/swim2_subsystem.sv:133-142`).
- Time0 fixed, Time1 unused, parameter reset/readback unqualified
  (`rtl/swim2.sv:50-52`). Step completion is immediate
  (`rtl/swim2_drive.sv:58`); settling/tach fidelity remains unqualified.
- Raw GCR images discard written tags and synthesize zero read tags.
  Tag containers, cross-geometry formatting and CRC-token edge behavior
  need qualification (`rtl/swim2_media/UPSTREAM.md:188-199`).
- SDRAM arbitration does not bound floppy service under continuous CPU
  posted writes (`rtl/swim2_media/UPSTREAM.md:183`). This is a risk to
  investigate, not a demonstrated cause of corruption.

Do not count absent IWM mode as a proven SWIM II defect without a matching
chip reference. The old "not fitted" statement in the media upstream notes
is stale; detailed codec limitations remain supported by current RTL.

## Resource budget

Latest local report: successful 2026-11-04 trace build, identified as
`9ed2fd9` in `docs/SWIM2_TRACE.md`. It is not a fresh fit of reviewed HEAD.
Source: `output_files/MacLC475.fit.summary` and `.fit.rpt`.

| Resource | Used / available | Remaining |
| --- | --- | --- |
| ALMs needed, fitter estimate | 31,607 / 41,910 | 10,303 (24.6%) |
| M10K RAM blocks | 510 / 553 | 43 (7.8%) |
| DSP blocks | 36 / 112 | 76 |
| PLLs | 4 / 6 | 2 |

The fitter actually places 35,173 ALMs (84%) and estimates 4,088 recoverable
by denser packing. Partially/fully used LABs are 3,989/4,191 (95%), with
packing difficulty reported low. Neither 95% LAB occupancy nor the 75%
ALM estimate is a hard prediction of the next design's fit. Routing and
timing can limit expansion before a nominal resource count is exhausted.

The 67% logical RAM-bit figure is misleading for expansion: allocated RAM
implementation bits are 92%. Free 43 M10Ks provide at most 53.75 KiB of raw
bits, less with width/port fragmentation. RAM cannot be pooled arbitrarily
from unused bits inside already allocated blocks.

Hierarchy figures (inclusive; do not add nested rows): CPU adapter about
14,629 ALMs / 90 M10Ks; IOSB 5,300 / 25; floppy platform 1,603 / 9;
trace recorder 264 / 5. Four VRAM byte-lane arrays use 81 M10Ks each:
**324 blocks**, the dominant memory cost. Removing trace alone saves little.

All reported constrained timing checks have positive slack: minimum setup
0.398 ns, hold 0.117 ns. This is not complete board timing signoff:
`.sta.rpt:754-764` lists 21 unconstrained input ports and 89 output ports,
including SDRAM DQ inputs. Review external memory constraints/board timing
before relying on summary slack as proof of physical margin.

Older candidate notes quote 31,370 ALMs / 505 RAM blocks (91%). They describe
a different non-trace build, not the latest trace report. No fresh matched
trace/no-trace or old/new CPU fit comparison was performed.

## Apple IIe card feasibility

Apple specifies 256 KiB physically on the card, including 128 KiB standard
application RAM and ROM contents simulated in protected RAM; it can also
use host memory. Even 128 KiB exceeds the free BRAM. See Apple's original
[IIe Card product sheet](https://mirrors.apple2.org.za/ftp.apple.asimov.net/documentation/hardware/misc/Apple_IIe_Card.pdf),
page 2. Byte-wide 256 KiB storage would typically consume about 256 M10Ks;
that is a memory-layout estimate, not a synthesized card measurement.

Two credible architectures:

1. Reserve card storage in SDRAM/DDR3, retaining small on-chip buffers.
   Machine RAM already uses SDRAM, ROM DDR3, and SWIM private SDRAM storage
   above 36 MiB (`rtl/swim2_memory.sv:41`). Allocation, ownership, arbitration
   and bounded latency would need explicit design.
2. Move VRAM to the planned external-memory backend. Removing its current
   arrays would grossly release 324 M10Ks, before replacement buffers and
   controller cost. This also addresses aliased VRAM. It is not a free or
   already validated migration; retain the existing beat/fetch interfaces.

No defensible card ALM estimate is available. A 65C02 alone is insufficient:
the card needs IIe memory/soft switches and its Mac-visible control, memory,
interrupt, video/input/media interfaces. Expansion currently bus-errors.
Stock software's 24-bit/MMU framebuffer path must be exercised. Apple's
560x384 IIe display option also needs qualification; it does not establish
that initial operation at 640x480 is impossible (developer note pp. 5,45).

Conclusion: capacity does not rule the card out after core completion, but
an unchanged BRAM allocation rules out an all-BRAM implementation. Only a
prototype fit after choosing the memory/interface architecture can establish
logic and timing feasibility. Do not promise a fit from 25% nominal ALMs.

## Verification and next steps

Fresh 2026-11-05 checks, all exit 0:

- `scripts/check_imports.ps1`: 96 preserved imports verified; 124 present.
  This verifies pinned imports, not freshness against latest upstream.
- `wsl.exe --exec sh tests/run_cpu040.sh smoke`: integer execution, two
  resets and delayed bus replies, about 18 seconds including compilation.
- Same runner `lc040`: 90 frame/EA/RTE/fault cases, about 31 seconds.
- `machine`: two runs, each 12 signatures, 138/47 memory beats and 22 posted
  writes; overlay, aliases, lanes, split accesses, caches, IRQ/RTE and reset.
  About 30 seconds including compilation.
- `mmu`: 30 translation/root/U-M/ATC/fault/copyback cases, about 24 seconds.

The last three ran concurrently, each bounded by `timeout 180`.
Logs: `local/tests/cpu040-<bench>-build.log` and `-run.log`.
Machine tests inject CPU-facing interrupts; they do not qualify actual
peripheral interrupt concurrency or all PrimeTime behavior.

Fresh ModelSim CPU/SWIM checks could not launch: native-output encoding
failure, and the SWIM attempt through Windows PowerShell reported Illegal
System DLL Relocation before compilation. No fresh ModelSim RTL pass is
claimed. Existing Nov 4 trace logs record catalog PASS 226,122 checks,
trace PASS 130 frames, platform PASS 20 checks; these are historical,
modeled-host tests and do not reproduce the hardware corruption.
Host storage test runners require absent `local/Main_MiSTer` sources here;
they were not run. No FPGA build or hardware test was run, and no process
was left running.

Priorities: capture and fix floppy corruption with a reproducing regression;
resolve V-Integer and measure real LC475 performance; qualify peripheral
interrupt/pseudo-DMA/reset/persistence behavior; define supported hardware
coverage including 16-bit video and sound input. Plan external VRAM/card
memory before prototyping IIe card integration. Existing readiness checklists
predate these fresh CPU execution results; other gates remain open.
