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
    CT_POISONED_WRITER = -7
};

enum {
    CT_CODEC_RAW = 0,
    CT_CODEC_COMPRESSED = 1
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

int ct_checkpoint(ct_handle *writer, uint8_t fsync);
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

int ct_close(ct_handle *handle);

#ifdef __cplusplus
}
#endif

#endif
