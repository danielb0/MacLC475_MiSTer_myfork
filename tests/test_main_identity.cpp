#include <cassert>
#include <cstdio>
#include <cstring>
#include "support/mac/mac.h"

static char core_names[2][64];

char *user_io_get_core_name(int original)
{
    return core_names[original];
}

static void check(const char *name, const char *original, bool family, bool optimized,
                  int cd_slot, int toolbox_slot, bool ring_eth = false)
{
    std::snprintf(core_names[0], sizeof(core_names[0]), "%s", name);
    std::snprintf(core_names[1], sizeof(core_names[1]), "%s", original);
    assert(bool(is_mac_scsi_family()) == family);
    assert(bool(is_mac_scsi_optimized()) == optimized);
    assert(mac_cdrom_slot() == cd_slot);
    assert(mac_toolbox_slot() == toolbox_slot);
    assert(mac_cd_toolbox_slot() == (toolbox_slot < 0 ? -1 : 5));
    assert(bool(is_mac_ring_eth()) == ring_eth);
}

int main()
{
    check("MacQuadra605", "", true, true, 4, 3);
    check("macquadra605_cpu040", "", true, true, 4, 3);
    check("Renamed", "MacQuadra605", true, true, 4, 3);
    check("MACQUADRA605", "", true, true, 4, 3);
    check("MacLC475", "", true, true, 4, 3);
    check("maclc475_trace", "", true, true, 4, 3);
    check("Renamed", "MACLC475", true, true, 4, 3);
    check("MacQuadra800", "", true, true, 4, 3);
    check("MacLC", "", true, false, 4, 3);
    check("MacLCII", "", true, false, 4, 3);
    check("MacPlus", "", true, false, 4, -1);
    check("MacPPC7300", "", true, true, 4, 3, true);
    check("MENU", "", false, false, -1, -1);
    std::puts("PASS: Main Mac SCSI recognition and slots, 13 core-name cases");
}
