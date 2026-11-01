#include <cassert>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include "file_io.h"
#include "user_io.h"
#include "support/mac/swim2.h"

fileTYPE::fileTYPE() : filp(nullptr), mode(0), type(0), zip(nullptr), size(0), offset(0) {}
fileTYPE::~fileTYPE() {}

static char names[2][64] = {"MacLC475", ""};
char *user_io_get_core_name(int original) { return names[original]; }

static uint16_t metadata[7];
static uint16_t control[7] = {0x5343, 0x0101, 0x3210, 0x7654, 0, 0, 6};
static uint8_t payload[512];
static uint8_t received[512];
static bool enabled, transferred, sync_called, reading, read_called;
static unsigned command, word, probes, transfers, results;
static std::vector<uint16_t> response;
static std::vector<uint16_t> actions;
static unsigned unmounts;
enum Failure { NONE, SEEK, WRITE, FLUSH, SYNC, STAT, SHORT_READ, READ_ERROR, EOF_READ };
static Failure failure;

void EnableIO()
{
    assert(!enabled);
    enabled = true;
    word = 0;
}

void DisableIO()
{
    assert(enabled);
    if (command == 0x08 || command == 0x0a || command == 0x0c) assert(word == 7);
    if (command == 0x09 || command == 0x0b || command == 0x0d) assert(word == 4);
    enabled = false;
}

uint16_t fpga_spi(uint16_t value)
{
    assert(enabled);
    if (!word++) {
        command = value;
        if (command == 0x0c) return control[0];
        if (command == 0x0d) return 0;
        if (command == 0x08 || command == 0x0a) {
            assert(command == (reading ? 0x0a : 0x08));
            ++probes; return metadata[0];
        }
        if (command == 0x09 || command == 0x0b) {
            assert(transferred && command == (reading ? 0x0b : 0x09));
            ++results; return 0;
        }
        assert(command == (reading ? 0x617 : 0x618));
        ++transfers;
        return 0;
    }
    if (command == 0x0c) {
        assert(value == 0 && word <= 7);
        return control[word - 1];
    }
    if (command == 0x0d) {
        assert(word <= 4);
        actions.push_back(value);
        return 0;
    }
    if (command == 0x08 || command == 0x0a) {
        assert(value == 0 && word <= 7);
        return metadata[word - 1];
    }
    assert((command == 0x09 || command == 0x0b) && word <= 4);
    response.push_back(value);
    return 0;
}

int user_io_file_mount(const char *name, unsigned char index, char pre, int pre_size)
{
    assert(!enabled && !name[0] && index == 6 && !pre && !pre_size);
    assert(swim2_can_mount(index, true));
    ++unmounts;
    return 1;
}

uint16_t spi_uio_cmd_cont(uint16_t value)
{
    EnableIO();
    return fpga_spi(value);
}

void spi_block_read(uint8_t *data, int wide, int size)
{
    assert(enabled && command == 0x618 && wide == 1 && size == 512);
    assert(!transferred);
    std::memcpy(data, payload, size);
    transferred = true;
}

void spi_block_write(const uint8_t *data, int wide, int size)
{
    assert(reading && enabled && command == 0x617 && wide == 1 && size == 512);
    assert(!transferred);
    std::memcpy(received, data, size);
    transferred = true;
}

extern "C" int __real_fseeko64(FILE *, off64_t, int);
extern "C" size_t __real_fwrite(const void *, size_t, size_t, FILE *);
extern "C" int __real_fflush(FILE *);
extern "C" int __real_fsync(int);
extern "C" int __real_fstat64(int, struct stat64 *);
extern "C" size_t __real_fread(void *, size_t, size_t, FILE *);
extern "C" int __real_ferror(FILE *);

extern "C" int __wrap_fseeko64(FILE *file, off64_t offset, int origin)
{
    assert(!enabled && (reading ? !transferred : transferred));
    if (failure == SEEK) { errno = EIO; return -1; }
    return __real_fseeko64(file, offset, origin);
}

extern "C" size_t __wrap_fread(void *data, size_t size, size_t count, FILE *file)
{
    assert(reading && !enabled && !transferred);
    read_called = true;
    if (failure == EOF_READ) assert(ftruncate(fileno(file), 2047) == 0);
    if (failure == SHORT_READ) return __real_fread(data, size, count - 1, file);
    return __real_fread(data, size, count, file);
}

extern "C" int __wrap_ferror(FILE *file)
{
    assert(reading && !enabled && !transferred);
    return failure == READ_ERROR ? 1 : __real_ferror(file);
}

extern "C" size_t __wrap_fwrite(const void *data, size_t size, size_t count, FILE *file)
{
    assert(!enabled && transferred);
    if (failure == WRITE) { errno = ENOSPC; return count - 1; }
    return __real_fwrite(data, size, count, file);
}

extern "C" int __wrap_fflush(FILE *file)
{
    assert(!enabled && transferred);
    if (failure == FLUSH) { errno = ENOSPC; return EOF; }
    return __real_fflush(file);
}

extern "C" int __wrap_fsync(int fd)
{
    assert(!enabled && transferred);
    sync_called = true;
    if (failure == SYNC) { errno = EIO; return -1; }
    return __real_fsync(fd);
}

extern "C" int __wrap_fstat64(int fd, struct stat64 *st)
{
    if (failure == STAT) { errno = EIO; return -1; }
    return __real_fstat64(fd, st);
}

static void setup(bool read_request = false, uint32_t sector = 1)
{
    assert(!enabled);
    reading = read_request;
    metadata[0] = reading ? 0x5352 : 0x5357;
    metadata[1] = 0x010b;
    metadata[2] = 0x9abc;
    metadata[3] = 0x1234;
    metadata[4] = sector;
    metadata[5] = sector >> 16;
    metadata[6] = 6;
    failure = NONE;
    transferred = sync_called = read_called = false;
    probes = transfers = results = 0;
    response.clear();
}

static void load(fileTYPE *file, bool success, uint32_t sector = 1, const uint8_t *expected = nullptr)
{
    uint64_t cache_lba = 1;
    __off64_t old_offset = file ? file->offset : 0;
    assert(swim2_sd_service(6, file, 1, sector, 512, 0x600, 1, &cache_lba) == 1);
    assert(cache_lba == UINT64_MAX);
    assert(probes == 1 && transfers == 1 && results == 1 && !sync_called);
    assert(response == std::vector<uint16_t>({0x9abc, 0x1234, uint16_t(success ? 0 : 1)}));
    assert(!enabled);
    if (success) {
        assert(read_called && file->offset == (__off64_t(sector) + 1) * 512);
        assert(expected && !std::memcmp(received, expected, sizeof(received)));
    } else {
        if (file) assert(file->offset == old_offset);
        for (uint8_t value : received) assert(value == 0);
    }
}

static void save(fileTYPE *file, bool success, uint32_t sector = 1)
{
    uint64_t cache_lba = 1;
    assert(swim2_sd_service(6, file, 2, sector, 512, 0x600, 1, &cache_lba) == 1);
    assert(cache_lba == UINT64_MAX);
    assert(probes == 1 && transfers == 1 && results == 1);
    assert(response == std::vector<uint16_t>({0x9abc, 0x1234, uint16_t(success ? 0 : 1)}));
    if (success) assert(sync_called);
    assert(!enabled);
}

static void blocked(fileTYPE *file, uint64_t lba = 1, uint32_t size = 512,
                    int ack = 0x600, int wide = 1)
{
    uint64_t cache_lba = 1;
    assert(swim2_sd_service(6, file, reading ? 1 : 2, lba, size, ack, wide, &cache_lba) == 1);
    assert(cache_lba == 1 && probes == 1 && transfers == 0 && results == 0);
}

static void reload(const char *path, const uint8_t *expected)
{
    int fd = open(path, O_RDONLY);
    assert(fd >= 0);
    uint8_t data[2048];
    assert(read(fd, data, sizeof(data)) == sizeof(data));
    assert(close(fd) == 0);
    for (unsigned i = 0; i < sizeof(data); ++i)
        assert(data[i] == (i >= 512 && i < 1024 ? expected[i - 512] : 0xa5));
}

int main(int argc, char **argv)
{
    const char *core_name = argc > 1 ? argv[1] : "MacLC475";
    std::snprintf(names[0], sizeof(names[0]), "%s", core_name);
    char path[] = "/tmp/q605-swim2-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    uint8_t original[2048];
    std::memset(original, 0xa5, sizeof(original));
    assert(write(fd, original, sizeof(original)) == sizeof(original));
    fileTYPE file;
    file.filp = fdopen(fd, "r+");
    file.mode = O_RDWR;
    file.size = sizeof(original);
    assert(file.filp);

    for (unsigned i = 0; i < sizeof(payload); ++i) payload[i] = (i * 29) ^ (i >> 4);
    setup();
    save(&file, true);
    assert(file.offset == 1024 && file.size == sizeof(original));
    assert(fclose(file.filp) == 0);
    reload(path, payload);

    file.filp = fopen(path, "r+");
    for (unsigned i = 0; i < sizeof(payload); ++i) payload[i] ^= 0x67;
    setup();
    save(&file, true);
    assert(fclose(file.filp) == 0);
    reload(path, payload);
    file.filp = fopen(path, "r+");

    for (Failure f : {SEEK, WRITE, FLUSH, SYNC, STAT}) {
        setup();
        failure = f;
        save(&file, false);
        setup();
        save(&file, true);
    }

    setup(); save(nullptr, false);
    setup(); file.zip = reinterpret_cast<fileZipArchive *>(1); save(&file, false); file.zip = nullptr;
    setup(); file.type = 2; save(&file, false); file.type = 0;
    setup(); file.size = 512; save(&file, false); file.size = sizeof(original);
    setup(); metadata[4] = 4;
    uint64_t cache = 3;
    assert(swim2_sd_service(6, &file, 2, 4, 512, 0x600, 1, &cache) == 1);
    assert(response.back() == 1 && !sync_called);
    assert(fclose(file.filp) == 0);
    file.filp = fopen(path, "r");
    setup(); save(&file, false);
    assert(fclose(file.filp) == 0);
    file.filp = fopen(path, "a+");
    setup(); save(&file, false);
    assert(fclose(file.filp) == 0);
    file.filp = fopen(path, "r+");
    assert(ftruncate(fileno(file.filp), 1536) == 0);
    setup(); save(&file, false);
    file.size = 1536;
    assert(ftruncate(fileno(file.filp), 1535) == 0);
    file.size = 1535;
    setup(); save(&file, false);
    assert(fclose(file.filp) == 0);
    file.filp = nullptr;

    setup(); metadata[1] = 0x0203; blocked(&file);
    setup(); metadata[1] = 0x0101; blocked(&file);
    setup(); metadata[1] = 0x0107; blocked(&file);
    setup(); metadata[1] = 0x0113; blocked(&file);
    setup(); metadata[6] = 5; blocked(&file);
    setup(); blocked(&file, 2);
    setup(); blocked(&file, 0x100000001ULL);
    setup(); blocked(&file, 1, 1024);
    setup(); blocked(&file, 1, 512, 0x500);
    setup(); blocked(&file, 1, 512, 0x600, 0);
    setup(); metadata[0] = 0;
    assert(swim2_sd_service(6, &file, 2, 1, 512, 0x600, 1, nullptr) == 0);
    assert(transfers == 0 && results == 0);
    setup();
    assert(swim2_sd_service(2, &file, 2, 1, 512, 0x200, 1, nullptr) == 0);
    assert(swim2_sd_service(6, &file, 3, 1, 512, 0x600, 1, nullptr) == 0);
    std::strcpy(names[0], "MacQuadra800");
    assert(swim2_sd_service(6, &file, 2, 1, 512, 0x600, 1, nullptr) == 0);
    assert(probes == 0);
    assert(swim2_can_mount(6));
    std::strcpy(names[1], "MACQUADRA605_CPU040");
    setup(); assert(!swim2_can_mount(6));
    std::strcpy(names[0], core_name);
    names[1][0] = 0;

    for (uint16_t status : {0x0101, 0x0108, 0x010b, 0x0107, 0x0200, 0x0110}) {
        setup(); metadata[1] = status; assert(!swim2_can_mount(6));
        assert(probes == 1 && transfers == 0 && results == 0);
    }
    setup(); metadata[1] = 0x0100; assert(swim2_can_mount(6));
    setup(); metadata[1] = 0x0100; metadata[6] = 5; assert(!swim2_can_mount(6));
    setup(); metadata[0] = 0; assert(swim2_can_mount(6));
    setup(); assert(swim2_can_mount(2)); assert(probes == 0);

    // Eject retains the handle until the matching mount is fully released.
    setup(); assert(!swim2_can_mount(6, true));
    assert(actions == std::vector<uint16_t>({0x3210, 0x7654, 1}));
    for (unsigned i = 0; i < 8; ++i) swim2_poll();
    assert(unmounts == 0);
    control[1] = 0x0117; // Failed live save with eject pending.
    assert(swim2_retry());
    assert(actions.back() == 3);
    swim2_poll(); assert(unmounts == 0);
    control[1] = 0x0100; metadata[1] = 0x0100;
    swim2_poll(); assert(unmounts == 1);
    swim2_poll(); assert(unmounts == 1);

    setup(); control[1] = 0x0101;
    assert(!swim2_can_mount(6, true));
    ++control[2]; swim2_poll(); // Stale pending eject cannot close a new mount.
    control[1] = 0x0100; swim2_poll(); assert(unmounts == 1);
    setup(); control[1] = 0x0101;
    assert(!swim2_can_mount(6, true));
    metadata[1] = 0x0100; assert(swim2_can_mount(6));
    control[1] = 0x0100; swim2_poll(); assert(unmounts == 1);

    actions.clear(); setup(); control[0] = 0;
    assert(!swim2_can_mount(6, true)); assert(actions.empty());
    control[0] = 0x5343; control[6] = 5;
    assert(!swim2_can_mount(6, true)); assert(actions.empty());
    control[6] = 6; control[1] = 0x0121;
    assert(!swim2_can_mount(6, true)); assert(actions.empty());
    assert(!swim2_retry());
    control[1] = 0x0109; assert(swim2_retry()); assert(actions.back() == 2);
    control[1] = 0x010b; assert(!swim2_retry());
    control[1] = 0x0101; assert(!swim2_retry());
    actions.clear();
    setup(); assert(!swim2_can_mount(6)); assert(actions.empty());
    assert(!swim2_can_mount(6, true));
    std::strcpy(names[0], "MacQuadra800"); swim2_poll();
    std::strcpy(names[0], core_name);
    control[1] = 0x0100; swim2_poll(); assert(unmounts == 1);

    fd = open(path, O_WRONLY | O_TRUNC);
    assert(fd >= 0 && write(fd, original, sizeof(original)) == sizeof(original));
    assert(pwrite(fd, payload, sizeof(payload), 512) == sizeof(payload));
    assert(close(fd) == 0);
    file.size = sizeof(original);
    file.filp = fopen(path, "r");
    uint8_t empty_sector[512];
    std::memset(empty_sector, 0xa5, sizeof(empty_sector));
    setup(true); load(&file, true, 1, payload);
    setup(true); load(&file, true, 1, payload);
    setup(true, 0); load(&file, true, 0, empty_sector);
    setup(true, 3); load(&file, true, 3, empty_sector);
    for (Failure f : {SEEK, SHORT_READ, READ_ERROR, STAT}) {
        setup(true); failure = f; load(&file, false);
        setup(true); load(&file, true, 1, payload);
    }
    setup(true, 4); load(&file, false, 4);
    setup(true); file.size = 512; load(&file, false); file.size = sizeof(original);
    setup(true); file.zip = reinterpret_cast<fileZipArchive *>(1); load(&file, false); file.zip = nullptr;
    setup(true); file.type = 2; load(&file, false); file.type = 0;
    setup(true); load(nullptr, false);
    assert(fclose(file.filp) == 0);
    fd = open(path, O_WRONLY);
    assert(fd >= 0);
    file.filp = fdopen(fd, "w");
    setup(true); load(&file, false);
    assert(fclose(file.filp) == 0);
    file.filp = fopen(path, "r+");
    setup(true, 3); failure = EOF_READ; load(&file, false, 3);
    assert(fclose(file.filp) == 0);
    file.filp = fopen(path, "r");
    setup(true); load(&file, false);
    file.size = 2047;
    setup(true); load(&file, false);
    assert(fclose(file.filp) == 0); file.filp = nullptr;

    for (uint16_t status : {0x020b, 0x0103, 0x0109, 0x010f, 0x011b}) {
        setup(true); metadata[1] = status; blocked(&file);
    }
    setup(true); metadata[6] = 5; blocked(&file);
    setup(true); blocked(&file, 2);
    setup(true); blocked(&file, 0x100000001ULL);
    setup(true); blocked(&file, 1, 1024);
    setup(true); blocked(&file, 1, 512, 0x500);
    setup(true); blocked(&file, 1, 512, 0x600, 0);
    setup(true); metadata[0] = 0;
    assert(swim2_sd_service(6, &file, 1, 1, 512, 0x600, 1, nullptr) == 0);
    assert(transfers == 0 && results == 0);
    setup(true);
    assert(swim2_sd_service(2, &file, 1, 1, 512, 0x200, 1, nullptr) == 0);
    std::strcpy(names[0], "MacQuadra800");
    assert(swim2_sd_service(6, &file, 1, 1, 512, 0x600, 1, nullptr) == 0);
    assert(probes == 0);
    std::strcpy(names[0], core_name);
    // Synthetic catalog writes, including a retry and replacement of LBA 30.
    std::vector<uint8_t> expected_image(1474560, 0xa5);
    fd = open(path, O_WRONLY | O_TRUNC);
    assert(fd >= 0);
    assert(write(fd, expected_image.data(), expected_image.size()) == ssize_t(expected_image.size()));
    assert(close(fd) == 0);
    file.size = expected_image.size();
    file.offset = 0;
    file.filp = fopen(path, "r+");
    assert(file.filp);
    unsigned attempt = 0;
    for (uint32_t sector : {2, 26, 28, 30, 29, 30}) {
        for (unsigned i = 0; i < sizeof(payload); ++i) payload[i] = i ^ (i >> 8) ^ (0x60 + attempt);
        if (attempt == 3) {
            setup(false, sector); failure = SYNC; save(&file, false, sector);
        }
        setup(false, sector); save(&file, true, sector);
        assert(file.offset == (__off64_t(sector) + 1) * 512 && file.size == __off64_t(expected_image.size()));
        std::memcpy(expected_image.data() + sector * 512, payload, sizeof(payload));
        ++attempt;
    }
    assert(fclose(file.filp) == 0);
    std::vector<uint8_t> reloaded(expected_image.size());
    fd = open(path, O_RDONLY);
    assert(fd >= 0);
    assert(read(fd, reloaded.data(), reloaded.size()) == ssize_t(reloaded.size()));
    assert(close(fd) == 0 && reloaded == expected_image);
    file.filp = fopen(path, "r");
    assert(file.filp);
    for (uint32_t sector : {2, 26, 28, 30, 29}) {
        setup(true, sector); load(&file, true, sector, expected_image.data() + sector * 512);
    }
    assert(fclose(file.filp) == 0); file.filp = nullptr;
    assert(unlink(path) == 0);
    std::puts("PASS: SWIM II host real-file read/reload, seek/read/write/flush/sync failures, retries, protocol and mount guard");
}
