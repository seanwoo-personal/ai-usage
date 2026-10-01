# CLI credentials are owned by the CLI

Status: existing constraint, documented 2026-10-01. Owner: @seanwoo-personal.

AI Usage reads existing CLI login information; it never refreshes or deletes the CLI's credentials.
Refreshing independently could invalidate the CLI's session. Account changes invalidate the app's cached credential;
if the new credential cannot be read, an older account's token is not a fallback.
Disconnect removes the app's cache. Shared web sign-in data is removed only when no web connection needs it.

Alternative: independently manage CLI authentication. Rejected because it crosses the CLI's ownership boundary.
Evidence: [ClaudeProvider](../../Sources/AIUsage/ClaudeProvider.swift), [Backend](../../Sources/AIUsage/Backend.swift).
Verification: CredentialTests and StoreTests in [store tests](../../Tests/store_tests.swift), using invented credentials only.
