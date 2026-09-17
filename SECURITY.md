# Security policy

## Supported version

Chronotail 1.x on macOS ARM64 receives correctness and security fixes. File format v6 and C ABI v1 remain compatibility boundaries for the v1 series.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for the repository. Do not open a public issue for a suspected memory-safety, file-validation, corruption, or durability vulnerability.

Include the affected version, a minimal reproducer or malformed file when possible, expected behavior, and observed behavior. Avoid including sensitive production data.

## Scope

Security-sensitive areas include parsing untrusted `.ctdb` files, checked offset arithmetic, checksums, footer-chain recovery, C ABI buffer contracts, Python native-library loading, and writer exclusivity. A checksum establishes byte integrity, not trust; callers must still control access to database paths and native libraries.
