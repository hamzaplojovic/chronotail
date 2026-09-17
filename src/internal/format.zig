//! Frozen Chronotail on-disk format v6 constants.
pub const version: u8 = 6;
pub const file_header = [_]u8{ 'C', 'T', 'D', 'B', version };
pub const block_magic = "CTBK";
pub const footer_magic = "CTIDX006";
pub const trailer_magic = "CTTRL006";

pub const block_size = 64 * 1024;
pub const block_header_size = 48;
pub const record_size = 16;
pub const records_per_block = (block_size - block_header_size) / record_size;
pub const raw_payload_capacity = records_per_block * record_size;
pub const trailer_size = 32;
pub const snapshot_interval = 64;
pub const chunk_record_count = 128;
pub const checkpoint_entry_size = 12;
pub const compression_min_savings_percent = 10;

pub const Codec = enum(u8) {
    raw = 0,
    compressed = 1,
};
