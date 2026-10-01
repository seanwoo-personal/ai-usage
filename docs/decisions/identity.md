# Stable application identity

Status: existing constraint, documented 2026-10-01. Owner: @seanwoo-personal.

The bundle identifier remains com.sean.aiusage. Build rejects an incompatible override.
An earlier identifier created a separate settings/cache/login-item identity. A casual rename would repeat that split.
A display-name change must not silently change the bundle identifier.

Alternative: introduce a new identity with an explicit migration. That requires a separate product decision and migration tests.
Evidence: [build script](../../scripts/build-app.sh), [LoginItem](../../Sources/AIUsage/LoginItem.swift).
Impact: settings, web sessions, installation and startup. Run SelfTest location/startup cases and the installer suite.
