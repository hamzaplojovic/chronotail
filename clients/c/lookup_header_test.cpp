#include "chronotail.h"

#include <type_traits>

static_assert(sizeof(ct_point) == 16 && alignof(ct_point) == 8);
static_assert(offsetof(ct_point, timestamp) == 0 && offsetof(ct_point, value) == 8);
static_assert(sizeof(ct_series_handle) == 16 && alignof(ct_series_handle) == 8);
static_assert(offsetof(ct_series_handle, reserved) == 4 && offsetof(ct_series_handle, generation) == 8);
static_assert(CT_LOOKUP_EXACT == 0 && CT_LOOKUP_PREDECESSOR == 1 &&
              CT_LOOKUP_SUCCESSOR == 2 && CT_LOOKUP_NEAREST == 3);
static_assert(CT_OK == 0 && CT_INVALID_ARGUMENT == -2 && CT_STALE_SERIES == -8);
using named = int (*)(ct_handle *, const char *, size_t, int64_t, uint8_t, uint8_t,
                     uint64_t, ct_point *, uint8_t *);
using prepared = int (*)(ct_handle *, ct_series_handle, int64_t, uint8_t, uint8_t,
                        uint64_t, ct_point *, uint8_t *);
static_assert(std::is_same<decltype(&ct_lookup), named>::value);
static_assert(std::is_same<decltype(&ct_lookup_prepared), prepared>::value);

int main() {
    ct_point out{12, 3.0};
    uint8_t found = 99;
    if (ct_abi_version() != 2 || ct_lookup(nullptr, "s", 1, 0, CT_LOOKUP_EXACT,
        0, 0, &out, &found) != CT_INVALID_ARGUMENT || found != 0 ||
        out.timestamp != 12 || out.value != 3.0) return 1;
    ct_series_handle handle{};
    found = 99;
    return ct_lookup_prepared(nullptr, handle, 0, CT_LOOKUP_NEAREST,
        1, UINT64_MAX, &out, &found) != CT_INVALID_ARGUMENT || found != 0;
}
