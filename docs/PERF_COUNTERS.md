# Perf counters (debug builds)

`rtl/perf_counters.sv` keeps 42 free-running 32-bit counters at the 25 MHz machine clock (wrap after about 171 s). They need a `MACLC475_DEBUG` build. The core copies all 42 to DDR3 every 10.5 ms, where an SSH script reads them; the DAFB hex overlay shows them on screen too. The sim profile (`tests/run_cpu040.sh profile`) cross-checks them against its own bus counts and prints all seven pages.

## Taking a measurement (SSH, no OSD)

Every 2^18 clocks the core writes a snapshot of all counters to DDR3 at ARM physical `0x27F00000` (layout in `MacLC475.sv`, `DDR_PERF_BASE`). Nothing has to be cleared, frozen or paged.

1. Start the logger from a Windows PowerShell terminal: `.\scripts\perflog.ps1` (`-Seconds N` for a timed run, `-Name label`, `-MiSTer mister-living`). It samples once a second into `local/shots/perf/capture_*.csv`; Ctrl-C stops it and it prints and saves the report. From a POSIX shell with the Windows ssh config: `ssh mister-bedroom python3 -u - < scripts/perflog.py > capture.csv` (in WSL, use `ssh.exe`, since the `mister-*` aliases live in the Windows ssh config).
2. Let it record a few seconds of idle, run the test normally, let it record a few seconds of idle again, then stop the ssh.
3. The report (`python scripts/perf_report.py capture.csv`, run for you by `perflog.ps1`) prints a per-second timeline, finds the busy stretch (VRAM traffic over 4x the median; `--metric NAME` picks another counter, `--from S --to S` sets it by hand) and prints every counter's total and rate in that window, the idle rate outside it, and the derived figures below.

The perf counters in the OSD (Clear, Freeze) still act on the same counters: don't use them during a capture, the report will flag the jump.

## Taking a measurement (overlay)

1. OSD, Debug page: set `Perf counting` to Run, then press `Clear perf counters`.
2. Close the OSD and start the test right away (Speedometer Graphics). Time spent idling before the test is counted too; to correct for it, measure an idle stretch of known length the same way.
3. When the test ends, set `Perf counting` to Freeze.
4. Set `Perf counters` to Page 0 and photograph the screen, then Pages 1 to 6. The overlay replaces the whole picture and updates about twice a second. Set it back to Off to get the Mac screen back.

## Reading the overlay

Four rows of hex. Rows 1, 3 and 4 hold two counters each (left, right); row 2 is a header `C00p f00o00`: p = page, f = 1 when frozen, o = 1 when some counter wrapped.

| Page | Row 1 | Row 3 | Row 4 |
|---|---|---|---|
| 0 | cycles, instructions retired | decoder queue empty, DC2 held | WB held, engine maintenance/done states |
| 1 | engine lookup/load (E_S_*), store (E_SP_*, E_W_*) | line fill, dirty push | single bus transfer (E_BUS*), table walk |
| 2 (beats) | ROM ifetch, RAM ifetch | ROM data read, RAM data read | RAM data write, I/O |
| 3 (request cycles) | ROM ifetch, RAM ifetch | ROM data read, RAM data read | RAM data write, I/O |
| 4 | VRAM read beats, VRAM read cycles | VRAM write beats, VRAM write cycles | machine-side request cycles, machine-side cycles without ack |
| 5 (VRAM controller) | read hits in the line cache, line fills issued | read-wait clocks in idle, read-wait clocks behind the write FIFO drain | read-wait clocks behind a scanline DMA burst, read-wait clocks while DDR3 accepts the fill |
| 6 (MMU, caches, VRAM stores) | table walks started (`walks`), frame buffer stores posted (`vst_post`) | stores through the general path (`vst_slow`), PFLUSHes of any scope (`pflush`) | CINV/CPUSHes reaching the instruction cache (`ic_inv`), lines pushed by CPUSH (`cpush_lines`) |

- Pages 2-4 (except the machine-side pair) watch the CPU's own bus, before the store buffer: a request cycle there is a cycle the bus unit waits on that kind of access. A beat is one acked longword; a line fill is four beats, so ifetch beats / 4 = I-cache misses.
- Engine idle cycles = cycles minus page 1 and page 0's last counter.
- IPC = retired / cycles.
- "Machine side" is after the store buffer (what RAM, ROM and VRAM actually see).
- Pages 5 and 6 mix two sources. From `rtl/vram_ddr3.sv`: line cache hits and fills (every VRAM read is one or the other, so hits + fills should match the VRAM read beats on page 4), read-wait clocks under a DMA burst and on fill data beats, and prefetches issued and used. From the CPU's data engine, counted once per access however many bus beats it takes: frame buffer reads sent straight to the bus (`vrd_fast`) against reads through the general path (`vrd_gen`, and how many of those are split, `vrd_gen_split`), and stores posted (`vst_post`) against stores through the general path (`vst_slow`, `vst_slow_split`). A split access is a misaligned one that needs more than one bus beat. A MOVE16 line (one access, four beats) on the frame buffer counts under `vrd_fast` and `vst_post` since the MOVE16 fast path; before it, under `vrd_gen` and `vst_slow`. These six replaced VRAM wait counters on 2026-11-13, so older captures read differently in slots 32, 33, 35, 37, 38 and 41.
- Later on 2026-11-13, slots 36, 39, 40 and 41 (fill-beat waits, prefetches issued and used, split general-path stores) became MMU and cache counts from the data engine: table walks started, PFLUSHes, CINV/CPUSHes that reach the instruction cache (one per instruction), and dirty lines CPUSH pushes. `eng_walk / walks` is the average cost of a walk. Captures before this change read differently in those four slots; `perf_report.py` names them by the new meaning.
