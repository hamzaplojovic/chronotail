# Security policy

## Supported versions

Chronotail 1.x on macOS ARM64 receives correctness and security fixes. File
format v6 and C ABI v1 remain compatibility boundaries for that line. The v2
branch is prerelease code using format v7 and C ABI v2; security reports are
welcome, but it is not yet a stable release boundary.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for the repository. Do not open a public issue for a suspected memory-safety, file-validation, corruption, or durability vulnerability.

Include the affected version, a minimal reproducer or malformed file when possible, expected behavior, and observed behavior. Avoid including sensitive production data.

## Scope

Security-sensitive areas include parsing untrusted `.ctdb` files, checked offset
arithmetic, checksums and external identities, root election, v6 migration,
index traversal, C buffer/lifetime contracts, Python native-library loading, and
writer exclusivity. A checksum establishes byte identity, not semantic validity
or trust; callers must still control database paths and native libraries.
