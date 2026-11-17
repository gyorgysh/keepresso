# Security

Keepresso is GPL-3.0 open-source software, built and maintained in the open.
There is no private disclosure process and no embargo.

## Reporting an issue

Open a [GitHub issue](https://github.com/gyorgysh/keepresso/issues) or send a
pull request with the fix. Both are fine, and a pull request is even better.

Please include:

- the Keepresso version and macOS version
- what an attacker could do, and what they need first (local access, another
  app running as the same user, and so on)
- steps or a proof of concept to reproduce it

Do not paste real secrets, tokens, or personal data into a public issue.

## Supported versions

Fixes land in the latest release only. Keepresso updates itself through Sparkle
and Homebrew, so stay on the current version.

## Scope

Areas where a report is most useful:

- the root helper (`Sources/keepresso-helper`) and its XPC interface, including
  how it validates the calling app
- the `keepresso` CLI and the `keepresso-mcp` server, and the automation leases
  they grant
- the update path: the signed Sparkle appcast and the notarized DMG
