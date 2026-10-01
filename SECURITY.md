# Security Policy

## Supported versions

Only the latest release receives security fixes. The app updates itself, or you can re-run the install command.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub: **Security → Report a vulnerability** on this repository
([direct link](https://github.com/seanwoo-personal/ai-usage/security/advisories/new)).

Include what you found, how to reproduce it, and what an attacker could do with it. Please don't include real
passwords, tokens or cookies; synthetic values are enough. You can expect a first reply within a few days.

## Scope

Especially relevant: anything that could expose Claude / ChatGPT logins or tokens, make the app talk to a host other
than the official services or GitHub, bypass the installer's checks, or run code from an untrusted source.

## Known limitations

- Builds are ad-hoc signed with Hardened Runtime but not yet signed with an Apple Developer ID or notarized.
- The installer verifies the SHA-256 published in the same GitHub release; it cannot detect a compromised release.
- Usage comes from the services' internal endpoints, which can change without notice.
