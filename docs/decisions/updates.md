# One verified installer for both update paths

Status: existing constraint, documented 2026-10-01. Owner: @seanwoo-personal.

The build embeds the same installer used for command-line installation. Updater selects an exact release tag.
The installer checks checksum, archive paths, bundle identity, version and signature integrity before replacement.
Staging and rollback preserve the existing app on failure.

Alternative: independent in-app replacement logic. Rejected to avoid two diverging validation implementations.
The checksum and ZIP share a release source; this does not protect against a compromised release publisher.
Ad-hoc signatures prove integrity, not developer identity. Developer ID/notarization is a separate release capability.

Evidence: [Updater](../../Sources/AIUsage/Updater.swift), [installer](../../scripts/install.sh), [build](../../scripts/build-app.sh).
Verification: UpdaterTests and [isolated install tests](../../scripts/test-install.sh); release checks remain in [operations](../release-and-operations.md).
