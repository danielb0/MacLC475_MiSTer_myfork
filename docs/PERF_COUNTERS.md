# Perf counters (debug builds)

`rtl/perf_counters.sv` keeps 30 free-running 32-bit counters at the 25 MHz machine clock (wrap after about 171 s). They need a `MACLC475_DEBUG` build and are read through the DAFB hex overlay. The sim profile (`tests/run_cpu040.sh profile`) cross-checks them against its own bus counts and prints all five pages.

## Taking a measurement

1. OSD, Debug page: set `Perf counting` to Run, then press `Clear perf counters`.
2. Close the OSD and start the test right away (Speedometer Graphics). Time spent idling before the test is counted too; to correct for it, measure an idle stretch of known length the same way.
3. When the test ends, set `Perf counting` to Freeze.
4. Set `Perf counters` to Page 0 and photograph the screen, then Pages 1 to 4. The overlay replaces the whole picture and updates about twice a second. Set it back to Off to get the Mac screen back.

## Reading the overlay

Four rows of hex. Rows 1, 3 and 4 hold two counters each (left, right); row 2 is a header `C00p f00o00`: p = page, f = 1 when frozen, o = 1 when some counter wrapped.

| Page | Row 1 | Row 3 | Row 4 |
|---|---|---|---|
| 0 | cycles, instructions retired | decoder queue empty, DC2 held | WB held, engine maintenance/done states |
| 1 | engine lookup/load (E_S_*), store (E_SP_*, E_W_*) | line fill, dirty push | single bus transfer (E_BUS*), table walk |
| 2 (beats) | ROM ifetch, RAM ifetch | ROM data read, RAM data read | RAM data write, I/O |
| 3 (request cycles) | ROM ifetch, RAM ifetch | ROM data read, RAM data read | RAM data write, I/O |
| 4 | VRAM read beats, VRAM read cycles | VRAM write beats, VRAM write cycles | machine-side request cycles, machine-side cycles without ack |

- Pages 2-4 (except the machine-side pair) watch the CPU's own bus, before the store buffer: a request cycle there is a cycle the bus unit waits on that kind of access. A beat is one acked longword; a line fill is four beats, so ifetch beats / 4 = I-cache misses.
- Engine idle cycles = cycles minus page 1 and page 0's last counter.
- IPC = retired / cycles.
- "Machine side" is after the store buffer (what RAM, ROM and VRAM actually see).
