# Perf counters (debug builds)

`rtl/perf_counters.sv` keeps 42 free-running 32-bit counters at the 25 MHz machine clock (wrap after about 171 s). They need a `MACLC475_DEBUG` build. The core copies all 42 to DDR3 every 10.5 ms, where an SSH script reads them; the DAFB hex overlay shows them on screen too. The sim profile (`tests/run_cpu040.sh profile`) cross-checks them against its own bus counts and prints all seven pages.

## Taking a measurement (SSH, no OSD)

Every 2^18 clocks the core writes a snapshot of all counters to DDR3 at ARM physical `0x27F00000` (layout in `MacLC475.sv`, `DDR_PERF_BASE`). Nothing has to be cleared, frozen or paged.

1. Start the logger from the PC; it samples once a second and the CSV lands on the PC: `ssh mister-bedroom python3 -u - < scripts/perflog.py > capture.csv`
2. Let it record a few seconds of idle, run the test normally, let it record a few seconds of idle again, then stop the ssh.
3. `python scripts/perf_report.py capture.csv` prints a per-second timeline, finds the busy stretch (VRAM traffic over 4x the median; `--metric NAME` picks another counter, `--from S --to S` sets it by hand) and prints every counter's total and rate in that window, the idle rate outside it, and the derived figures below.

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
| 6 (VRAM controller) | read-wait clocks on fill data beats, read-wait clocks in idle with a FIFO conflict | fills of the line after the last one filled, refills of a line whose tag is already held | reads acked from another line's beat (must be 0), read-wait clocks under another line's fill tail |

- Pages 2-4 (except the machine-side pair) watch the CPU's own bus, before the store buffer: a request cycle there is a cycle the bus unit waits on that kind of access. A beat is one acked longword; a line fill is four beats, so ifetch beats / 4 = I-cache misses.
- Engine idle cycles = cycles minus page 1 and page 0's last counter.
- IPC = retired / cycles.
- "Machine side" is after the store buffer (what RAM, ROM and VRAM actually see).
- Pages 5 and 6 come from `rtl/vram_ddr3.sv` and count its clocks, not beats. Every VRAM read is either a hit or waits for a fill, so hits + fills should match the VRAM read beats on page 4. Page 5 counters 2-5 plus page 6 counter 0 split the waiting clocks by what the DDR3 state machine was doing; page 6 row 4 left must read 0.
