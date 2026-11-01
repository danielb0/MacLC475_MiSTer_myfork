# Pipelined LC040

Source: `alanswx/MacQuadra800_MiSTer`, `pipelined-040-66mhz-timing`,
revision `eefa4aa8df9b57ee19791a14be2f728243d50fca`.
Donor hashes and adaptation flags are in `docs/imports.json`.
Generated tables and the license are preserved.

`MacLC475.qpf` selects this CPU through `quadra_cpu040.sv` and
`quadra_bus040.sv`. It runs 1:1 at 25 MHz with 4 KiB caches and no FPU.
Local adaptations implement LC040 EA-only decoding, format-4 entry/RTE,
no-FPU exception/store handling and earlier scalar DMU dispatch.
Local microcode uses unused ROM slots.

CE must remain asserted, interrupts must be autovectored and Ethernet must
remain disabled. The wrapper does not implement DMA snooping, platform
retained-line injection or external store-buffer gating. Only retired PC
is exposed in legacy CPU diagnostics. CPU reset/cache semantics are preserved.

The project generates the scaler startup guard outside stock sys.
Prior CPU/bus/LC040/machine/MMU checks passed in the source repository;
those results do not qualify a future donor or establish complete hardware
acceptance. Use `tests/run_cpu040.ps1` for short directed checks and
`tests/run_cpu040.sh` for execution. Elle runs longer checks and full fits.

See `docs/CPU_DONOR.md` for the next isolated donor import.
