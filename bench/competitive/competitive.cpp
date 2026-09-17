#include "chronotail.h"
#include "nanots.h"
#include "sqlite3.h"

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;

static std::atomic<uint64_t> consumed{0};

struct Point {
  int64_t timestamp;
  double value;
};
static_assert(sizeof(Point) == 16, "logical point must be 16 bytes");

struct Metrics {
  double seconds = 0;
  uint64_t operations = 0;
  uint64_t points = 0;
  uint64_t bytes = 0;
  std::vector<uint64_t> latency;
  std::vector<uint64_t> sync_latency;
  std::string latency_scope = "operation";
};

enum class ValuePattern { constant, smooth, spiky, random };

static void fail(const std::string &message) {
  throw std::runtime_error(message);
}

static void ct_ok(int code, const char *where) {
  if (code != CT_OK) fail(std::string(where) + ": " + ct_error_string(code));
}

static void sql_ok(int code, sqlite3 *database, const char *where) {
  if (code != SQLITE_OK && code != SQLITE_DONE && code != SQLITE_ROW) {
    fail(std::string(where) + ": " +
         (database ? sqlite3_errmsg(database) : "sqlite error"));
  }
}

static uint64_t ns(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
      .count();
}

static uint64_t splitmix(uint64_t &state) {
  uint64_t value = (state += 0x9e3779b97f4a7c15ULL);
  value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
  value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
  return value ^ (value >> 31);
}

struct Sampler {
  uint64_t state = 0x123456789abcdef0ULL;
  uint64_t next = 317;

  bool take(uint64_t index) {
    if (index != next) return false;
    next += 512 + (splitmix(state) & 1023);
    return true;
  }
};

static ValuePattern parse_pattern(const std::string &name) {
  if (name == "constant") return ValuePattern::constant;
  if (name == "smooth") return ValuePattern::smooth;
  if (name == "spiky") return ValuePattern::spiky;
  if (name == "random") return ValuePattern::random;
  fail("unknown value pattern: " + name);
  return ValuePattern::smooth;
}

static double value_for(uint64_t index, ValuePattern pattern, uint64_t &state) {
  if (pattern == ValuePattern::constant) return 42.0;
  if (pattern == ValuePattern::smooth) {
    return 20.0 + static_cast<double>(index) * 0.000001 +
           std::sin(static_cast<double>(index) * 0.0001);
  }
  if (pattern == ValuePattern::spiky) {
    return index % 1024 == 0
               ? 1000.0 + static_cast<double>(index % 17)
               : 20.0 + static_cast<double>(index) * 0.000001;
  }
  uint64_t bits = (splitmix(state) >> 12) | 0x3ff0000000000000ULL;
  double value;
  std::memcpy(&value, &bits, sizeof(value));
  return value - 1.0;
}

static uint64_t percentile(std::vector<uint64_t> values, double quantile) {
  if (values.empty()) return 0;
  std::sort(values.begin(), values.end());
  const size_t index = std::min(
      values.size() - 1,
      static_cast<size_t>(quantile * static_cast<double>(values.size() - 1)));
  return values[index];
}

static uint64_t files_size(const std::string &path) {
  uint64_t bytes = 0;
  const fs::path file(path);
  const fs::path directory = file.parent_path().empty() ? "." : file.parent_path();
  const std::string base = file.filename().string();
  for (const auto &entry : fs::directory_iterator(directory)) {
    if (entry.is_regular_file() &&
        entry.path().filename().string().rfind(base, 0) == 0) {
      bytes += entry.file_size();
    }
  }
  return bytes;
}

static void remove_database(const std::string &path) {
  const fs::path file(path);
  const fs::path directory = file.parent_path().empty() ? "." : file.parent_path();
  const std::string base = file.filename().string();
  if (!fs::exists(directory)) fs::create_directories(directory);
  for (const auto &entry : fs::directory_iterator(directory)) {
    if (entry.path().filename().string().rfind(base, 0) == 0) {
      fs::remove(entry.path());
    }
  }
}

struct Sqlite {
  sqlite3 *database = nullptr;
  sqlite3_stmt *insert = nullptr;

  Sqlite(const std::string &path, bool create, bool durable = true) {
    const int flags = SQLITE_OPEN_READWRITE |
                      (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_NOMUTEX;
    sql_ok(sqlite3_open_v2(path.c_str(), &database, flags, nullptr), database,
           "sqlite open");
    sqlite3_busy_timeout(database, 30'000);
    if (create) {
      execute("PRAGMA journal_mode=WAL");
      execute(durable ? "PRAGMA synchronous=FULL"
                      : "PRAGMA synchronous=OFF");
    }
    execute("PRAGMA temp_store=MEMORY");
    execute("PRAGMA cache_size=-65536");
    execute("PRAGMA mmap_size=1073741824");
    if (create) {
      execute("CREATE TABLE points (series_id INTEGER NOT NULL, "
              "ts INTEGER NOT NULL, value REAL NOT NULL, "
              "PRIMARY KEY(series_id, ts))");
    }
  }

  ~Sqlite() {
    if (insert) sqlite3_finalize(insert);
    if (database) sqlite3_close(database);
  }

  void execute(const char *sql) {
    char *error = nullptr;
    const int code = sqlite3_exec(database, sql, nullptr, nullptr, &error);
    if (code == SQLITE_OK) return;
    const std::string message = error ? error : "sqlite error";
    sqlite3_free(error);
    fail(message);
  }

  void prepare_insert() {
    sql_ok(sqlite3_prepare_v2(database, "INSERT INTO points VALUES(?,?,?)", -1,
                              &insert, nullptr),
           database, "prepare insert");
  }

  void add(int series, int64_t timestamp, double value) {
    sqlite3_bind_int(insert, 1, series);
    sqlite3_bind_int64(insert, 2, timestamp);
    sqlite3_bind_double(insert, 3, value);
    sql_ok(sqlite3_step(insert), database, "insert");
    sqlite3_reset(insert);
    sqlite3_clear_bindings(insert);
  }
};

static uint32_t nano_block(uint64_t logical_points) {
  const uint64_t bytes = 16 + logical_points * 80;
  if (bytes > UINT32_MAX) fail("NanoTS block exceeds uint32 size");
  return static_cast<uint32_t>(bytes);
}

static Metrics append_chronotail(const std::string &path, uint64_t count,
                                 int series_count, uint64_t boundary,
                                 bool compressed, ValuePattern pattern,
                                 size_t batch_size) {
  remove_database(path);
  ct_handle *writer = nullptr;
  ct_ok(ct_open_writer(path.data(), path.size(),
                       compressed ? CT_CODEC_COMPRESSED : CT_CODEC_RAW,
                       &writer),
        "ct_open_writer");
  std::vector<std::string> names;
  for (int series = 0; series < series_count; ++series) {
    names.push_back("series-" + std::to_string(series));
  }

  Metrics metrics;
  metrics.operations = count;
  metrics.points = count;
  uint64_t random_state = 1;
  Sampler sampler;
  if (batch_size > 1) {
    if (series_count != 1 || boundary != 0) {
      fail("batch benchmark requires one series and no sync boundary");
    }
    ct_ok(ct_prepare_append(writer, names[0].data(), names[0].size(), count),
          "ct_prepare_append");
    metrics.latency_scope = "batch";
  }

  const auto begin = Clock::now();
  if (batch_size == 1) {
    for (uint64_t index = 0; index < count; ++index) {
      const int series = static_cast<int>(index % series_count);
      const int64_t timestamp = static_cast<int64_t>(index / series_count);
      const double value = value_for(index, pattern, random_state);
      const bool sampled = sampler.take(index);
      Clock::time_point sample_start;
      if (sampled) sample_start = Clock::now();
      ct_ok(ct_append(writer, names[series].data(), names[series].size(),
                      &timestamp, &value, 1),
            "ct_append");
      if (sampled) metrics.latency.push_back(ns(sample_start, Clock::now()));
      if (boundary && (index + 1) % boundary == 0) {
        const auto sync_start = Clock::now();
        ct_ok(ct_checkpoint(writer, 1), "ct_checkpoint");
        metrics.sync_latency.push_back(ns(sync_start, Clock::now()));
      }
    }
  } else {
    std::vector<int64_t> timestamps(batch_size);
    std::vector<double> values(batch_size);
    for (uint64_t offset = 0; offset < count;) {
      const size_t batch = static_cast<size_t>(
          std::min<uint64_t>(batch_size, count - offset));
      for (size_t index = 0; index < batch; ++index) {
        timestamps[index] = static_cast<int64_t>(offset + index);
        values[index] = value_for(offset + index, pattern, random_state);
      }
      const auto batch_start = Clock::now();
      ct_ok(ct_append(writer, names[0].data(), names[0].size(),
                      timestamps.data(), values.data(), batch),
            "ct_append batch");
      metrics.latency.push_back(ns(batch_start, Clock::now()));
      offset += batch;
    }
  }
  const auto sync_start = Clock::now();
  ct_ok(ct_checkpoint(writer, boundary ? 1 : 0), "ct final checkpoint");
  metrics.sync_latency.push_back(ns(sync_start, Clock::now()));
  ct_ok(ct_close(writer), "ct_close");
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  metrics.bytes = files_size(path);
  return metrics;
}

static Metrics append_nanots(const std::string &path, uint64_t count,
                             int series_count, uint64_t boundary,
                             ValuePattern pattern) {
  remove_database(path);
  const uint64_t window =
      boundary ? std::max<uint64_t>(1, boundary / series_count)
               : (count + series_count - 1) / series_count;
  const uint64_t per_series = (count + series_count - 1) / series_count;
  const uint32_t blocks = static_cast<uint32_t>(
      series_count * ((per_series + window - 1) / window));
  nanots_writer::allocate(path, nano_block(window), blocks);

  Metrics metrics;
  metrics.operations = count;
  metrics.points = count;
  uint64_t random_state = 1;
  Sampler sampler;
  const auto begin = Clock::now();
  {
    nanots_writer writer(path);
    std::vector<write_context> contexts;
    for (int series = 0; series < series_count; ++series) {
      contexts.push_back(writer.create_write_context(
          "series-" + std::to_string(series), "benchmark"));
    }
    for (uint64_t index = 0; index < count; ++index) {
      const int series = static_cast<int>(index % series_count);
      Point point{static_cast<int64_t>(index / series_count),
                  value_for(index, pattern, random_state)};
      const bool sampled = sampler.take(index);
      Clock::time_point sample_start;
      if (sampled) sample_start = Clock::now();
      writer.write(contexts[series], reinterpret_cast<uint8_t *>(&point),
                   sizeof(point), 0, point.timestamp);
      if (sampled) metrics.latency.push_back(ns(sample_start, Clock::now()));
    }
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  metrics.bytes = files_size(path);
  return metrics;
}

static Metrics append_sqlite(const std::string &path, uint64_t count,
                             int series_count, uint64_t boundary,
                             ValuePattern pattern) {
  remove_database(path);
  Metrics metrics;
  metrics.operations = count;
  metrics.points = count;
  uint64_t random_state = 1;
  Sampler sampler;
  const auto begin = Clock::now();
  {
    Sqlite database(path, true, boundary != 0);
    database.prepare_insert();
    database.execute("BEGIN IMMEDIATE");
    for (uint64_t index = 0; index < count; ++index) {
      const int series = static_cast<int>(index % series_count);
      const int64_t timestamp = static_cast<int64_t>(index / series_count);
      const double value = value_for(index, pattern, random_state);
      const bool sampled = sampler.take(index);
      Clock::time_point sample_start;
      if (sampled) sample_start = Clock::now();
      database.add(series, timestamp, value);
      if (sampled) metrics.latency.push_back(ns(sample_start, Clock::now()));
      if (boundary && (index + 1) % boundary == 0) {
        const auto sync_start = Clock::now();
        database.execute("COMMIT");
        metrics.sync_latency.push_back(ns(sync_start, Clock::now()));
        database.execute("BEGIN IMMEDIATE");
      }
    }
    const auto sync_start = Clock::now();
    database.execute("COMMIT");
    metrics.sync_latency.push_back(ns(sync_start, Clock::now()));
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)");
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  metrics.bytes = files_size(path);
  return metrics;
}

static Metrics build_database(const std::string &engine, const std::string &path,
                              uint64_t count, int series_count, bool compressed,
                              ValuePattern pattern, uint64_t boundary = 0,
                              size_t batch_size = 1) {
  if (engine == "chronotail") {
    return append_chronotail(path, count, series_count, boundary, compressed,
                             pattern, batch_size);
  }
  if (engine == "nanots") {
    return append_nanots(path, count, series_count, boundary, pattern);
  }
  if (engine == "sqlite") {
    return append_sqlite(path, count, series_count, boundary, pattern);
  }
  fail("unknown engine: " + engine);
  return {};
}

static uint64_t verify_database(const std::string &engine,
                                const std::string &path, uint64_t expected,
                                int series_count) {
  uint64_t count = 0;
  uint64_t hash = 0;
  if (engine == "chronotail") {
    ct_handle *reader = nullptr;
    ct_ok(ct_open_reader(path.data(), path.size(), &reader), "verify open");
    for (int series = 0; series < series_count; ++series) {
      const std::string name = "series-" + std::to_string(series);
      const size_t capacity = (expected + series_count - 1) / series_count;
      size_t result_count = capacity;
      std::vector<int64_t> timestamps(capacity);
      std::vector<double> values(capacity);
      ct_ok(ct_range(reader, name.data(), name.size(), INT64_MIN, INT64_MAX,
                     timestamps.data(), values.data(), capacity, &result_count),
            "verify range");
      count += result_count;
      for (size_t index = 0; index < result_count; ++index) {
        hash ^= static_cast<uint64_t>(timestamps[index]) +
                std::bit_cast<uint64_t>(values[index]);
      }
    }
    ct_ok(ct_close(reader), "verify close");
  } else if (engine == "nanots") {
    for (int series = 0; series < series_count; ++series) {
      nanots_iterator iterator(path, "series-" + std::to_string(series));
      iterator.reset();
      while (iterator.valid()) {
        const auto &frame = *iterator;
        if (frame.size != sizeof(Point)) fail("NanoTS payload size");
        Point point;
        std::memcpy(&point, frame.data, sizeof(point));
        if (point.timestamp != frame.timestamp) {
          fail("NanoTS timestamp mismatch");
        }
        hash ^= static_cast<uint64_t>(point.timestamp) +
                std::bit_cast<uint64_t>(point.value);
        ++count;
        ++iterator;
      }
    }
  } else {
    Sqlite database(path, false);
    sqlite3_stmt *query = nullptr;
    sql_ok(sqlite3_prepare_v2(
               database.database,
               "SELECT ts,value FROM points ORDER BY series_id,ts", -1, &query,
               nullptr),
           database.database, "verify prepare");
    while (sqlite3_step(query) == SQLITE_ROW) {
      const int64_t timestamp = sqlite3_column_int64(query, 0);
      const double value = sqlite3_column_double(query, 1);
      hash ^= static_cast<uint64_t>(timestamp) +
              std::bit_cast<uint64_t>(value);
      ++count;
    }
    sqlite3_finalize(query);
  }
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  if (count != expected) {
    fail("verification count mismatch: " + std::to_string(count) + " != " +
         std::to_string(expected));
  }
  return hash;
}

static Metrics query_chronotail(const std::string &path, uint64_t query_count,
                                int width, uint64_t dataset, uint64_t seed) {
  ct_handle *reader = nullptr;
  ct_ok(ct_open_reader(path.data(), path.size(), &reader), "query open");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  std::vector<int64_t> timestamps(width);
  std::vector<double> values(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t query_index = 0; query_index < query_count; ++query_index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    size_t result_count = static_cast<size_t>(width);
    const auto query_start = Clock::now();
    ct_ok(ct_range(reader, "series-0", 8, start, start + width - 1,
                   timestamps.data(), values.data(), width, &result_count),
          "query range");
    const auto query_end = Clock::now();
    if (result_count != static_cast<size_t>(width)) fail("Chronotail short query");
    for (size_t index = 0; index < result_count; ++index) {
      hash ^= static_cast<uint64_t>(timestamps[index]) +
              std::bit_cast<uint64_t>(values[index]);
    }
    metrics.latency.push_back(ns(query_start, query_end));
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  ct_ok(ct_close(reader), "query close");
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics query_nanots(const std::string &path, uint64_t query_count,
                            int width, uint64_t dataset, uint64_t seed) {
  nanots_iterator iterator(path, "series-0");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t query_index = 0; query_index < query_count; ++query_index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    const auto query_start = Clock::now();
    if (!iterator.find(start)) fail("NanoTS find");
    for (int index = 0; index < width; ++index) {
      if (!iterator.valid()) fail("NanoTS short query");
      Point point;
      std::memcpy(&point, iterator->data, sizeof(point));
      hash ^= static_cast<uint64_t>(point.timestamp) +
              std::bit_cast<uint64_t>(point.value);
      if (index + 1 < width) ++iterator;
    }
    metrics.latency.push_back(ns(query_start, Clock::now()));
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics query_sqlite(const std::string &path, uint64_t query_count,
                            int width, uint64_t dataset, uint64_t seed) {
  Sqlite database(path, false);
  sqlite3_stmt *query = nullptr;
  sql_ok(sqlite3_prepare_v2(
             database.database,
             "SELECT ts,value FROM points WHERE series_id=0 AND ts>=? "
             "ORDER BY ts LIMIT ?",
             -1, &query, nullptr),
         database.database, "query prepare");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t query_index = 0; query_index < query_count; ++query_index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    sqlite3_bind_int64(query, 1, start);
    sqlite3_bind_int(query, 2, width);
    const auto query_start = Clock::now();
    int result_count = 0;
    while (sqlite3_step(query) == SQLITE_ROW) {
      hash ^= static_cast<uint64_t>(sqlite3_column_int64(query, 0)) +
              std::bit_cast<uint64_t>(sqlite3_column_double(query, 1));
      ++result_count;
    }
    metrics.latency.push_back(ns(query_start, Clock::now()));
    if (result_count != width) fail("SQLite short query");
    sqlite3_reset(query);
    sqlite3_clear_bindings(query);
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  sqlite3_finalize(query);
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics query_database(const std::string &engine, const std::string &path,
                              uint64_t query_count, int width, uint64_t dataset,
                              uint64_t seed) {
  if (engine == "chronotail") {
    return query_chronotail(path, query_count, width, dataset, seed);
  }
  if (engine == "nanots") {
    return query_nanots(path, query_count, width, dataset, seed);
  }
  return query_sqlite(path, query_count, width, dataset, seed);
}

struct AggregateValue {
  uint64_t count = 0;
  double minimum = NAN;
  double maximum = NAN;
  double sum = 0;
  double first = NAN;
  double last = NAN;
};

static uint64_t aggregate_hash(const AggregateValue &value) {
  return value.count ^ std::bit_cast<uint64_t>(value.minimum) ^
         std::bit_cast<uint64_t>(value.maximum) ^
         std::bit_cast<uint64_t>(value.sum) ^
         std::bit_cast<uint64_t>(value.first) ^
         std::bit_cast<uint64_t>(value.last);
}

static Metrics aggregate_chronotail(const std::string &path,
                                    uint64_t query_count, int width,
                                    uint64_t dataset, uint64_t seed) {
  ct_handle *reader = nullptr;
  ct_ok(ct_open_reader(path.data(), path.size(), &reader), "aggregate open");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t index = 0; index < query_count; ++index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    ct_aggregate_result result{};
    const auto query_start = Clock::now();
    ct_ok(ct_aggregate(reader, "series-0", 8, start, start + width - 1,
                       &result),
          "ct_aggregate");
    const AggregateValue value{result.count, result.minimum, result.maximum,
                               result.sum, result.first, result.last};
    hash ^= aggregate_hash(value);
    metrics.latency.push_back(ns(query_start, Clock::now()));
    if (result.count != static_cast<uint64_t>(width)) {
      fail("Chronotail short aggregate");
    }
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  ct_ok(ct_close(reader), "aggregate close");
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics aggregate_nanots(const std::string &path, uint64_t query_count,
                                int width, uint64_t dataset, uint64_t seed) {
  nanots_iterator iterator(path, "series-0");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t query_index = 0; query_index < query_count; ++query_index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    const auto query_start = Clock::now();
    if (!iterator.find(start)) fail("NanoTS aggregate find");
    AggregateValue value;
    for (int index = 0; index < width; ++index) {
      if (!iterator.valid()) fail("NanoTS short aggregate");
      Point point;
      std::memcpy(&point, iterator->data, sizeof(point));
      if (index == 0) {
        value.minimum = point.value;
        value.maximum = point.value;
        value.first = point.value;
      }
      value.minimum = std::min(value.minimum, point.value);
      value.maximum = std::max(value.maximum, point.value);
      value.sum += point.value;
      value.last = point.value;
      ++value.count;
      if (index + 1 < width) ++iterator;
    }
    hash ^= aggregate_hash(value);
    metrics.latency.push_back(ns(query_start, Clock::now()));
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics aggregate_sqlite(const std::string &path, uint64_t query_count,
                                int width, uint64_t dataset, uint64_t seed) {
  Sqlite database(path, false);
  sqlite3_stmt *query = nullptr;
  const char *sql =
      "SELECT COUNT(*),MIN(value),MAX(value),SUM(value),"
      "(SELECT value FROM points WHERE series_id=0 AND ts>=?1 AND ts<=?2 "
      "ORDER BY ts ASC LIMIT 1),"
      "(SELECT value FROM points WHERE series_id=0 AND ts>=?1 AND ts<=?2 "
      "ORDER BY ts DESC LIMIT 1) "
      "FROM points WHERE series_id=0 AND ts>=?1 AND ts<=?2";
  sql_ok(sqlite3_prepare_v2(database.database, sql, -1, &query, nullptr),
         database.database, "aggregate prepare");
  Metrics metrics;
  metrics.operations = query_count;
  metrics.points = query_count * static_cast<uint64_t>(width);
  uint64_t random_state = seed;
  uint64_t hash = 0;
  const auto begin = Clock::now();
  for (uint64_t query_index = 0; query_index < query_count; ++query_index) {
    const int64_t start = splitmix(random_state) % (dataset - width + 1);
    sqlite3_bind_int64(query, 1, start);
    sqlite3_bind_int64(query, 2, start + width - 1);
    const auto query_start = Clock::now();
    if (sqlite3_step(query) != SQLITE_ROW) fail("SQLite aggregate row");
    const AggregateValue value{
        static_cast<uint64_t>(sqlite3_column_int64(query, 0)),
        sqlite3_column_double(query, 1), sqlite3_column_double(query, 2),
        sqlite3_column_double(query, 3), sqlite3_column_double(query, 4),
        sqlite3_column_double(query, 5)};
    hash ^= aggregate_hash(value);
    metrics.latency.push_back(ns(query_start, Clock::now()));
    if (value.count != static_cast<uint64_t>(width)) {
      fail("SQLite short aggregate");
    }
    sqlite3_reset(query);
    sqlite3_clear_bindings(query);
  }
  metrics.seconds = std::chrono::duration<double>(Clock::now() - begin).count();
  sqlite3_finalize(query);
  consumed.fetch_xor(hash, std::memory_order_relaxed);
  return metrics;
}

static Metrics aggregate_database(const std::string &engine,
                                  const std::string &path,
                                  uint64_t query_count, int width,
                                  uint64_t dataset, uint64_t seed) {
  if (engine == "chronotail") {
    return aggregate_chronotail(path, query_count, width, dataset, seed);
  }
  if (engine == "nanots") {
    return aggregate_nanots(path, query_count, width, dataset, seed);
  }
  return aggregate_sqlite(path, query_count, width, dataset, seed);
}

struct ConcurrentMetrics {
  Metrics writer;
  Metrics reader;
};

static ConcurrentMetrics concurrent_chronotail(const std::string &path,
                                                int reader_count, int seconds,
                                                uint64_t base) {
  build_database("chronotail", path, base, 1, false, ValuePattern::smooth,
                 65'536);
  std::atomic<bool> go = false;
  std::atomic<bool> stop = false;
  std::atomic<uint64_t> writes = 0;
  std::atomic<uint64_t> queries = 0;
  std::mutex latency_mutex;
  std::vector<uint64_t> latency;
  std::vector<std::thread> readers;
  for (int reader_index = 0; reader_index < reader_count; ++reader_index) {
    readers.emplace_back([&, reader_index] {
      ct_handle *reader = nullptr;
      ct_ok(ct_open_reader(path.data(), path.size(), &reader), "reader open");
      uint64_t random_state = reader_index + 7;
      uint64_t hash = 0;
      std::vector<int64_t> timestamps(100);
      std::vector<double> values(100);
      while (!go.load()) {}
      while (!stop.load()) {
        const int64_t start = splitmix(random_state) % (base - 99);
        size_t result_count = 100;
        const auto query_start = Clock::now();
        ct_ok(ct_range(reader, "series-0", 8, start, start + 99,
                       timestamps.data(), values.data(), 100, &result_count),
              "concurrent range");
        const auto query_end = Clock::now();
        hash ^= static_cast<uint64_t>(timestamps[0]);
        ++queries;
        if ((queries.load() & 255) == 0) {
          std::lock_guard<std::mutex> guard(latency_mutex);
          latency.push_back(ns(query_start, query_end));
        }
      }
      consumed.fetch_xor(hash, std::memory_order_relaxed);
      ct_close(reader);
    });
  }
  ct_handle *writer = nullptr;
  ct_ok(ct_open_writer(path.data(), path.size(), CT_CODEC_RAW, &writer),
        "writer reopen");
  const auto begin = Clock::now();
  go = true;
  uint64_t index = base;
  while (std::chrono::duration<double>(Clock::now() - begin).count() < seconds) {
    const int64_t timestamp = static_cast<int64_t>(index);
    const double value = static_cast<double>(index);
    ct_ok(ct_append(writer, "series-0", 8, &timestamp, &value, 1),
          "concurrent append");
    ++index;
    ++writes;
    if ((index - base) % 65'536 == 0) {
      ct_ok(ct_checkpoint(writer, 1), "concurrent checkpoint");
    }
  }
  ct_ok(ct_checkpoint(writer, 1), "final checkpoint");
  stop = true;
  for (auto &reader : readers) reader.join();
  ct_close(writer);
  const double elapsed =
      std::chrono::duration<double>(Clock::now() - begin).count();
  return {{elapsed, writes.load(), writes.load(), files_size(path)},
          {elapsed, queries.load(), queries.load() * 100, 0, latency, {}}};
}

static ConcurrentMetrics concurrent_nanots(const std::string &path,
                                            int reader_count, int seconds,
                                            uint64_t base) {
  remove_database(path);
  const uint64_t extra = 50'000'000;
  const uint64_t window = 65'536;
  nanots_writer::allocate(
      path, nano_block(window),
      static_cast<uint32_t>((base + extra + window - 1) / window));
  auto writer = std::make_unique<nanots_writer>(path);
  auto context = std::make_unique<write_context>(
      writer->create_write_context("series-0", "benchmark"));
  uint64_t random_state = 1;
  for (uint64_t index = 0; index < base; ++index) {
    Point point{static_cast<int64_t>(index),
                value_for(index, ValuePattern::smooth, random_state)};
    writer->write(*context, reinterpret_cast<uint8_t *>(&point), sizeof(point),
                  0, point.timestamp);
  }

  std::atomic<bool> go = false;
  std::atomic<bool> stop = false;
  std::atomic<uint64_t> writes = 0;
  std::atomic<uint64_t> queries = 0;
  std::mutex latency_mutex;
  std::vector<uint64_t> latency;
  std::vector<std::thread> readers;
  for (int reader_index = 0; reader_index < reader_count; ++reader_index) {
    readers.emplace_back([&, reader_index] {
      nanots_iterator iterator(path, "series-0");
      uint64_t reader_state = reader_index + 7;
      uint64_t hash = 0;
      while (!go.load()) {}
      while (!stop.load()) {
        const int64_t start = splitmix(reader_state) % (base - 99);
        const auto query_start = Clock::now();
        if (!iterator.find(start)) fail("NanoTS concurrent find");
        for (int index = 0; index < 100; ++index) {
          hash ^= static_cast<uint64_t>(iterator->timestamp);
          if (index < 99) ++iterator;
        }
        const auto query_end = Clock::now();
        ++queries;
        if ((queries.load() & 255) == 0) {
          std::lock_guard<std::mutex> guard(latency_mutex);
          latency.push_back(ns(query_start, query_end));
        }
      }
      consumed.fetch_xor(hash, std::memory_order_relaxed);
    });
  }
  const auto begin = Clock::now();
  go = true;
  uint64_t index = base;
  while (std::chrono::duration<double>(Clock::now() - begin).count() < seconds) {
    Point point{static_cast<int64_t>(index), static_cast<double>(index)};
    writer->write(*context, reinterpret_cast<uint8_t *>(&point), sizeof(point),
                  0, point.timestamp);
    ++index;
    ++writes;
  }
  context.reset();
  writer.reset();
  stop = true;
  for (auto &reader : readers) reader.join();
  const double elapsed =
      std::chrono::duration<double>(Clock::now() - begin).count();
  return {{elapsed, writes.load(), writes.load(), files_size(path)},
          {elapsed, queries.load(), queries.load() * 100, 0, latency, {}}};
}

static ConcurrentMetrics concurrent_sqlite(const std::string &path,
                                            int reader_count, int seconds,
                                            uint64_t base) {
  build_database("sqlite", path, base, 1, false, ValuePattern::smooth, 65'536);
  Sqlite writer(path, false);
  writer.execute("PRAGMA synchronous=FULL");
  writer.prepare_insert();
  std::atomic<bool> go = false;
  std::atomic<bool> stop = false;
  std::atomic<uint64_t> writes = 0;
  std::atomic<uint64_t> queries = 0;
  std::mutex latency_mutex;
  std::vector<uint64_t> latency;
  std::vector<std::thread> readers;
  for (int reader_index = 0; reader_index < reader_count; ++reader_index) {
    readers.emplace_back([&, reader_index] {
      Sqlite reader(path, false);
      sqlite3_stmt *query = nullptr;
      sql_ok(sqlite3_prepare_v2(
                 reader.database,
                 "SELECT ts,value FROM points WHERE series_id=0 AND ts>=? "
                 "ORDER BY ts LIMIT 100",
                 -1, &query, nullptr),
             reader.database, "concurrent prepare");
      uint64_t random_state = reader_index + 7;
      uint64_t hash = 0;
      while (!go.load()) {}
      while (!stop.load()) {
        const int64_t start = splitmix(random_state) % (base - 99);
        sqlite3_bind_int64(query, 1, start);
        const auto query_start = Clock::now();
        int result_count = 0;
        while (sqlite3_step(query) == SQLITE_ROW) {
          hash ^= static_cast<uint64_t>(sqlite3_column_int64(query, 0));
          ++result_count;
        }
        const auto query_end = Clock::now();
        if (result_count != 100) fail("SQLite concurrent short query");
        sqlite3_reset(query);
        sqlite3_clear_bindings(query);
        ++queries;
        if ((queries.load() & 255) == 0) {
          std::lock_guard<std::mutex> guard(latency_mutex);
          latency.push_back(ns(query_start, query_end));
        }
      }
      sqlite3_finalize(query);
      consumed.fetch_xor(hash, std::memory_order_relaxed);
    });
  }
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  writer.execute("BEGIN IMMEDIATE");
  const auto begin = Clock::now();
  go = true;
  uint64_t index = base;
  while (std::chrono::duration<double>(Clock::now() - begin).count() < seconds) {
    writer.add(0, index, static_cast<double>(index));
    ++index;
    ++writes;
    if ((index - base) % 65'536 == 0) {
      writer.execute("COMMIT");
      writer.execute("BEGIN IMMEDIATE");
    }
  }
  writer.execute("COMMIT");
  stop = true;
  for (auto &reader : readers) reader.join();
  const double elapsed =
      std::chrono::duration<double>(Clock::now() - begin).count();
  return {{elapsed, writes.load(), writes.load(), files_size(path)},
          {elapsed, queries.load(), queries.load() * 100, 0, latency, {}}};
}

static void print_metrics(const Metrics &metrics, const std::string &engine,
                          const std::string &workload, int run) {
  std::cout << std::setprecision(12)
            << "{\"schema\":2,\"engine\":\"" << engine
            << "\",\"workload\":\"" << workload << "\",\"run\":" << run
            << ",\"seconds\":" << metrics.seconds
            << ",\"operations\":" << metrics.operations
            << ",\"points\":" << metrics.points
            << ",\"file_bytes\":" << metrics.bytes
            << ",\"latency_scope\":\"" << metrics.latency_scope << "\""
            << ",\"p50_ns\":" << percentile(metrics.latency, 0.50)
            << ",\"p95_ns\":" << percentile(metrics.latency, 0.95)
            << ",\"p99_ns\":" << percentile(metrics.latency, 0.99)
            << ",\"max_ns\":" << percentile(metrics.latency, 1.0)
            << ",\"sync_p50_ns\":" << percentile(metrics.sync_latency, 0.50)
            << ",\"sync_p95_ns\":" << percentile(metrics.sync_latency, 0.95)
            << ",\"sync_p99_ns\":" << percentile(metrics.sync_latency, 0.99)
            << ",\"sync_max_ns\":" << percentile(metrics.sync_latency, 1.0)
            << ",\"checksum\":" << consumed.load() << "}" << std::endl;
}

int main(int argc, char **argv) {
  try {
    if (argc < 2) fail("missing command");
    const std::string command = argv[1];
    if (command == "append") {
      if (argc != 12) {
        fail("append engine path count series boundary codec pattern batch run label");
      }
      const std::string engine = argv[2];
      const std::string path = argv[3];
      const uint64_t count = std::stoull(argv[4]);
      const int series_count = std::stoi(argv[5]);
      const uint64_t boundary = std::stoull(argv[6]);
      const bool compressed = std::string(argv[7]) == "compressed";
      const ValuePattern pattern = parse_pattern(argv[8]);
      const size_t batch_size = std::stoull(argv[9]);
      const int run = std::stoi(argv[10]);
      const std::string label = argv[11];
      const Metrics metrics = build_database(
          engine, path, count, series_count, compressed, pattern, boundary,
          batch_size);
      verify_database(engine, path, count, series_count);
      print_metrics(metrics, engine, label, run);
    } else if (command == "query" || command == "aggregate") {
      if (argc != 11) {
        fail(command + " engine path dataset queries width codec run label seed");
      }
      const std::string engine = argv[2];
      const std::string path = argv[3];
      const uint64_t dataset = std::stoull(argv[4]);
      const uint64_t query_count = std::stoull(argv[5]);
      const int width = std::stoi(argv[6]);
      const bool compressed = std::string(argv[7]) == "compressed";
      const int run = std::stoi(argv[8]);
      const std::string label = argv[9];
      const uint64_t seed = std::stoull(argv[10]);
      build_database(engine, path, dataset, 1, compressed, ValuePattern::smooth,
                     65'536);
      verify_database(engine, path, dataset, 1);
      Metrics metrics = command == "query"
                            ? query_database(engine, path, query_count, width,
                                             dataset, seed)
                            : aggregate_database(engine, path, query_count,
                                                 width, dataset, seed);
      verify_database(engine, path, dataset, 1);
      metrics.bytes = files_size(path);
      print_metrics(metrics, engine, label, run);
    } else if (command == "concurrent") {
      if (argc != 8) {
        fail("concurrent engine path readers seconds run label");
      }
      const std::string engine = argv[2];
      const std::string path = argv[3];
      const int reader_count = std::stoi(argv[4]);
      const int seconds = std::stoi(argv[5]);
      const int run = std::stoi(argv[6]);
      const std::string label = argv[7];
      const ConcurrentMetrics metrics =
          engine == "chronotail"
              ? concurrent_chronotail(path, reader_count, seconds, 1'000'000)
          : engine == "nanots"
              ? concurrent_nanots(path, reader_count, seconds, 1'000'000)
              : concurrent_sqlite(path, reader_count, seconds, 1'000'000);
      verify_database(engine, path, 1'000'000 + metrics.writer.operations, 1);
      print_metrics(metrics.writer, engine, label + "-writer", run);
      print_metrics(metrics.reader, engine, label + "-readers", run);
    } else {
      fail("unknown command");
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "ERROR: " << error.what() << "\n";
    return 1;
  }
}
