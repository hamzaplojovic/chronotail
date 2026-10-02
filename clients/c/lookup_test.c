#include "chronotail.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "lookup check failed at line %d: %s\n", __LINE__, #condition); \
    exit(1); } } while (0)

static const uint64_t value_bits[] = {
    UINT64_C(0), UINT64_C(0x8000000000000000), UINT64_C(1),
    UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
    UINT64_C(0x7ff8000000000123), UINT64_C(0xfff8000000000456),
    UINT64_C(0x3ff0000000000000), UINT64_C(0x7fefffffffffffff)
};

static double from_bits(uint64_t bits) {
    double value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static uint64_t bits_of(double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

/* Independent linear reference over the small fixture, with unsigned rank
   distance rather than signed subtraction or production traversal. */
static uint64_t distance(int64_t a, int64_t b) {
    uint64_t x = (uint64_t)a ^ (UINT64_C(1) << 63);
    uint64_t y = (uint64_t)b ^ (UINT64_C(1) << 63);
    return x >= y ? x - y : y - x;
}

static int reference(const int64_t *times, size_t count, int64_t target,
                     uint8_t mode, uint8_t has_limit, uint64_t limit) {
    int result = -1;
    uint64_t best = UINT64_MAX;
    for (size_t i = 0; i < count; ++i) {
        int64_t timestamp = times[i];
        if ((mode == CT_LOOKUP_EXACT && timestamp != target) ||
            (mode == CT_LOOKUP_PREDECESSOR && timestamp > target) ||
            (mode == CT_LOOKUP_SUCCESSOR && timestamp < target)) continue;
        uint64_t delta = distance(timestamp, target);
        if (result < 0 || delta < best) { result = (int)i; best = delta; }
    }
    return has_limit && best > limit ? -1 : result;
}

static void check_result(int status, uint8_t found, ct_point out, ct_point sentinel,
                         int expected, const int64_t *times, const double *values) {
    CHECK(status == CT_OK);
    CHECK(found == (expected >= 0));
    if (expected < 0) {
        CHECK(memcmp(&out, &sentinel, sizeof(out)) == 0);
    } else {
        CHECK(out.timestamp == times[expected]);
        CHECK(bits_of(out.value) == bits_of(values[expected]));
    }
}

static void query(ct_handle *reader, const char *name, ct_series_handle series,
                  const int64_t *times, const double *values, size_t count,
                  int64_t target, uint8_t mode, uint8_t has_limit, uint64_t limit) {
    ct_point sentinel = {12345, from_bits(UINT64_C(0x7ff800000000abcd))};
    ct_point out = sentinel;
    uint8_t found = 0xa5;
    int expected = reference(times, count, target, mode, has_limit, limit);
    int status = ct_lookup(reader, name, strlen(name), target, mode, has_limit,
                           limit, &out, &found);
    check_result(status, found, out, sentinel, expected, times, values);
    out = sentinel; found = 0xa5;
    status = ct_lookup_prepared(reader, series, target, mode, has_limit, limit, &out, &found);
    check_result(status, found, out, sentinel, expected, times, values);
}

static void target_cases(ct_handle *reader, const char *name, ct_series_handle series,
                         const int64_t *times, const double *values, size_t count, int64_t target) {
    for (uint8_t mode = 0; mode <= 3; ++mode) {
        uint64_t limits[] = {0, 1, UINT64_MAX, UINT64_MAX - 1, UINT64_C(1) << 63};
        query(reader, name, series, times, values, count, target, mode, 0, 0);
        query(reader, name, series, times, values, count, target, mode, 0, UINT64_MAX);
        for (size_t j = 0; j < sizeof(limits) / sizeof(limits[0]); ++j)
            query(reader, name, series, times, values, count, target, mode, 1, limits[j]);
        int expected = reference(times, count, target, mode, 0, 0);
        if (expected >= 0) {
            uint64_t delta = distance(times[expected], target);
            query(reader, name, series, times, values, count, target, mode, 1, delta);
            if (delta > 0) query(reader, name, series, times, values, count, target, mode, 1, delta - 1);
            if (delta < UINT64_MAX) query(reader, name, series, times, values, count, target, mode, 1, delta + 1);
        }
    }
}

static void error_result(int status, int expected, uint8_t found, ct_point out, ct_point sentinel) {
    CHECK(status == expected);
    CHECK(found == 0);
    CHECK(memcmp(&out, &sentinel, sizeof(out)) == 0);
}

static void invalid_cases(ct_handle *reader, ct_handle *writer, ct_series_handle series) {
    ct_point sentinel = {98765, from_bits(UINT64_C(0xfff800000000abcd))};
    ct_point out;
    uint8_t found;
    int status;
#define NAMED_ERROR(handle, name, length, mode, tag, expected) do { \
    out = sentinel; found = 0xa5; \
    status = ct_lookup(handle, name, length, 0, mode, tag, 0, &out, &found); \
    error_result(status, expected, found, out, sentinel); } while (0)
#define PREPARED_ERROR(handle, prepared, mode, tag, expected) do { \
    out = sentinel; found = 0xa5; \
    status = ct_lookup_prepared(handle, prepared, 0, mode, tag, 0, &out, &found); \
    error_result(status, expected, found, out, sentinel); } while (0)
    for (unsigned byte = 4; byte <= UINT8_MAX; ++byte) {
        NAMED_ERROR(reader, "signal", 6, (uint8_t)byte, 0, CT_INVALID_ARGUMENT);
        PREPARED_ERROR(reader, series, (uint8_t)byte, 0, CT_INVALID_ARGUMENT);
    }
    for (unsigned byte = 2; byte <= UINT8_MAX; ++byte) {
        NAMED_ERROR(reader, "signal", 6, CT_LOOKUP_EXACT, (uint8_t)byte, CT_INVALID_ARGUMENT);
        PREPARED_ERROR(reader, series, CT_LOOKUP_EXACT, (uint8_t)byte, CT_INVALID_ARGUMENT);
    }
    NAMED_ERROR(NULL, "signal", 6, 0, 0, CT_INVALID_ARGUMENT);
    PREPARED_ERROR(NULL, series, 0, 0, CT_INVALID_ARGUMENT);
    NAMED_ERROR(reader, NULL, 6, 0, 0, CT_INVALID_ARGUMENT);
    NAMED_ERROR(reader, "signal", 0, 0, 0, CT_INVALID_ARGUMENT);
    NAMED_ERROR(reader, "unknown", 7, CT_LOOKUP_NEAREST, 1, CT_INVALID_ARGUMENT);
    NAMED_ERROR(writer, "signal", 6, 0, 0, CT_WRONG_HANDLE);
    PREPARED_ERROR(writer, series, 0, 0, CT_WRONG_HANDLE);
    NAMED_ERROR(writer, "signal", 6, 255, 0, CT_INVALID_ARGUMENT);
    ct_series_handle invalid = series;
    invalid.reserved = 1;
    PREPARED_ERROR(writer, invalid, 0, 0, CT_INVALID_ARGUMENT);
    invalid = series; invalid.index = UINT32_MAX;
    PREPARED_ERROR(reader, invalid, CT_LOOKUP_NEAREST, 1, CT_STALE_SERIES);
    invalid = series; --invalid.generation;
    PREPARED_ERROR(reader, invalid, CT_LOOKUP_EXACT, 1, CT_STALE_SERIES);
    out = sentinel; found = 0xa5;
    CHECK(ct_lookup(reader, "signal", 6, 0, 0, 0, 0, NULL, &found) == CT_INVALID_ARGUMENT);
    CHECK(found == 0);
    CHECK(ct_lookup(reader, "signal", 6, 0, 0, 0, 0, &out, NULL) == CT_INVALID_ARGUMENT);
    CHECK(memcmp(&out, &sentinel, sizeof(out)) == 0);
    found = 0xa5;
    CHECK(ct_lookup_prepared(reader, series, 0, 0, 0, 0, NULL, &found) == CT_INVALID_ARGUMENT);
    CHECK(found == 0);
    CHECK(ct_lookup_prepared(reader, series, 0, 0, 0, 0, &out, NULL) == CT_INVALID_ARGUMENT);
    CHECK(memcmp(&out, &sentinel, sizeof(out)) == 0);
#undef NAMED_ERROR
#undef PREPARED_ERROR
}

static void codec_cases(uint8_t codec) {
    const char *path = codec == CT_CODEC_RAW ? "lookup-raw.ctdb" : "lookup-compressed.ctdb";
    int64_t times[] = {INT64_MIN, INT64_MIN + 1, -31, -10, 0, 10, 47, INT64_MAX - 1, INT64_MAX};
    double values[sizeof(times) / sizeof(times[0])];
    size_t count = sizeof(times) / sizeof(times[0]);
    for (size_t i = 0; i < count; ++i) values[i] = from_bits(value_bits[i]);
    ct_handle *writer = NULL, *reader = NULL;
    CHECK(ct_open_writer(path, strlen(path), codec, &writer) == CT_OK);
    CHECK(ct_append(writer, "signal", 6, times, values, count) == CT_OK);
    CHECK(ct_append(writer, "single", 6, times, values, 1) == CT_OK);
    /* 44 committed small pages exceed the format-v7 leaf's 41 entries in both
       encodings, forcing real page and index-child boundaries. */
    enum { MANY = 132 };
    int64_t many[MANY]; double many_values[MANY];
    for (size_t i = 0; i < MANY; ++i) { many[i] = (int64_t)i * 11 - 500; many_values[i] = (double)i; }
    for (size_t offset = 0; offset < MANY; offset += 3) {
        CHECK(ct_append(writer, "pages", 5, many + offset, many_values + offset, 3) == CT_OK);
        CHECK(ct_checkpoint(writer, 0) == CT_OK);
    }
    CHECK(ct_open_reader(path, strlen(path), &reader) == CT_OK);
    ct_series_handle prepared = {0}, single = {0}, pages = {0};
    CHECK(ct_prepare_series(reader, "signal", 6, &prepared) == CT_OK);
    CHECK(ct_prepare_series(reader, "single", 6, &single) == CT_OK);
    CHECK(ct_prepare_series(reader, "pages", 5, &pages) == CT_OK);
    int64_t targets[] = {INT64_MIN, INT64_MIN + 2, -32, -31, -20, -11, -10, -5, 0, 5, 11, 46, 48, INT64_MAX};
    for (size_t i = 0; i < sizeof(targets) / sizeof(targets[0]); ++i)
        target_cases(reader, "signal", prepared, times, values, count, targets[i]);
    target_cases(reader, "single", single, times, values, 1, INT64_MAX);
    for (size_t i = 0; i < MANY; i += 3) {
        target_cases(reader, "pages", pages, many, many_values, MANY, many[i] - 1);
        target_cases(reader, "pages", pages, many, many_values, MANY, many[i]);
    }
    invalid_cases(reader, writer, prepared);
    uint8_t changed = 99;
    CHECK(ct_refresh(reader, &changed) == CT_OK && changed == 0);
    target_cases(reader, "pages", pages, many, many_values, MANY, many[0]);
    ct_point copied; uint8_t found = 0;
    CHECK(ct_lookup_prepared(reader, prepared, INT64_MIN, CT_LOOKUP_EXACT, 0, 0, &copied, &found) == CT_OK && found == 1);
    int64_t next = many[MANY - 1] + 11; double next_value = 0.0;
    CHECK(ct_append(writer, "pages", 5, &next, &next_value, 1) == CT_OK);
    CHECK(ct_checkpoint(writer, 0) == CT_OK);
    CHECK(ct_refresh(reader, &changed) == CT_OK && changed == 1);
    ct_point sentinel = {123, 4.0}, out = sentinel; found = 99;
    int status = ct_lookup_prepared(reader, pages, next, CT_LOOKUP_EXACT, 1, 0, &out, &found);
    error_result(status, CT_STALE_SERIES, found, out, sentinel);
    CHECK(ct_lookup(reader, "pages", 5, next, CT_LOOKUP_EXACT, 1, 0, &out, &found) == CT_OK && found == 1);
    CHECK(out.timestamp == next && bits_of(out.value) == 0);
    CHECK(ct_close(reader) == CT_OK); reader = NULL;
    CHECK(copied.timestamp == INT64_MIN && bits_of(copied.value) == value_bits[0]);
    out = sentinel; found = 99;
    status = ct_lookup(reader, "signal", 6, 0, 0, 0, 0, &out, &found);
    error_result(status, CT_INVALID_ARGUMENT, found, out, sentinel);
    CHECK(ct_close(writer) == CT_OK);
}

static void checksum_error_case(void) {
    const char *path = "lookup-checksum.ctdb";
    ct_handle *writer = NULL, *reader = NULL;
    int64_t timestamp = 10; double value = -0.0;
    CHECK(ct_open_writer(path, strlen(path), CT_CODEC_RAW, &writer) == CT_OK);
    CHECK(ct_append(writer, "signal", 6, &timestamp, &value, 1) == CT_OK);
    CHECK(ct_close(writer) == CT_OK);
    /* The first v7 data page starts after the 64-KiB control region. Corrupt
       its payload before opening any mapped reader, retaining valid roots,
       manifest and selected index edge. No mapped bytes are mutated. */
    FILE *file = fopen(path, "r+b"); CHECK(file != NULL);
    CHECK(fseek(file, 64 * 1024 + 128, SEEK_SET) == 0);
    int byte = fgetc(file); CHECK(byte != EOF);
    CHECK(fseek(file, -1, SEEK_CUR) == 0);
    CHECK(fputc(byte ^ 0x80, file) != EOF);
    CHECK(fclose(file) == 0);
    CHECK(ct_open_reader(path, strlen(path), &reader) == CT_OK);
    ct_series_handle series = {0};
    CHECK(ct_prepare_series(reader, "signal", 6, &series) == CT_OK);
    ct_point sentinel = {123, 4.0}, out = sentinel; uint8_t found = 99;
    int status = ct_lookup(reader, "signal", 6, 10, CT_LOOKUP_EXACT, 1, 0, &out, &found);
    error_result(status, CT_IO_ERROR, found, out, sentinel);
    out = sentinel; found = 99;
    status = ct_lookup_prepared(reader, series, 10, CT_LOOKUP_NEAREST, 0, 0, &out, &found);
    error_result(status, CT_IO_ERROR, found, out, sentinel);
    CHECK(ct_close(reader) == CT_OK);
}

int main(void) {
    CHECK(ct_abi_version() == 2);
    codec_cases(CT_CODEC_RAW);
    codec_cases(CT_CODEC_COMPRESSED);
    checksum_error_case();
    puts("C temporal lookup parity passed");
    return 0;
}
