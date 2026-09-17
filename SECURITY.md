# Security policy

## Supported versions

Chronotail 1.x on macOS ARM64 receives correctness and security fixes within its
frozen format-v6 and C-ABI-v1 boundaries. Chronotail 2.0.0 is currently
prerelease source using format v7 and C ABI v2; security reports are welcome,
but published support starts only with a signed release record and artifacts.

## Report a vulnerability

Use GitHub private vulnerability reporting for this repository. Do not open a
public issue for suspected memory-safety, file-validation, corruption,
durability, migration, or native-library-loading vulnerabilities.

Include:

- the affected Chronotail version, commit, file format, and API surface;
- a minimal reproducer or malformed `.ctdb` file when possible;
- expected and observed behavior;
- whether the file was opened as a reader, writer, verifier, or migration input;
- relevant operating-system and filesystem details.

Do not include sensitive production data. A synthetic file with the same
structure is preferable.

## Security-sensitive boundaries

The highest-risk areas are:

- parsing offsets, lengths, integer domains, and reserved fields from untrusted
  `.ctdb` files;
- BLAKE3 object identities, root election, predecessor validation, and semantic
  checks beyond authentication;
- publication order, `fsync` handling, older-root fallback, and writer
  poisoning after failed I/O;
- v6 parsing and separate-file migration;
- index traversal, summaries, codecs, and overlapping physical-range checks;
- C buffer lengths, handle kinds, generation-bound cursors, and borrowed-pointer
  lifetimes;
- Python native-library discovery and ABI verification;
- exclusive writer locking and safe reader refresh.

An identity proves exact bytes, not trust or semantic validity. Callers must
still control database paths and native libraries, and should run full
verification before accepting files from an untrusted source.

## Disclosure expectations

We will confirm receipt, reproduce the issue, assess affected versions, and
coordinate a fix and disclosure timeline with the reporter. Please allow time
for deterministic tests, malformed-file coverage, simulator runs, and release
artifact validation before public disclosure.
