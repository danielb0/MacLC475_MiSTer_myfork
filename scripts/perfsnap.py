import mmap, os, struct, time
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x27F00000)
def snap():
    w = struct.unpack_from("<46I", m, 0)
    return w[1], w[2:44]
a = snap(); time.sleep(2); b = snap()
print("seq", a[0], "->", b[0])
for i in range(42):
    d = (b[1][i] - a[1][i]) & 0xFFFFFFFF
    print("c%-2d %10d  +%d" % (i, b[1][i], d))
