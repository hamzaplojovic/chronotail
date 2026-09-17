//! Stable public Zig API for Chronotail file format v6.
//! Internal modules may change without changing this facade.
const engine = @import("internal/engine.zig");

pub const file_header = engine.file_header;
pub const block_size = engine.block_size;
pub const block_header_size = engine.block_header_size;
pub const record_size = engine.record_size;
pub const records_per_block = engine.records_per_block;
pub const compression_min_savings_percent = engine.compression_min_savings_percent;

pub const Codec = engine.Codec;
pub const Appender = engine.Appender;
pub const Reader = engine.Reader;
pub const QueryProfile = engine.QueryProfile;
pub const VerificationReport = engine.VerificationReport;

pub const AppenderFor = engine.AppenderFor;
pub const ReaderFor = engine.ReaderFor;
pub const verifyPath = engine.verifyPath;
pub const encodeRecord = engine.encodeRecord;
