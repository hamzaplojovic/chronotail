#ifndef CHRONOTAIL_H
#define CHRONOTAIL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void ct_handle;

enum {
    CT_OK = 0,
    CT_BUFFER_TOO_SMALL = 1,
    CT_ERROR = -1,
    CT_INVALID_ARGUMENT = -2,
    CT_WRONG_HANDLE = -3,
    CT_WRITER_BUSY = -4,
    CT_TIMESTAMP_ORDER = -5,
    CT_IO_ERROR = -6,
    CT_POISONED_WRITER = -7,
    CT_STALE_SERIES = -8,
    CT_PAGE_NOT_RAW = -9,
    CT_TIMESTAMP_NOT_FOUND = -10,
    CT_BORROWED_VIEW_UNAVAILABLE = -11
};

typedef struct {
    uint32_t index;
    uint32_t reserved;
    uint64_t generation;
} ct_series_handle;

typedef struct {
    uint64_t count;
    double minimum;
    double maximum;
    double sum;
    double first;
    double last;
} ct_aggregate_result;

typedef struct {
    ct_series_handle series;
    int64_t next_timestamp;
    int64_t end;
    uint8_t complete;
    uint8_t reserved[7];
} ct_range_cursor;

typedef struct {
    const int64_t *timestamps;
    const double *values;
    size_t count;
    int64_t timestamp_min;
    int64_t timestamp_max;
} ct_raw_page_view;

enum {
    CT_CODEC_RAW = 0,
    CT_CODEC_COMPRESSED = 1
};

enum {
    CT_DURABILITY_MEMORY = 0,
    CT_DURABILITY_DISK = 1
};

uint32_t ct_abi_version(void);
const char *ct_error_string(int code);

int ct_open_writer(
    const char *path,
    size_t path_len,
    uint8_t codec,
    ct_handle **out);

/* The complete batch is validated before mutation. On operational failure,
   the writer is poisoned so no partial batch can be checkpointed. */
int ct_append(
    ct_handle *writer,
    const char *series,
    size_t series_len,
    const int64_t *timestamps,
    const double *values,
    size_t count);

/* Declares a bound that keeps append allocation-free until the next checkpoint. */
int ct_prepare_append(
    ct_handle *writer,
    const char *series,
    size_t series_len,
    size_t maximum_points_before_checkpoint);

int ct_checkpoint(ct_handle *writer, uint8_t fsync);
int ct_checkpoint_with_durability(ct_handle *writer, uint8_t durability);
int ct_open_reader(const char *path, size_t path_len, ct_handle **out);
int ct_refresh(ct_handle *reader, uint8_t *changed);

/* On CT_BUFFER_TOO_SMALL, count contains the required capacity. */
int ct_range(
    ct_handle *reader,
    const char *series,
    size_t series_len,
    int64_t start,
    int64_t end,
    int64_t *timestamps,
    double *values,
    size_t capacity,
    size_t *count);

/* Prepared handles avoid repeated UTF-8 hashing. Refresh invalidates them. */
int ct_prepare_series(
    ct_handle *reader,
    const char *series,
    size_t series_len,
    ct_series_handle *out);

int ct_range_prepared(
    ct_handle *reader,
    ct_series_handle series,
    int64_t start,
    int64_t end,
    int64_t *timestamps,
    double *values,
    size_t capacity,
    size_t *count);

/* Uses persistent subtree summaries whenever the requested range permits it. */
int ct_aggregate(
    ct_handle *reader,
    const char *series,
    size_t series_len,
    int64_t start,
    int64_t end,
    ct_aggregate_result *out);

int ct_aggregate_prepared(
    ct_handle *reader,
    ct_series_handle series,
    int64_t start,
    int64_t end,
    ct_aggregate_result *out);

/* Cursors make bounded progress without a count-then-copy call. */
int ct_cursor_init(
    ct_handle *reader,
    const char *series,
    size_t series_len,
    int64_t start,
    int64_t end,
    ct_range_cursor *out);

int ct_cursor_next(
    ct_handle *reader,
    ct_range_cursor *cursor,
    int64_t *timestamps,
    double *values,
    size_t capacity,
    size_t *count);

/* The returned slices are valid until reader refresh or close. */
int ct_borrow_raw_page(
    ct_handle *reader,
    ct_series_handle series,
    int64_t timestamp,
    ct_raw_page_view *out);

int ct_close(ct_handle *handle);

#ifdef __cplusplus
}
#endif

#endif
