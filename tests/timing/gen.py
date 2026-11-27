# builds prog_<mode>.hex (one 32-bit long per line, from address 0) and tests.txt
# mode wt: caches on, write-through (no TTR).  mode cb: DTT0 maps $00xxxxxx copyback,
# the mode the Mac OS runs the 68040 in (Apple developer note, "CopyBack mode").
import os, sys
PASSES = int(os.environ.get('PASSES', '3'))
SUITE = int(os.environ.get('SUITE', '1'))   # 2: the second set of tests (the marker has room for 63)
MEMLONGS = 1 << 17
MARK = 0x50000000          # outside RAM: never cached, always a bus write

def build(mode):
    mem = bytearray(MEMLONGS * 4)
    st = {"pc": 0x1000}
    tests = []
    def put16(a, w): mem[a] = (w >> 8) & 255; mem[a+1] = w & 255
    def put32(a, l): put16(a, l >> 16); put16(a+2, l & 0xFFFF)
    def emit(*ws):
        for w in ws:
            put16(st["pc"], w & 0xFFFF); st["pc"] += 2
    def marker(i): emit(0x7E00 | (i & 0x7F), 0x23C7, MARK >> 16, MARK & 0xFFFF)
    def test(name, units, um, setup, body, suite=1):
        if suite != SUITE: return
        i = len(tests)
        # Each test runs twice in a row and the second run is the one timed
        # (the bench keeps the last): its code is then in the instruction
        # cache, 4 Kbytes as the MC68040's, which the whole program is not.
        # The first run of the first pass is the "cold" column.
        emit(0x7A01)                                    # MOVEQ #1,D5
        again = st["pc"]
        setup(); marker(2*i); body(); marker(2*i+1)
        emit(0x51CD, (again - (st["pc"] + 2)) & 0xFFFF) # DBRA D5,again
        tests.append((name, units, um))
    def rep(n, *ws):
        def f():
            for _ in range(n): emit(*ws)
        return f
    def nop(): pass
    def lea_a0(): emit(0x41F9, 0x0002, 0x0000)                      # LEA $20000,A0
    def lea_a01(): emit(0x41F9, 0x0002, 0x0000, 0x43F9, 0x0002, 0x1000)

    put32(0, 0x00008000); put32(4, 0x00001000)
    put32(10*4, 0x300); put32(32*4, 0x310)
    put16(0x300, 0x54AF); put16(0x302, 0x0002); put16(0x304, 0x4E73)   # ADDQ.L #2,2(A7); RTE
    put16(0x310, 0x4E73)                                               # RTE
    put16(0x380, 0x4E75)                                               # RTS
    put16(0x390, 0x61EE); put16(0x392, 0x4E75)                         # BSR.S $380; RTS

    if mode == "cb":
        emit(0x203C, 0x0000, 0xC020, 0x4E7B, 0x0006)    # DTT0: $00xxxxxx, copyback
    emit(0x203C, 0x8000, 0x8000, 0x4E7B, 0x0002)        # CACR: both caches on
    emit(0x47F9, 0x0004, 0x0000)                        # LEA $40000,A3 (read-miss walker)
    emit(0x49F9, 0x0006, 0x0000)                        # LEA $60000,A4 (write-miss walker)
    emit(0x45F9, 0x0000, 0x0380)                        # LEA $380,A2
    emit(0x7C00 | PASSES)                              # MOVEQ #PASSES,D6
    top = st["pc"]
    N = 64
    test("(empty: marker overhead)", 1, 0, nop, nop)
    test("MOVE.L D0,D1", N, 1, nop, rep(N, 0x2200))
    test("ADD.L D0,D1", N, 1, nop, rep(N, 0xD280))
    test("ADDQ.L #1,D0", N, 1, nop, rep(N, 0x5280))
    test("MOVE.L (A0),D0", N, 1, lea_a0, rep(N, 0x2010))
    test("MOVE.L D0,(A0)", N, 1, lea_a0, rep(N, 0x2080))
    test("MOVE.L (A0)+,D0", N, 1, lea_a0, rep(N, 0x2018))
    test("MOVE.L 4(A0),D0", N, 1, lea_a0, rep(N, 0x2028, 4))
    test("MOVE.L D0,4(A0)", N, 1, lea_a0, rep(N, 0x2140, 4))
    test("MOVE.L (A0),(A1)", N, 1, lea_a01, rep(N, 0x2290))
    test("ADD.L 4(A0),D0", N, 1, lea_a0, rep(N, 0xD0A8, 4))
    test("ADD.L D0,(A0)", N, 1, lea_a0, rep(N, 0xD190))
    test("ADDQ.L #1,(A0)", N, 1, lea_a0, rep(N, 0x5290))
    test("CLR.L (A0)", N, 1, lea_a0, rep(N, 0x4290))
    test("TST.L (A0)", N, 1, lea_a0, rep(N, 0x4A90))
    test("LEA 4(A0),A1", N, 2, lea_a0, rep(N, 0x43E8, 4))
    test("MOVE.L (A0,D1.L*4),D0", N, 3, lambda: (lea_a0(), emit(0x7203)), rep(N, 0x2030, 0x1C00))
    test("MOVE.L D0,-(A7) / MOVE.L (A7)+,D0", N, 2, nop, rep(N, 0x2F00, 0x201F))
    test("MOVEA.L (A0),A0 (pointer chase)", N, 1, lambda: (lea_a0(), emit(0x2088)), rep(N, 0x2050))
    test("SWAP D0", N, 2, nop, rep(N, 0x4840))
    test("EXT.L D0", N, 1, nop, rep(N, 0x48C0))
    test("LSL.L #2,D0", N, 2, nop, rep(N, 0xE588))
    test("ASL.L #2,D0", N, 3, nop, rep(N, 0xE580))
    test("LSR.L D1,D0", N, 3, lambda: emit(0x7203), rep(N, 0xE2A8))
    test("MULU.W D1,D0", 16, 14, lambda: emit(0x7203, 0x7005), rep(16, 0xC0C1))
    test("MULS.L D1,D0", 16, 20, lambda: emit(0x7203, 0x7005), rep(16, 0x4C01, 0x0800))
    test("MOVE.L D2,D0 / DIVU.W D1,D0", 16, 28, lambda: emit(0x7203, 0x243C, 0x0001, 0x86A0), rep(16, 0x2002, 0x80C1))
    test("MOVE.L D2,D0 / DIVU.L D1,D0", 16, 45, lambda: emit(0x7203, 0x243C, 0x0001, 0x86A0), rep(16, 0x2002, 0x4C41, 0x0000))
    # branches: the flags are set inside the window (the marker's MOVEQ changes them)
    def b_nt():
        emit(0x7000)                                    # MOVEQ #0,D0 (Z=1)
        for _ in range(N): emit(0x6600, 0x0004, 0x7000) # BNE.W +4 (not taken); MOVEQ #0,D0
    test("BNE.W not taken / MOVEQ", N, 4, nop, b_nt)
    def b_tk():
        emit(0x7001)                                    # MOVEQ #1,D0 (Z=0)
        for _ in range(N): emit(0x6600, 0x0004, 0x7200) # BNE.W over a MOVEQ (taken)
    test("BNE.W taken (forward)", N, 2, nop, b_tk)
    def b_bra():
        for _ in range(N): emit(0x6000, 0x0004, 0x7200) # BRA.W over a MOVEQ
    test("BRA.W (forward)", N, 2, nop, b_bra)
    test("loop: SUBQ.L #1,D0 / BNE.S (x100)", 100, 3, lambda: emit(0x7064), lambda: emit(0x5380, 0x66FC))
    test("loop: DBRA D0 (x100)", 100, 3, lambda: emit(0x7063), lambda: emit(0x51C8, 0xFFFE))
    test("loop: MOVE.L (A0)+,(A1)+ / DBRA (x100)", 100, 5, lambda: (lea_a01(), emit(0x7063)), lambda: emit(0x22D8, 0x51C8, 0xFFFC))
    # a branch that alternates taken / not taken: ADDQ, MOVE, AND, BEQ.S (+MOVEQ), DBRA
    def alt():
        emit(0x5281, 0x2401, 0xC483, 0x6702, 0x7800, 0x51C8, 0xFFF4)
    test("loop: alternating BEQ (ADDQ/MOVE/AND/BEQ/[MOVEQ]/DBRA x100)", 100, 9,
         lambda: emit(0x7601, 0x7200, 0x7063), alt)
    def bsr():
        for _ in range(32): emit(0x6100, (0x380 - (st["pc"] + 2)) & 0xFFFF)
    test("BSR.W / RTS", 32, 7, nop, bsr)
    test("JSR (A2) / RTS", 32, 8, nop, rep(32, 0x4E92))
    test("LINK A6,#-8 / UNLK A6", 32, 5, nop, rep(32, 0x4E56, 0xFFF8, 0x4E5E))
    test("MOVEM.L D0-D7/A0-A5,-(A7) / MOVEM.L (A7)+,same", 16, 33, nop, rep(16, 0x48E7, 0xFFFC, 0x4CDF, 0x3FFF))
    test("A-line trap / ADDQ.L #2,2(A7) / RTE", 16, 31, nop, rep(16, 0xA000))
    test("TRAP #0 / RTE", 16, 29, nop, rep(16, 0x4E40))
    test("NOP", 16, 8, nop, rep(16, 0x4E71))
    test("D-cache read miss: MOVE.L (A3),D0 / LEA 16(A3),A3", N, -1, nop, rep(N, 0x2013, 0x47EB, 0x0010))
    test("D-cache write miss: MOVE.L D0,(A4) / LEA 16(A4),A4", N, -1, nop, rep(N, 0x2880, 0x49EC, 0x0010))
    # controls for the store/load stall: the same moves with the two addresses in
    # different cache sets, and an unrelated store followed by a load
    def lea_a01x(): emit(0x41F9, 0x0002, 0x0000, 0x43F9, 0x0002, 0x1040)
    test("MOVE.L (A0),(A1), other set", N, 1, lea_a01x, rep(N, 0x2290))
    test("MOVE.L D0,(A1) / MOVE.L (A0),D1, other set", N, 2, lea_a01x, rep(N, 0x2280, 0x2210))
    test("MOVE.L D0,(A1) / ADD.L D2,D3 / MOVE.L (A0),D1, other set", N, 3, lea_a01x, rep(N, 0x2280, 0xD682, 0x2210))
    # Misaligned operands.  UM 4.2: a read takes one cache access when the
    # operand lies inside a half-line (two long words) and two when it crosses
    # a half-line or a line; a write inside a line takes one.  UM 10.1 leaves
    # the timing to the reader: the figure here is one clock per extra access.
    def lea_o(off): return lambda: emit(0x41F9, 0x0002, off)
    test("misaligned MOVE.L (A0),D0, line+6 (two half-lines)", N, 2, lea_o(6), rep(N, 0x2010))
    test("misaligned MOVE.L (A0),D0, line+14 (two lines)", N, 2, lea_o(14), rep(N, 0x2010))
    test("misaligned MOVE.L D0,(A0), line+2 (one line)", N, 1, lea_o(2), rep(N, 0x2080))
    test("misaligned MOVE.L D0,(A0), line+14 (two lines)", N, 2, lea_o(14), rep(N, 0x2080))
    # the same across two lines that are not in the cache: the first pass
    # ("cold") is the figure, later passes find them cached
    test("cold: MOVE.L (A0),D0 across two lines / LEA 16(A0),A0", N, -1,
         lambda: emit(0x41F9, 0x0003, 0x000E), rep(N, 0x2010, 0x41E8, 0x0010))
    test("cold: MOVE.L D0,(A0) across two lines / LEA 16(A0),A0", N, -1,
         lambda: emit(0x41F9, 0x0003, 0x800E), rep(N, 0x2080, 0x41E8, 0x0010))
    def cp(src, dst): return lambda: emit(0x41F9, 0x0002, src, 0x43F9, 0x0002, 0x1040 + dst, 0x7063)
    cploop = lambda: emit(0x22D8, 0x51C8, 0xFFFC)
    test("loop: MOVE.L (A0)+,(A1)+ / DBRA (x100), other set", 100, 5, cp(0, 0), cploop)
    test("loop: same, source +1 (UM 5.5)", 100, 6, cp(1, 0), cploop)
    test("loop: same, destination +1 (UM 5.25)", 100, 5, cp(0, 1), cploop)
    test("loop: same, both +1 (UM 5.75)", 100, 6, cp(1, 1), cploop)
    test("loop: MOVE.B (A0)+,(A1)+ / DBRA (x100)", 100, 5, cp(0, 0), lambda: emit(0x12D8, 0x51C8, 0xFFFC))
    # mixed reads and writes of cached memory
    test("MOVE.L D0,(A0) / MOVE.L (A0),D1 (same long word)", N, 2, lea_a0, rep(N, 0x2080, 0x2210))
    test("MOVE.L (A0),D0 / ADDQ.L #1,D0 / MOVE.L D0,(A0)", N, 3, lea_a0, rep(N, 0x2010, 0x5280, 0x2080))
    test("MOVE.L (A0)+,D0 / MOVE.L D0,(A1)+, other set", N, 2, lea_a01x, rep(N, 0x2018, 0x22C0))
    # a branch no predictor can learn: the low bit of a 32-bit LFSR
    #   LSR.L #1,D1 / BCC.S +2 / EOR.L D2,D1 / DBRA D0   (UM: taken 7, not taken 9)
    test("loop: LFSR-driven BCC (LSR/BCC/[EOR]/DBRA x100)", 100, 8,
         lambda: emit(0x223C, 0xACE1, 0xACE1, 0x243C, 0x8020, 0x0003, 0x7063),
         lambda: emit(0xE289, 0x6402, 0xB581, 0x51C8, 0xFFF8))
    test("LEA 4(PC),A0 / JMP (A0)", 32, 5, nop, rep(32, 0x41FA, 0x0004, 0x4ED0))
    # the second set: one instruction each from the rest of MC68040UM 10.4 - 10.6
    def t2(name, um, *ws, units=N, setup=nop): test(name, units, um, setup, rep(units, *ws), suite=2)
    t2("(empty: marker overhead)", 0, units=1) if False else test("(empty: marker overhead)", 1, 0, nop, nop, suite=2)
    t2("ADDA.L D0,A1", 2, 0xD3C0)
    t2("SUBA.L D0,A1", 1, 0x93C0)
    t2("ADDA.L (A0),A1", 2, 0xD3D0, setup=lea_a0)
    t2("MOVEA.L (A0),A1", 1, 0x2250, setup=lea_a0)
    t2("MOVEA.W (A0),A1", 2, 0x3250, setup=lea_a0)
    t2("MOVE.L (A0)+,(A1)+", 2, 0x22D8, setup=lea_a01x)
    t2("MOVE.L 4(A0),8(A1)", 2, 0x2368, 4, 8, setup=lea_a01x)
    t2("MOVE.L (A0),(A1), other set", 1, 0x2290, setup=lea_a01x)
    t2("MOVE.L D0,(8,A0,D1.L)", 3, 0x2180, 0x1808, setup=lambda: (lea_a0(), emit(0x7204)))
    t2("ADD.L (8,A0,D1.L),D0", 3, 0xD0B0, 0x1808, setup=lambda: (lea_a0(), emit(0x7204)))
    t2("ADDQ.L #1,4(A0)", 2, 0x52A8, 4, setup=lea_a0)
    t2("ADDI.L #1,D0", 1, 0x0680, 0, 1)
    t2("CMPI.L #1,4(A0)", 2, 0x0CA8, 0, 1, 4, setup=lea_a0)
    t2("CMPA.L D0,A1", 1, 0xB3C0)
    t2("ROL.L #2,D0", 3, 0xE598)
    t2("ROR.L D1,D0", 4, 0xE2B8, setup=lambda: emit(0x7203))
    t2("ROXL.L #1,D0", 5, 0xE390)
    t2("BTST #3,D0", 1, 0x0800, 3)
    t2("BTST D1,D0", 2, 0x0300)
    t2("BSET #3,D0", 3, 0x08C0, 3)
    t2("BCLR D1,D0", 4, 0x0380)
    t2("BCHG #3,(A0)", 3, 0x0850, 3, setup=lea_a0)
    t2("SEQ D0", 2, 0x57C0)
    t2("EXG D0,D1", 1, 0xC141)
    t2("EXG A0,A1", 2, 0xC149)
    t2("EXT.W D0", 2, 0x4880)
    t2("NEG.L D0", 1, 0x4480)
    t2("ADDX.L D0,D1", 1, 0xD380)
    t2("PEA (A0) / ADDQ.L #4,A7", 3, 0x4850, 0x588F, setup=lea_a0)
    t2("MOVE D0,CCR", 2, 0x44C0)
    t2("BFEXTU D0{4:8},D1", 4, 0xE9C0, 0x1108)
    t2("BFTST D0{4:8}", 3, 0xE8C0, 0x0108)
    t2("CMPM.L (A0)+,(A1)+", 3, 0xB388, setup=lea_a01x)
    t2("ABCD D0,D1", 3, 0xC300)
    t2("MOVEM.L D0-D3,-(A7) / MOVEM.L (A7)+,D0-D3", 13, 0x48E7, 0xF000, 0x4CDF, 0x000F, units=16)
    t2("MOVEM.L A0-A1,-(A7) / MOVEM.L (A7)+,A0-A1", 11, 0x48E7, 0x00C0, 0x4CDF, 0x0300, units=16, setup=lea_a01x)
    t2("LEA (8,A0,D1.L),A1", 4, 0x43F0, 0x1808, setup=lambda: (lea_a0(), emit(0x7204)))
    # memory operands that do not read what the instruction before wrote
    t2("ADD.L D0,(A0)+ (each a new long word)", 1, 0xD198, setup=lea_a0)
    t2("ADDQ.L #1,(A0)+", 2, 0x5298, setup=lea_a0)
    t2("MOVE.L D0,4(A0) / MOVE.L 8(A0),D1 (same line, other bytes)", 2, 0x2140, 4, 0x2228, 8, setup=lea_a0)
    t2("MOVE.L D0,(A0)+ / MOVE.L (A1)+,D1 (other line)", 2, 0x20C0, 0x2219, setup=lea_a01x)
    t2("MOVE.L D0,4(A0) / MOVE.L 4(A0),D1 (the same bytes)", 2, 0x2140, 4, 0x2228, 4, setup=lea_a0)
    t2("MOVE.L D0,4(A0) / ADDQ.L #1,D2 / MOVE.L 4(A0),D1", 3, 0x2140, 4, 0x5282, 0x2228, 4, setup=lea_a0)
    t2("MOVE.L D0,4(A0) / ADDQ / ADDQ / MOVE.L 4(A0),D1", 4, 0x2140, 4, 0x5282, 0x5283, 0x2228, 4, setup=lea_a0)
    # The third set: the instruction supply.  Instructions of one to five
    # words with register, immediate and absolute operands (no clock is the
    # data cache's), at both word alignments; and changes of flow of every
    # kind the tables list, with outcomes that repeat, alternate and cycle.
    # MC68040UM 10.4 - 10.6: the figures do not depend on the instruction's
    # length, and a branch costs the same whatever it did the time before.
    def t3(name, um, *ws, units=N, setup=nop): test(name, units, um, setup, rep(units, *ws), suite=3)
    def al(off):                                        # the timed code starts at off (0, 2) in a long word
        def f():
            while st["pc"] % 4 != off: emit(0x7800)             # (the marker after it is two long words)
        return f
    test("(empty: marker overhead)", 1, 0, nop, nop, suite=3)
    t3("1 word:  MOVE.L D0,D1", 1, 0x2200)
    t3("2 words: ADDI.W #1,D0, long-aligned", 1, 0x0640, 1, setup=al(0))
    t3("2 words: ADDI.W #1,D0, word-aligned", 1, 0x0640, 1, setup=al(2))
    t3("2 words: MOVE.W #1,D0", 1, 0x303C, 1)
    t3("2 words: LEA 4(A0),A1 (UM 2)", 2, 0x43E8, 4)
    t3("3 words: MOVE.L #imm,D0", 1, 0x203C, 0x1234, 0x5678)
    t3("3 words: ADDI.L #imm,D0", 1, 0x0680, 0, 1)
    t3("3 words: LEA (xxx).L,A1", 1, 0x43F9, 0x0002, 0x0000)
    t3("3 words: MOVE.L (xxx).L,D0", 1, 0x2039, 0x0002, 0x0000)
    t3("3 words: MOVE.L D0,(xxx).L", 1, 0x23C0, 0x0002, 0x0000)
    t3("3 words: MOVE.L #imm,(A0)", 1, 0x20BC, 0x1234, 0x5678, setup=lea_a0)
    t3("4 words: MOVE.L #imm,4(A0) (UM 2)", 2, 0x217C, 0x1234, 0x5678, 4, setup=lea_a0)
    t3("5 words: MOVE.L #imm,(xxx).L (UM 2)", 2, 0x23FC, 0x1234, 0x5678, 0x0002, 0x0000)
    t3("5 words: MOVE.L (xxx).L,(xxx).L (UM 2)", 2, 0x23F9, 0x0002, 0x0000, 0x0002, 0x1040)
    t3("5 words: CMPI.L #imm,(xxx).L (UM 2)", 2, 0x0CB9, 0x1234, 0x5678, 0x0002, 0x0000)
    t3("1 + 3 words: MOVE.L D0,D1 / MOVE.L #imm,D0", 2, 0x2200, 0x203C, 0x1234, 0x5678)
    t3("1 + 2 words: MOVE.L D0,D1 / ADDI.W #1,D0", 2, 0x2200, 0x0640, 1)
    # unconditional changes of flow, each over one skipped word
    t3("BRA.S", 2, 0x6002, 0x7200)
    t3("BRA.L", 2, 0x60FF, 0x0000, 0x0006, 0x7200)
    def jmp_abs():
        for _ in range(N):
            t = st["pc"] + 8; emit(0x4EF9, t >> 16, t & 0xFFFF, 0x7200)
    test("JMP (xxx).L", N, 3, nop, jmp_abs, suite=3)
    t3("JMP (d16,PC)", 6, 0x4EFA, 0x0004, 0x7200)
    t3("BRA.S to a 3-word instruction (MOVE.L #imm,D0)", 3, 0x6002, 0x7200, 0x203C, 0x1234, 0x5678)
    # conditional, the outcome always the same
    test("BNE.S taken", N, 2, nop, lambda: (emit(0x7001), rep(N, 0x6602, 0x7400)()), suite=3)
    test("BNE.S not taken (in a row)", N, 3, nop, lambda: (emit(0x7000), rep(N, 0x6602)()), suite=3)
    test("BNE.W not taken (in a row)", N, 3, nop, lambda: (emit(0x7000), rep(N, 0x6600, 0x0002)()), suite=3)
    # ... the outcome a pattern: ROL.L #1,D1 (3) / BCC.S +2 (2 taken, 3 not) / [MOVEQ] (1) / DBRA (3)
    def pat(name, bits, um):
        test("loop: ROL/BCC/[MOVEQ]/DBRA x100, carry " + name, 100, um,
             lambda: emit(0x223C, bits >> 16, bits & 0xFFFF, 0x7063),
             lambda: emit(0xE399, 0x6402, 0x7400, 0x51C8, 0xFFF8), suite=3)
    pat("never (UM 8)", 0x00000000, 8)
    pat("always (UM 10)", 0xFFFFFFFF, 10)
    pat("every other time (UM 9)", 0x55555555, 9)
    pat("2 of 3 (UM 9.33)", 0xDB6DB6DB, 9)
    pat("3 of 4 (UM 9.5)", 0x77777777, 9)
    pat("1 of 4 (UM 8.5)", 0x11111111, 8)
    # loops that end: MOVEQ #k,D0 / DBRA D0,itself -- k turns of 3 clocks and the last of 4
    for k in (0, 1, 2, 3, 7):
        t3("MOVEQ #%d,D0 / DBRA D0,itself (loops %d times, then falls out)" % (k, k), 5 + 3 * k,
           0x7000 | k, 0x51C8, 0xFFFE)
    t3("loop of 2: MOVEQ #1,D0 / SUBQ.L #1,D0 + BGE.S (2 turns)", 1 + 1 + 2 + 1 + 3, 0x7001, 0x5380, 0x6CFC)
    # calls and returns
    def bsr3(tgt, n):
        def f():
            for _ in range(n): emit(0x6100, (tgt - (st["pc"] + 2)) & 0xFFFF)
        return f
    test("BSR.W / RTS", 32, 7, nop, bsr3(0x380, 32), suite=3)
    t3("JSR (xxx).L / RTS", 8, 0x4EB9, 0x0000, 0x0380, units=32)
    t3("JSR 0(A2) / RTS", 9, 0x4EAA, 0x0000, units=32)
    test("BSR.W / BSR.S / RTS / RTS (two deep)", 32, 14, nop, bsr3(0x390, 32), suite=3)
    t3("PEA 4(PC) / RTS (a return no call made)", 9, 0x487A, 0x0004, 0x4E75, units=32)
    t3("LEA 4(PC),A0 / JMP (A0)", 5, 0x41FA, 0x0004, 0x4ED0, units=32)
    test("loop: MOVE.L #imm,D1 / DBRA (x100)", 100, 4, lambda: emit(0x7063),
        lambda: emit(0x223C, 0x1234, 0x5678, 0x51C8, 0xFFF8), suite=3)
    # The fourth set: structures that fill, wrap or are thrown away (a sweep
    # for clocks lost by accident, not by design).
    test("(empty: marker overhead)", 1, 0, nop, nop, suite=4)
    def stub(a, *ws):
        for i, w in enumerate(ws): put16(a + 2*i, w)
    def chain(base, leaf):                              # three levels of BSR.W / RTS above the leaf
        t = leaf
        for i in range(3):
            a = base + 8*i
            stub(a, 0x6100, (t - (a + 2)) & 0xFFFF, 0x4E75); t = a
        return t
    stub(0x3A0, 0x4E40, 0x4E75)                         # TRAP #0; RTS
    stub(0x3B0, 0x4E40, *([0x7400] * 16), 0x4E75)       # TRAP #0; 16 x MOVEQ; RTS
    stub(0x3E0, 0x205F, 0x4ED0)                         # MOVEA.L (A7)+,A0; JMP (A0)
    c_rts = chain(0x400, 0x380); c_trap = chain(0x420, 0x3A0)
    c_trpp = chain(0x440, 0x3B0); c_jmp = chain(0x460, 0x3E0)
    def calls(tgt, n=16):
        def f():
            for _ in range(n): emit(0x6100, (tgt - (st["pc"] + 2)) & 0xFFFF)
        return f
    test("calls 4 deep, leaf RTS", 16, 28, nop, calls(c_rts), suite=4)
    test("calls 4 deep, leaf TRAP #0 / RTS (UM 28 + 29)", 16, 57, nop, calls(c_trap), suite=4)
    test("calls 4 deep, leaf TRAP #0 / 16 x MOVEQ / RTS (UM 28 + 29 + 16)", 16, 73, nop, calls(c_trpp), suite=4)
    test("calls 4 deep, leaf MOVEA.L (A7)+,A0 / JMP (A0)", 16, 27, nop, calls(c_jmp), suite=4)
    test("call 1 deep, leaf TRAP #0 / RTS (UM 7 + 29)", 16, 36, nop, calls(0x3A0), suite=4)
    test("call 1 deep, leaf MOVEA.L (A7)+,A0 / JMP (A0)", 16, 6, nop, calls(0x3E0), suite=4)
    # a three-word loop at each place in a half-line
    for off in (0, 2, 4, 6):
        def su(off=off):
            while (st["pc"] + 10) % 8 != off: emit(0x7800)
        test("loop: SUBQ.L #1,D0 / BNE.W (x100), loop at +%d in the half-line" % off, 100, 3, su,
             lambda: emit(0x7064, 0x5380, 0x6600, 0xFFFC), suite=4)
    # data-cache misses: 256 lines at $30000 after 512 lines at $20000 were
    # read (the victims clean) or written (the victims dirty)
    def fillc(op):
        return lambda: emit(0x41F9, 0x0002, 0x0000, 0x323C, 0x01FF, op, 0x41E8, 0x0010, 0x51C9, 0xFFF8)
    def walk(op):
        return lambda: emit(0x43F9, 0x0003, 0x0000, 0x323C, 0x00FF, op, 0x43E9, 0x0010, 0x51C9, 0xFFF8)
    for nm, f in (("clean", 0x2010), ("dirty", 0x2080)):
        test("miss, %s victim: MOVE.L (A1),D0 / LEA 16(A1),A1 / DBRA" % nm, 256, 6, fillc(f), walk(0x2011), suite=4)
        test("miss, %s victim: MOVE.L D0,(A1) / LEA / DBRA" % nm, 256, 6, fillc(f), walk(0x2280), suite=4)
        test("miss, %s victim: ADDQ.L #1,(A1) / LEA / DBRA" % nm, 256, 6, fillc(f), walk(0x5291), suite=4)
    # a miss with work behind it (the early answer, MC68040UM 4.6.1: the
    # requested long word is available to the IU as it arrives): the load's
    # value used at once, then work that touches no memory; and the next long
    # word of the same line read right after the missed one
    def walkw(*ws):
        n = len(ws) + 3       # the words from the loop top to DBRA's extension
        return lambda: emit(0x43F9, 0x0003, 0x0000, 0x323C, 0x00FF, *ws, 0x43E9, 0x0010,
                            0x51C9, (-(2 * n)) & 0xFFFF)
    test("miss, then use + 6 x ADDQ: MOVE.L (A1),D0 / ADD.L D0,D2 / ... / LEA / DBRA", 256, -1,
         fillc(0x2010), walkw(0x2011, 0xD480, 0x5282, 0x5282, 0x5282, 0x5282, 0x5282, 0x5282), suite=4)
    test("miss, then the next long word: MOVE.L (A1),D0 / MOVE.L 4(A1),D2 / LEA / DBRA", 256, -1,
         fillc(0x2010), walkw(0x2011, 0x2429, 0x0004), suite=4)
    def t4(name, um, *ws, units=N, setup=nop): test(name, units, um, setup, rep(units, *ws), suite=4)
    t4("ADDQ.L #1,(A0) / MOVE.L 4(A0),D0 (same line, other bytes)", 2, 0x5290, 0x2028, 4, setup=lea_a0)
    t4("MOVE.L D1,(A0) / MOVE.L 4(A0),D0 (same line, other bytes)", 2, 0x2081, 0x2028, 4, setup=lea_a0)
    a6 = lambda: emit(0x4DF9, 0x0002, 0x0000)
    t4("MOVE.L 8(A6),-(A7) / PEA 12(A6) / ADDQ.L #8,A7", 5, 0x2F2E, 8, 0x486E, 12, 0x508F, setup=a6)
    t4("MOVE.L D0,-(A7) / PEA 12(A6) / ADDQ.L #8,A7", 4, 0x2F00, 0x486E, 12, 0x508F, setup=a6)
    ptr = lambda: (lea_a0(), emit(0x2088))
    t4("MOVEA.L (A0),A1 / MOVE.L (A1),D0 / MOVE.L 4(A1),D1", 3, 0x2250, 0x2011, 0x2229, 4, setup=ptr)
    t4("MOVEA.L (A0),A1 / MOVE.L (A1),D0 / MOVEQ / MOVE.L 4(A1),D1", 4, 0x2250, 0x2011, 0x7400, 0x2229, 4, setup=ptr)
    emit(0x7E7F, 0x23C7, MARK >> 16, MARK & 0xFFFF)     # marker $7F: end of pass
    emit(0x5386)                                        # SUBQ.L #1,D6
    emit(0x6600, (top - (st["pc"] + 2)) & 0xFFFF)       # BNE.W top
    emit(0x7E7E, 0x23C7, MARK >> 16, MARK & 0xFFFF)     # marker $7E: done
    emit(0x4E72, 0x2700)
    print(mode, "program ends at %x" % st["pc"])
    with open("prog_%s.hex" % mode, "w", newline="\n") as f:
        for a in range(0, len(mem), 4):
            f.write("%08x\n" % int.from_bytes(mem[a:a+4], "big"))
    with open("tests.txt", "w", newline="\n") as f:
        for n, u, um in tests: f.write("%d|%d|%s\n" % (u, um, n))

build("wt"); build("cb")
