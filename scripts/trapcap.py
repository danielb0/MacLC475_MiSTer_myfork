import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x27F00000)
w = struct.unpack_from("<14I", m, 22 * 8)
c = w[2:10]
print("seq %d" % w[1])
print("F-line traps %d, illegal traps %d" % (c[0] >> 16, c[0] & 0xFFFF))
print("PC       %08X" % c[1])
print("vector   %d  format %X  opword valid %d" % (c[2] >> 24, (c[2] >> 20) & 0xF, (c[2] >> 19) & 1))
print("opword   %04X" % (c[2] & 0xFFFF))
print("handler  %08X" % c[4])
s = c[6]
print("irqs taken %d  IPL in %d  SR mask %d  stopped %d  wb_v %d" % (
    s >> 16, s & 7, (s >> 8) & 7, (s >> 11) & 1, (s >> 6) & 1))
print("live: irq_pend %d  cm_block %d  halted %d  dbl_fault %d  cm_pend %d"
      "  ipend_r %d  cm_n_v %d  trace_defer %d" % (
    (s >> 15) & 1, (s >> 14) & 1, (s >> 13) & 1, (s >> 12) & 1,
    (s >> 7) & 1, (s >> 5) & 1, (s >> 4) & 1, (s >> 3) & 1))
print("boundaries with irq pending %d  missed %d  (16-bit, wrap)" % (
    c[7] >> 16, c[7] & 0xFFFF))
print("last miss: PC %08X  SR %04X  IPL %d" % (c[5], c[3] >> 16, c[3] & 7))
