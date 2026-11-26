# Random memory-operand programs for cpu040, with the memory image they must
# leave behind.  The program is checked by its result, not by its timing:
#
#   python3 gen.py <seed> <wt|cb|mm> <ops>   ->  prog.hex, exp.hex
#
# wt: translation off, write-through.  cb: DTT0 makes $00xxxxxx copyback.
# mm: the MMU on with 4 KB pages (an identity map; the test region's pages
# alternate copyback and write-through), as the Mac OS runs the 68040.
#
# Operands sit on and around cache line boundaries, in lines that share a
# cache set (so lines are evicted and dirty ones pushed), in a second region
# the data cache may not hold (DTT1: noncachable), and are read back soon
# after they are written.  Sizes are byte, word and long at any address.
# Branches on memory data that no predictor can learn discard uops in flight.
# The model below is the 68040's: big-endian bytes, nothing else.
import random, sys

seed = int(sys.argv[1]); mode = sys.argv[2]; nops = int(sys.argv[3])
rnd = random.Random(seed * 4 + ["wt", "cb", "mm"].index(mode))
MEMLONGS = 1 << 17
MARK = 0x50000000
mem = bytearray(MEMLONGS * 4)          # the program image, then left alone
mod = None                             # the model's memory
pc = [0x1000]

def put16(a, w): mem[a] = (w >> 8) & 255; mem[a + 1] = w & 255
def put32(a, l): put16(a, l >> 16); put16(a + 2, l & 0xFFFF)
def emit(*ws):
    for w in ws:
        put16(pc[0], w & 0xFFFF); pc[0] += 2

BASE = [0x00024000, 0x00025003, 0x01034000]      # A0, A1 (cached), A2 (noncachable)
D = [0] * 6
SZ = {1: 1, 2: 3, 4: 2}                # MOVE's size field
SZQ = {1: 0, 2: 1, 4: 2}               # ADDQ / TST / ADD's

# hot addresses: around line boundaries of lines that collide in the cache
# (sets repeat every 1 KB in the 68040, every 2 KB in this core's larger
# cache), and a few at random
def hot(lo):
    out = []
    for k in range(12):
        if k < 8:
            line = lo + 0x800 * rnd.randrange(8) + 16 * rnd.randrange(4)
        else:
            # the last line of a 2 KB block (the tag changes with the next
            # line) or of a page (so does the translation)
            line = (lo & ~0x7FF) + 0x800 * rnd.randrange(1, 8) - 32
        for _ in range(4):
            out.append(line + 16 + rnd.randrange(-4, 4))
    for _ in range(8):
        out.append(lo + rnd.randrange(0x3F00))
    return out
HOT = [hot(0x20100), hot(0x30100)]     # cached, noncachable (physical)

def pick():
    """an operand: (address register, d16, physical address)"""
    if rnd.random() < 0.2:
        phys = rnd.choice(HOT[1]); a = 2
        return a, phys - (BASE[2] & 0x7FFFF), phys
    phys = rnd.choice(HOT[0]); a = rnd.randrange(2)
    return a, phys - BASE[a], phys

def rd(p, n): return int.from_bytes(mod[p:p + n], "big")
def wr(p, n, v): mod[p:p + n] = (v & ((1 << (8 * n)) - 1)).to_bytes(n, "big")
def setreg(r, n, v):
    m = (1 << (8 * n)) - 1
    D[r] = (D[r] & ~m & 0xFFFFFFFF) | (v & m)

def op():
    """emit one operation, apply it to the model; returns its words (already emitted)"""
    k = rnd.random(); n = rnd.choice([1, 2, 4, 4]); r = rnd.randrange(6)
    if k < 0.30:                                    # MOVE.s Dr,(d16,Aa)
        a, d, p = pick()
        emit((SZ[n] << 12) | (a << 9) | (5 << 6) | r, d)
        wr(p, n, D[r])
    elif k < 0.60:                                  # MOVE.s (d16,Aa),Dr
        a, d, p = pick()
        emit((SZ[n] << 12) | (r << 9) | (5 << 3) | a, d)
        setreg(r, n, rd(p, n))
    elif k < 0.72:                                  # MOVE.s (d16,Aa),(d16,Ab)
        a, d, p = pick(); b, e, q = pick()
        emit((SZ[n] << 12) | (b << 9) | (5 << 6) | (5 << 3) | a, d, e)
        wr(q, n, rd(p, n))
    elif k < 0.82:                                  # ADD.s Dr,(d16,Aa)
        a, d, p = pick()
        emit(0xD100 | (r << 9) | (SZQ[n] << 6) | (5 << 3) | a, d)
        wr(p, n, rd(p, n) + D[r])
    elif k < 0.90:                                  # ADDQ.s #q,(d16,Aa)
        a, d, p = pick(); q = rnd.randrange(1, 9)
        emit(0x5000 | ((q & 7) << 9) | (SZQ[n] << 6) | (5 << 3) | a, d)
        wr(p, n, rd(p, n) + q)
    else:                                           # ADD.L Ds,Dr
        s = rnd.randrange(6)
        emit(0xD080 | (r << 9) | s)
        D[r] = (D[r] + D[s]) & 0xFFFFFFFF

# vectors, then the program
put32(0, 0x00008000); put32(4, 0x00001000)
if mode == "cb":
    emit(0x203C, 0x0000, 0xC020, 0x4E7B, 0x0006)    # DTT0: $00xxxxxx copyback
if mode == "mm":
    # root $60000 (index A31-25), pointer tables $60200 / $60400 (A24-18),
    # page tables $60600, $60700 (RAM, 2 x 256 KB) and $60800 (the marker's
    # page).  U and M are set already: the table search writes nothing back.
    ROOT, PA, PB, P0, P1, PM = 0x60000, 0x60200, 0x60400, 0x60600, 0x60700, 0x60800
    put32(ROOT + 4 * 0, PA | 0xA); put32(ROOT + 4 * (MARK >> 25), PB | 0xA)
    put32(PA + 0, P0 | 0xA); put32(PA + 4, P1 | 0xA)
    put32(PB + 4 * ((MARK >> 18) & 127), PM | 0xA)
    put32(PM + 4 * ((MARK >> 12) & 63), MARK | (3 << 5) | 0x19)
    for pg in range(128):
        cm = 0
        if 0x20 <= pg < 0x28: cm = 1 if (pg & 1) else 0     # the cached region: copyback / write-through
        put32((P0 if pg < 64 else P1) + 4 * (pg & 63), (pg << 12) | (cm << 5) | 0x19)
    emit(0x203C, ROOT >> 16, ROOT & 0xFFFF, 0x4E7B, 0x0806, 0x4E7B, 0x0807)   # URP, SRP
    emit(0x203C, 0x0000, 0x8000, 0x4E7B, 0x0003)                             # TC: enable, 4 KB
emit(0x203C, 0x0100, 0xC060, 0x4E7B, 0x0007)        # DTT1: $01xxxxxx noncachable
emit(0x203C, 0x8000, 0x8000, 0x4E7B, 0x0002)        # CACR: both caches on
for i, b in enumerate(BASE): emit(0x41F9 | (i << 9), b >> 16, b & 0xFFFF)
for r in range(6):
    D[r] = rnd.getrandbits(32)
    emit(0x203C | (r << 9), D[r] >> 16, D[r] & 0xFFFF)
# the regions start with random contents (part of the image)
for lo in (0x20000, 0x30000):
    for a in range(lo, lo + 0x8000): mem[a] = rnd.getrandbits(8)
mod = bytearray(mem)

i = 0
while i < nops:
    if rnd.random() < 0.12:
        # TST.s (d16,Aa) / Bcc.S over the next operation
        a, d, p = pick(); n = rnd.choice([1, 2, 4])
        emit(0x4A00 | (SZQ[n] << 6) | (5 << 3) | a, d)
        z = rd(p, n) == 0
        if rnd.random() < 0.5:
            # make the outcome vary: the operand was written by earlier ops
            pass
        bne = rnd.random() < 0.5
        at = pc[0]; emit(0x6600 if bne else 0x6700)
        taken = (not z) if bne else z
        save_mod, save_D, save_state = bytes(mod), list(D), rnd.getstate()
        op()
        put16(at, (0x6600 if bne else 0x6700) | (pc[0] - at - 2))
        if taken:                                   # the skipped operation did not happen
            mod[:] = save_mod; D[:] = save_D
        i += 2
    else:
        op(); i += 1

for r in range(6):                                  # the registers, to memory
    emit(0x23C0 | r, 0x0007, 0xF000 + 4 * r)
    wr(0x7F000 + 4 * r, 4, D[r])
emit(0xF478)                                        # CPUSHA DC: dirty lines to memory
emit(0x7E7E, 0x23C7, MARK >> 16, MARK & 0xFFFF)     # done
emit(0x4E72, 0x2700)
# the model's image is the program's image (code included) plus the data
mod[0:0x20000] = mem[0:0x20000]
for name, img in (("prog.hex", mem), ("exp.hex", mod)):
    with open(name, "w", newline="\n") as f:
        for a in range(0, len(img), 4):
            f.write("%08x\n" % int.from_bytes(img[a:a + 4], "big"))
print("seed %d %s: %d ops, ends at %x" % (seed, mode, nops, pc[0]))
