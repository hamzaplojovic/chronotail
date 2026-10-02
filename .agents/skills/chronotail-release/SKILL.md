---
name: chronotail-release
description: Validate Chronotail native release artifacts, version boundaries, and migration evidence before an authorized release.
---

Read AGENTS.md, scripts/targets.sh, RELEASE_NOTES.md, and docs/development/maintenance.md.
Use scripts/dev.sh release on native macOS ARM64: three test modes, clients,
1,000 simulator seeds/100M operations, full resource profile, metadata gates,
and isolated bundle smoke tests. A Linux cross-build is not native validation.

Verify tag/source/wheel versions and release-note status. Keep v6 migration-only
on the current line. New format/ABI boundaries require explicit documentation
and separate-file migration evidence. Preserve historical benchmark archives.

An authorized release merge is incomplete until its matching annotated tag and
GitHub release exist, with the validated bundles, checksums, and version-specific
notes. The tag workflow publishes after full native validation; manual dispatch
only creates candidates. Verify actual tag/asset/workflow status before reporting
shipment. Ordinary maintenance merges do not publish releases. This skill grants
no authorization. Report missing native validation or publication access plainly.
