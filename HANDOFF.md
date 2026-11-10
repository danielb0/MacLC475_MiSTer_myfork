# Project handoff

## Public README cleanup

- Objective: provide concise repository setup and status information for
  prospective users; make clear that ROM and CUDA firmware are user-supplied.
- Baseline: `exp/lean-ddr3-vram`, README described internal build/test details
  and did not clearly state that ROM and firmware are not included.
- Changes: `README.md` now gives build/setup steps, the Macintosh ROM checksum
  (`FF7439EE`) and expected path, CUDA firmware filename, and brief status.
- Checks: reviewed the README diff against `docs/CURRENT_DIRECTION.md` and
  `docs/RELEASE_READINESS.md`; no tests run (documentation-only change).
- Unresolved: alternate ROM dump names are descriptive examples, not verified
  canonical filenames. Exact next step: none unless canonical filenames or a
  different user setup flow are provided.

## Hardware coverage and Apple IIe feasibility review

- Objective: assess full machine coverage, SWIM II/PrimeTime completeness,
  FPGA headroom and hypothetical IIe card fit. Review only; no RTL changes.
- Baseline: `a0f7575` on `diag/swim2-trace`, initially clean. Existing Nov 4
  trace fit (`9ed2fd9` per trace notes): 31,607/41,910 ALMs, 510/553 M10Ks,
  positive constrained slack. This was not rebuilt against reviewed HEAD.
- Changes: `docs/HARDWARE_REVIEW.md` records evidence and limitations.
  No previous root handoff existed. Existing direction/readiness documents
  predate the fresh CPU results below.
- Fresh checks, 2026-11-05: import verification PASS (96 preserved/124
  present); Verilator smoke PASS, LC040 90 cases PASS, machine two runs PASS,
  MMU/cache 30 cases PASS. Each compile/run finished within 32 seconds;
  execution logs are `local/tests/cpu040-<bench>-run.log`.
- Failed checks/resources: legacy ModelSim launch failed before compilation
  (encoding/Illegal System DLL Relocation). No fresh ModelSim results.
  Host Main regression sources absent at the runner's `local/Main_MiSTer`
  path; those tests were not run. No workaround or new full build attempted.
- Findings: major blocks exist; timing/configuration, 16-bit video, sound
  recording and LocalTalk coverage remain incomplete. SWIM catalog corruption
  remains unresolved; old modeled regressions do not locate its cause.
  Only 43 M10Ks free; current VRAM uses 324. IIe all-BRAM addition cannot fit
  unchanged; external card memory or external VRAM is plausible, unproven.
- Exact next step: capture the failing floppy sequence on hardware using
  `docs/SWIM2_TRACE.md`, identified RBF/Main and disposable images; decode
  and locate the loss before modifying RTL. Review report before choosing
  additional base-hardware or IIe implementation work. No process running.
