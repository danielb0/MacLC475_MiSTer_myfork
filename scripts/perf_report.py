#!/usr/bin/env python3
# perf_report.py -- reads a scripts/perflog.py capture and prints:
#   1. a timeline, one line per sample: IPC and the main traffic rates, so a
#      benchmark run stands out against idle;
#   2. for one window of samples (the busy stretch, found automatically, or
#      --from/--to in seconds from the capture start): every counter's total
#      and rate, the idle rate outside the window, and the derived figures in
#      docs/PERF_COUNTERS.md.
#
#   python scripts/perf_report.py capture.csv [--from S --to S]
#                                 [--metric NAME] [--no-timeline]
#
# The window search marks samples whose --metric rate (default vram, VRAM read
# plus write beats) is over 4x the capture's median, and takes the longest
# run of them, so the capture needs some idle on at least one side.

import argparse
import csv
import statistics
import sys

CLK_HZ = 25_000_000
WRAP = 1 << 32

NAMES = [
    # page 0
    "cycles", "retired", "dq_empty", "dc2_held", "wb_held", "eng_maint",
    # page 1: engine cycles by class
    "eng_lookup", "eng_store", "eng_fill", "eng_push", "eng_bus", "eng_walk",
    # page 2: CPU-side beats
    "b_rom_if", "b_ram_if", "b_rom_rd", "b_ram_rd", "b_ram_wr", "b_io",
    # page 3: CPU-side request cycles
    "r_rom_if", "r_ram_if", "r_rom_rd", "r_ram_rd", "r_ram_wr", "r_io",
    # page 4
    "vram_rd_beats", "vram_rd_cyc", "vram_wr_beats", "vram_wr_cyc",
    "m_req_cyc", "m_noack_cyc",
    # page 5: vram_ddr3
    "v_hit", "v_fill", "ram_rd_line", "vrd_gen", "v_wait_dma",
    "vrd_gen_split",
    # page 6
    "walks", "ram_rd_linec", "vst_slow", "dc_flush_all",
    "ic_inv", "cpush_lines",
]
IDX = {n: i for i, n in enumerate(NAMES)}


def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            try:
                rows.append((float(r["t"]), int(r["seq"]),
                             [int(r["c%d" % i]) for i in range(len(NAMES))]))
            except (KeyError, ValueError):
                pass              # a cut-off last line
    return rows


def deltas(rows):
    """Per-interval (t_offset, dt_clocks, [delta per counter])."""
    out = []
    t0 = rows[0][0]
    for (ta, _, a), (tb, _, b) in zip(rows, rows[1:]):
        d = [(y - x) % WRAP for x, y in zip(a, b)]
        wall = tb - ta
        # cycles is the clock: a clear or a wrap gap shows as a mismatch
        if wall > 0 and abs(d[0] / CLK_HZ - wall) > 0.25 * wall + 0.05:
            print("note: sample at %.1f s: cycles say %.2f s, wall %.2f s "
                  "(counters cleared, frozen, or a gap over 171 s)"
                  % (tb - t0, d[0] / CLK_HZ, wall), file=sys.stderr)
        out.append((tb - t0, d))
    return out


def metric(d, name):
    if name == "vram":
        return d[IDX["vram_rd_beats"]] + d[IDX["vram_wr_beats"]]
    return d[IDX[name]]


def rate(d, name):
    return metric(d, name) * CLK_HZ / d[0] if d[0] else 0.0


def timeline(ds):
    print("   t(s)   IPC  retired/s  vram_rd/s  vram_wr/s  ram_if/s"
          "   io/s  v_fill/s")
    for t, d in ds:
        if not d[0]:
            print("%7.1f   (frozen)" % t)
            continue
        s = d[0] / CLK_HZ
        print("%7.1f %5.3f %10.0f %10.0f %10.0f %9.0f %6.0f %9.0f" % (
            t, d[1] / d[0], d[1] / s, d[IDX["vram_rd_beats"]] / s,
            d[IDX["vram_wr_beats"]] / s, d[IDX["b_ram_if"]] / s,
            d[IDX["b_io"]] / s, d[IDX["v_fill"]] / s))


def find_window(ds, name):
    rates = [rate(d, name) for _, d in ds]
    med = statistics.median(rates)
    thresh = max(4 * med, 1.0)
    # a benchmark has quiet phases: bridge gaps of up to GAP low samples
    GAP = 3
    best, cur, low = (0, 0), None, 0
    for i, r in enumerate(rates):
        if r > thresh:
            cur = (cur[0], i + 1) if cur else (i, i + 1)
            low = 0
            if cur[1] - cur[0] > best[1] - best[0]:
                best = cur
        elif cur:
            low += 1
            if low > GAP:
                cur, low = None, 0
    return best


def report(ds, lo, hi):
    win = [d for _, d in ds[lo:hi]]
    out = [d for _, d in ds[:lo] + ds[hi:] if d[0]]
    tot = [sum(c) for c in zip(*win)]
    otot = [sum(c) for c in zip(*out)] if out else None
    secs = tot[0] / CLK_HZ
    print("\nwindow: samples ending %.1f s to %.1f s, %.2f s of machine time"
          % (ds[lo][0], ds[hi - 1][0], secs))
    if otot:
        print("idle:   %.2f s outside the window" % (otot[0] / CLK_HZ))
    print("\n%-16s %14s %14s %14s" % ("counter", "window total", "window /s",
                                     "idle /s"))
    for i, n in enumerate(NAMES):
        idle = "%14.0f" % (otot[i] * CLK_HZ / otot[0]) if otot else ""
        print("%-16s %14d %14.0f %s" % (n, tot[i], tot[i] / secs, idle))

    def g(n):
        return tot[IDX[n]]
    cyc = g("cycles")
    eng = sum(g(n) for n in ("eng_lookup", "eng_store", "eng_fill",
                             "eng_push", "eng_bus", "eng_walk", "eng_maint"))
    print("\nderived (window)")
    print("  IPC                      %.4f" % (g("retired") / cyc))
    print("  engine idle cycles       %d (%.1f%%)" % (cyc - eng,
                                                    100 * (cyc - eng) / cyc))
    print("  I-cache misses (ROM/RAM) %d / %d" % (g("b_rom_if") // 4,
                                                  g("b_ram_if") // 4))
    vr = g("vram_rd_beats")
    print("  VRAM hits+fills vs reads %d vs %d" % (g("v_hit") + g("v_fill"),
                                                   vr))
    print("  VRAM reads general (split)         %d (%d)" % (
        g("vrd_gen"), g("vrd_gen_split")))
    print("  VRAM stores                        %d" % g("vst_slow"))
    # (slots 32 and 37: RAM data line reads, beats and request cycles;
    # 41479fa counted CIOUT beats there, older captures frame buffer
    # counts)
    lb, lc = g("ram_rd_line"), g("ram_rd_linec")
    sb, sc = g("b_ram_rd") - lb, g("r_ram_rd") - lc
    print("  RAM data line fills / single reads %d / %d" % (lb // 4, sb))
    if lb:
        print("  RAM line read cycles / beat        %.2f" % (lc / lb))
    if sb:
        print("  RAM single read cycles / read      %.2f" % (sc / sb))
    if vr:
        print("  VRAM read cycles / beat  %.2f" % (g("vram_rd_cyc") / vr))
    vw = g("vram_wr_beats")
    if vw:
        print("  VRAM write cycles / beat %.2f" % (g("vram_wr_cyc") / vw))
    # (since the next-line prefetch, a read acked by a prefetch's fill
    # beat counts as neither a hit nor a fill, so hits+fills can fall short)
    w = g("walks")
    print("  table walks %d, CINVA/CPUSHA DC %d, I-cache CINV/CPUSH %d, "
          "CPUSH lines %d"
          % (w, g("dc_flush_all"), g("ic_inv"), g("cpush_lines")))
    if w:
        print("  cycles / table walk      %.1f" % (g("eng_walk") / w))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--from", dest="t_from", type=float)
    ap.add_argument("--to", dest="t_to", type=float)
    ap.add_argument("--metric", default="vram",
                    help="window search rate: vram or a counter name")
    ap.add_argument("--no-timeline", action="store_true")
    a = ap.parse_args()

    rows = load(a.csv)
    if len(rows) < 3:
        sys.exit("need at least 3 samples")
    ds = deltas(rows)
    if not a.no_timeline:
        timeline(ds)
    if a.t_from is not None or a.t_to is not None:
        tf = a.t_from if a.t_from is not None else 0.0
        tt = a.t_to if a.t_to is not None else ds[-1][0]
        idx = [i for i, (t, _) in enumerate(ds) if tf < t <= tt]
        if not idx:
            sys.exit("no samples in that window")
        lo, hi = idx[0], idx[-1] + 1
    else:
        lo, hi = find_window(ds, a.metric)
        if hi == lo:
            print("\nno busy stretch found (all idle?); give --from/--to")
            return
    report(ds, lo, hi)


if __name__ == "__main__":
    main()
