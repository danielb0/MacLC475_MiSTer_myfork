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
