# SWIM II media staging

LC donor: `https://github.com/meauxdal/MacLC_MiSTer.git` at
`fd29cdb3ff2c917d76144fe3f429f9e2ef1c9fe8`. Source hashes are in
`docs/imports.json`.

- `mfm_track_encoder.v` and `mfm_write_decoder.v`: donor logic retained;
  comments trimmed to ASCII and encoder declarations moved before use.
- `floppy_track_encoder.v` and `floppy_track_decoder.v`: donor zoned GCR
  nibbler/checksum and format relay retained. Encoder declarations precede
  use; image address is combinational for the tagged prefetch interface.
  Added fetch/sector/index outputs and decoder byte-ready reporting for its
  three-clock recovered-byte writes. Comments are trimmed to ASCII.
- `../swim2_mfm_write.sv`: adapted from `ism_write_engine` in `rtl/swim.v`.
  Adds CE, requests FIFO consumption on the same edge, and delegates empty
  requests to SWIM II's underrun handling. One CRC token emits two bytes.
- `../swim2_drive.sv`: extracts the single-drive command/sense state from
  `rtl/floppy.v`. Retains the donor's falling LSTRB edge, immediate step and
  ACTION-gated head selection. Eject completion waits for persistence and
  remains logically absent until the host withdraws the old mount.
- `../swim2_write_commit.sv`: extracts `floppy_write_committer` from
  `rtl/floppy_sd.v`. Retains synchronous buffer reads, even-byte-high word
  packing and the persistence tap. Adds explicit offer rejection, aligned
  sector validation, initialized outputs and ACK-low turnaround.
- `../swim2_loader.sv`: adapts the donor's one-sector load-then-drain pattern.
  Accepts only raw 400K/800K GCR and 720K/1440K MFM sizes. Validates all 256
  WIDE words before draining, retains failed transfers for explicit retry and
  publishes media only after the final memory drain. Owns the host slot from
  acquisition through media release; guest reset cannot cancel loading.
  Requires a successful checked host result before draining each sector.
  Pre-publication cancel waits for any active host transfer/result and memory
  ACK/drain, then pulses cancel_done. Missing replies never imply completion.
  Cancellation cannot discard published media or unfinished durable saves.
  Acquisition ownership uses sampled cancellation to avoid host-control
  feedback; current cancel still gates acceptance and publication.

These are decoded byte streams, not flux models. Encoder tests supply immediate
image data; subsystem tests supply byte deadlines. The optional platform wrapper
generates deadlines and connects storage. Physical cells, settling, LSTRB and
Q605 tach calibration remain unqualified. A decoded sector is not a persisted write.

The committer owns the decoder buffer from an accepted sector offer until
`done`; the producer must prevent buffer writes during `busy`. Its `nreset`
is a global abort, which can leave a partially written memory sector. `done`
means all 256 memory writes completed, not durable file storage.

`../swim2_media.sv` wraps both decoders and the shared committer:

- All ports use the full clock. Mount valid/ready accepts a resident image's
  base, encoding, sidedness, density and write protection. The loader must not reuse that region
  or host slot until release completes. A new mount needs a new handshake.
- The buffer locks on `sector_valid`, including while waiting for memory's
  ACK to clear. Completed sectors survive guest reset, seek and release;
  partial decoder streams are discarded. The completed buffer's codec is
  latched so setup changes cannot redirect its read port. Only global
  `nreset` aborts commit. Unbacked heads of 400K images cannot fetch or write.
- The image fetcher launches only on `read_enable`, holds `read_busy` through
  reply turnaround and drops replies marked `read_discard`. A context change
  keeps outstanding replies stale until that transaction drains. Commit waits
  for an existing read; release waits for reads, writes and save notifications.
- Feed the decoded write engine's strobe/data and its CE-qualified deadline
  pulse separately. Deadlines must continue when `stream_enable` is low.
  `write_fault` reports lost deadlines or decoder rejection until ACTION ends
  or context resets. The subsystem connects lost deadlines to FIFO underrun.
- `save_valid/save_ready` transfers each completed sector address to the
  persistence backend. Backpressure retains buffer ownership. The backend
  must own the accepted notification and any tap data it needs before ready;
  subsequent sectors may overwrite the tap. No queue or file writer is here.
- Hold release request until `release_done`, then withdraw it. Flush uses a
  four-phase level handshake after all memory/save work drains. A stale high
  ACK blocks a new flush; ACK must mean every accepted save is durable. The
  mount stays owned until ACK returns low. Errors must not acknowledge flush.
  Release completion is a full-clock pulse; the drive CE needs held delivery.

`../swim2_subsystem.sv` connects controller, drive, owner and MFM/GCR codecs:

- One-byte image fetches use level request/ACK with address setup and ACK-low
  turnaround. Prefetch replies carry their image offset; invalidated replies
  are discarded. Write activity revokes cached data. Byte deadlines advance
  rotation even when memory is late; missing payload reads substitute zero,
  set diagnostic `read_fault` and suppress MFM CRC-zero until the next mark.
- Blocked write deadlines use the FIFO's underrun path through `tx_fault`,
  preserving first-error retention and stopping ACTION on CE. A decoder
  rejection remains a media diagnostic; if software continues into another
  blocked deadline, that deadline is reported as underrun.
- Mount/context invalidation reaches FIFO tags and anchors. Guest eject and
  release completion are held across guest reset and stopped CE. New mounts
  wait until the old disk's absence has been sampled by the drive on CE.
- The wrapper takes external CE-qualified byte deadlines and tach. The
  fixture supplies delayed image/memory replies and durable-flush responses.
  Physical cell/rotation and parameter pulse timing remain unqualified.
  `rddata` and the test counter are tied low.
  The optional platform connects loader/SDRAM/host persistence; this is not a
  guest-qualified or fitted SuperDrive.

`../swim2_persistence.sv` stages raw-image writeback behind the media owner:

- Capture all 256 committer tap words before `save_valid`. Hold that valid
  level and the owner buffer until `save_ready`. One snapshot, no queue;
  backpressure prevents a later sector from overwriting a pending save.
- `image_blocks` is the raw file's 512-byte block count, stable for the mount.
  Unaligned/out-of-bounds notifications fault without writing or retiring.
  The latched LBA and snapshot survive metadata changes and failed retries.
- The host reads synchronous `sd_buff_din`, even byte low in WIDE order.
  `sd_wr/sd_ack` transfers one block; a separate `durable_req/ack/error`
  handshake must report its actual durable file-write result. Hold error
  throughout ACK. Stale ACKs must clear before either request starts.
- Failure holds ownership and blocks flush. Pulse `retry` to resend the same
  snapshot. Missing/held replies wait indefinitely; they never imply success.
  `save_ready` follows successful durable ACK turnaround. Flush ACK stays high
  until request drops and requires all saves to have completed durably.
- Connect reset only to global abort. Guest reset/context/eject use the media
  owner's drain path. No power-loss protection or host throughput is qualified.

Stock hps_io ACK ends the SPI buffer transfer before Main writes the file.
Main `8328d9f0e162c663bcdcd695ee77b61ca6eab06a`, `user_io.cpp` generic
`op == 2`, calls `FileWriteAdv` after `DisableIO` and does not return its
failure to the core. Never derive durable ACK from sd_ack or a delay. The
host path is in `../swim2_host_persistence.sv`, connecting the snapshot backend
to `../swim2_host.sv` through stock `hps_io.EXT_BUS`.

- Reserve host slot 6. Command `0x08` returns seven words: `0x5357`, status,
  token low/high, LBA low/high, slot. Status is `0x0100` plus bit 0 pending,
  bit 1 transfer request, bit 2 transfer ACK and bit 3 mount owned.
- Command `0x09` takes token low/high and result (zero success, else error).
  Only a matching pending attempt after transfer ACK clears can accept it.
  The first result is retained until the backend's four-phase durable request
  drains. Early results wait; duplicates/stale/truncated results cannot retire
  another save. Tokens survive global abort; exhaustion blocks further saves.
- `../swim2_host_read.sv` uses commands `0x0a`/`0x0b` for checked reads, with
  magic `0x5352`, transfer-request bit 1 for sd_rd and the same token/status
  layout. `../swim2_storage.sv` multiplexes both command paths on EXT_BUS.
  The loader waits for the result's four-phase turnaround before draining.
  Main validates/reads the actual raw file before SPI transfer and reports
  short reads, EOF, seek or stream errors. Zero payload on failure completes
  the transfer but its error result prevents publication. Retry gets a new
  token; stale results cannot authorize another attempt.
- `mount_owned` must cover loader acquisition, loading and media ownership
  through release, including periods without a pending save. Main's separate
  `patches/Main_MiSTer-swim2.patch` checks it before changing a slot-6 handle.
  Host replacement requires completed release. `../swim2_host_control.sv`
  routes host eject to loader cancellation before publication or media release
  after publication. Connect storage's `release_request` to the subsystem.
- Command `0x0c` snapshots seven words: `0x5343`, status, mount token low/high,
  two reserved zero words and slot 6. Status is `0x0100` plus owned, eject pending,
  live, loader fault, writer fault and token exhausted in bits 0-5. Command
  `0x0d` takes mount token low/high and action: 1 eject, 2 load retry, 3 save
  retry. Tokens survive global abort and fail closed on exhaustion. Truncated,
  stale and unknown commands cannot act on a later mount. Save retry remains
  available while eject waits for a failed durable save; load retry cannot
  override cancellation. Missing replies retain ownership indefinitely.
- Main's empty-name slot-6 mount requests eject without changing the handle
  or cache. Polling closes it only after matching ownership ends, using the
  guarded mount path again. Replacement clears a pending deferred close.
  `swim2_retry()` provides explicit fault retry from the optional project's
  Retry floppy I/O menu action. It does not run automatically.
- Main validates a fixed raw file, seeks, writes exactly 512 bytes, flushes and
  calls `fsync` before returning success. Errors retain the RTL snapshot for
  retry. `tests/run_main_swim2.sh` exercises that production helper with real
  files, close/reopen comparison and injected failures. The RTL media fixture
  now delivers completions through these commands; its file remains modeled.
- `tests/run_swim2_hps.ps1` checks stock hps_io's status, WIDE buffer transfer
  and extension mux with the snapshot backend and checked loader. Its disposable ModelSim copy
  only adapts declarations/syntax; the physical HPS link is not simulated.
- Deployed bus/filesystem/device behavior and power-loss recovery remain
  unqualified. Never reuse LC's fixed image base:
  byte 12 MiB overlaps Q605 RAM. `../swim2_memory.sv` translates image byte
  offsets to byte 0x02400000, above maximum 36 MiB RAM backing. The media's
  legacy base can remain zero; no physical base passes through that port.

`../swim2_memory.sv` arbitrates machine beats, loader/committer words and byte
reads on the existing `sdram_beat32` beat port:

- Requires known 64/128 MiB SDRAM for image accesses. Elle's module is 128 MiB.
  Rejects unaligned/out-of-image writes without ACK. Image geometry/capacity
  must remain stable while owned. CPU beats remain available independently.
- Latches request ownership and payload through pulse ACK, then holds each
  floppy ACK until its request drops. Global client abort drains/discards an
  outstanding beat before rearming. Shared bridge init is power-up only.
- Preserve the CPU's posted-write push and wq_room connections directly.
  A write ACK is FIFO acceptance. Publication/release fences include bridge
  busy and retained-line pending, since busy alone omits the BL8 read tail.
- Round-robin grants do not bound service under continuous CPU push traffic.
  Physical timing, production latency and throughput remain unqualified.
- `tests/run_swim2_memory.ps1` exercises the real bridge and Altera MLAB against
  the existing chip models; declarations are reordered only in a test copy.

GCR staging supports raw 400K/800K payload images. Set `mount_gcr=1`,
`mount_hd=0` and `mount_sides=0/1`; mounted sidedness fixes image geometry.
Setup bit 2 selects GCR reads and bit 6 selects raw GCR writes independently.
Software supplies nibblized disk bytes through the FIFO; the GCR path does
not expand them using the MFM CRC engine. Unsupported CRC tokens stop ACTION
through the staged underrun path. This fallback and mark/sync-cell behavior
still need silicon qualification; no polynomial GCR token behavior is claimed.
Read tags are zero-filled and write tags are discarded, matching raw payload
images. Tag-bearing containers and cross-geometry formatting are unqualified.
The donor format relay is connected to accepted raw bytes, address marks and
write completion. Byte deadlines must leave time for the decoder's internal
three-clock group commit; blocked deadlines are reported, not silently lost.
The codec fixture checks 300 sectors against an independent whole-byte
nibblization/checksum reference, plus geometry, corruption and relay behavior.
The subsystem fixture checks raw FIFO traffic and byte-exact memory commits
for 400K/800K, including codec switches during drain.

`MacLC475.qpf` selects `../swim2_platform.sv` through `../swim2.qip`.
It inherits cpu040; other projects omit the drive. PrimeTime uses the saved MAME
iosb.cpp map: $5001E000-$5001FFFF, MiB mirrors, 512-byte register strides, upper
byte readback per 16-bit word and either write lane (low byte wins a word write).
The bus strobe captures read data before register side effects on the same edge.
Slot 6 uses stock hps_io; the separate Main patch is required for checked results,
eject and explicit retry. Storage global reset is PLL loss, not guest reset.

`../swim2_timing.sv` scales the pinned LC 8.125 MHz byte/tach enables with
`rate_enable`: 130/260 enables per MFM HD/DD byte and 128 per raw GCR byte.
At 25 MHz MFM media deadlines are 400/800 clocks. No memory or FIFO backpressure
stretches them. ACTION does not restart rotation. Write FIFO deadlines are
independent: nominal 16 us, doubled by Setup bit 3 for both encodings (ERS
pp. 6, 8). ACTION/FIFO clear/guest reset stop that clock; divider changes restart
a complete byte interval. Media density and motor state do not set write speed.
These are decoded-byte timings, not Q605 physical-clock/cell qualification.
Controller serialization continues with no selected disk so ROM FIFO calibration
can run without media. The media owner discards this output; selected-media
backpressure still reports a write fault and preserves pending persistence.
Tach keeps the donor's
calibrated half-period counts, with CE-safe pause and zone-transition handling;
do not interpret these as qualified Q605 RPM. Read clock division, flux/sync
cells, parameter precompensation and the test/RDDATA signals remain unqualified.
`tests/run_swim2_platform.ps1` checks pacing, PrimeTime and a full modeled
load/read/write/failure/retry/eject/reload through the production wrapper.
