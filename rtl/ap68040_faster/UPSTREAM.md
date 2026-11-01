# Pipelined LC040

Source: `alanswx/MacQuadra800_MiSTer`, `pipelined-040-small33`,
revision `82122463f51cc22d61164aa343178188cb225953`.
Donor hashes and adaptation flags are in `docs/imports.json`.
Generated tables and the license are preserved.

`MacLC475.qpf` selects this CPU through `quadra_cpu040.sv` and
`quadra_bus040.sv`. It runs 1:1 at 25 MHz with 4 KiB caches and no FPU.
Dual issue and BTIC are disabled for the initial size candidate.
Local adaptations implement LC040 EA-only decoding, format-4 entry/RTE,
no-FPU exception/store handling and earlier scalar DMU dispatch.
Local microcode uses unused ROM slots.

CE must remain asserted, interrupts must be autovectored and Ethernet must
remain disabled. The wrapper does not implement DMA snooping, platform
retained-line injection or external store-buffer gating. Only retired PC
is exposed in legacy CPU diagnostics. CPU reset/cache semantics are preserved.

The project generates the scaler startup guard outside stock sys.
Directed bus/LC040 checks and CPU/machine/MMU elaboration pass. Execution,
fitting and guest acceptance remain pending. Use `tests/run_cpu040.ps1` for
short directed checks and `tests/run_cpu040.sh` for Verilator execution.
ModelSim 10.5b rejects donor forward references and always_ff initialization;
it supports the directed subset only. Elle runs longer checks and full fits.

See `docs/CPU_DONOR.md` for qualification gates and the reference pin.
