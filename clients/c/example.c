#include "chronotail.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(int status, const char *operation) {
    if (status == CT_OK) return;
    fprintf(stderr, "%s: %s (%d)\n", operation, ct_error_string(status), status);
    exit(1);
}

int main(void) {
    const char *path = "c-client.ctdb";
    const char *series = "cpu";
    int64_t timestamps[] = {1000, 1001, 1002};
    double values[] = {42.5, 43.5, 44.5};
    ct_handle *writer = NULL;

    check(ct_open_writer(path, strlen(path), CT_CODEC_COMPRESSED, &writer),
          "open writer");
    check(ct_prepare_append(writer, series, strlen(series), 3), "prepare");
    check(ct_append(writer, series, strlen(series), timestamps, values, 3),
          "append");
    check(ct_checkpoint_with_durability(writer, CT_DURABILITY_DISK),
          "checkpoint");
    check(ct_close(writer), "close writer");

    ct_handle *reader = NULL;
    int64_t read_timestamps[3] = {0};
    double read_values[3] = {0};
    size_t count = 0;
    check(ct_open_reader(path, strlen(path), &reader), "open reader");
    check(ct_range(reader, series, strlen(series), 0, INT64_MAX,
                   read_timestamps, read_values, 3, &count),
          "range");
    if (count != 3 || read_timestamps[0] != 1000 || read_values[2] != 44.5) {
        fprintf(stderr, "unexpected C client result\n");
        return 1;
    }
    check(ct_close(reader), "close reader");
    return 0;
}
