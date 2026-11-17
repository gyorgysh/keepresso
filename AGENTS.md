# AGENTS.md

Guidance for coding agents (and humans) working in this repository. This is a
durable map of what the project is and where things live, not a feature log.
For what shipped when, read `CHANGELOG.md`.

## What this is

Keepresso is a macOS **menu-bar keep-awake app** (Swift + SwiftUI, macOS 14+):
it holds the Mac awake, either manually or automatically while triggers hold
(on a call, downloading, gaming, an AI agent working, and so on), and lets it
sleep otherwise.

It is distributed **open-source via GitHub + Homebrew Cask, not the Mac App
Store**, because the App Sandbox blocks the `IOPMAssertion` power APIs the app
depends on. Keep `ENABLE_APP_SANDBOX: false` in `project.yml`. Sandboxing the
app silently breaks its core function. The repo is **public**: keep commit
messages tidy and release-worthy.

## Layout

Two-layer split, deliberately keeping all testable logic out of the UI:

- **`Sources/KeepressoCore`**: a SwiftPM library with **no SwiftUI**. This is
  where behavior lives and where tests go (`Tests/KeepressoCoreTests`). System
  access (power, network, workspace, disk, SMC, brightness) sits behind protocol
  seams so tests can inject fakes.
- **`Sources/Keepresso`**: the SwiftUI `MenuBarExtra` app shell. Thin: views +
  lifecycle glue, depends on `KeepressoCore`. `AppModel` wires the real backends.
- **`Sources/KeepressoWidget`**: the widget + Control Center appex. Talks to the
  app through an App Group (`WidgetBridge` in Core). The group id is resolved at
  runtime from the process's own signature, never hardcoded.

`project.yml` (XcodeGen) defines the app target and references the local package.
The generated `Keepresso.xcodeproj` is **git-ignored**: never commit it,
regenerate it with `xcodegen generate`.

### Where things live

- **Privileged work** goes through a root helper (`SMAppService` daemon, source
  in `Sources/keepresso-helper`, protocol in `KeepressoCore/HelperService.swift`,
  app-side glue in `HelperManager`) over a versioned XPC protocol: closed-display
  `disablesleep`, `pmset` wake schedules, fan holds, AWDL pausing, priority boost,
  Keyboard Cleaner, DNS flush. Without the helper, these features fall back to a
  password prompt on purpose, and a notification always explains it first.
- **Bundled tools** under `Contents/Helpers`: the `keepresso` CLI
  (`Sources/keepresso-cli`) and the `keepresso-mcp` stdio MCP server
  (`Sources/keepresso-mcp`), both of which drive automation leases. A
  ready-to-install agent skill ships under
  `Contents/Resources/AgentSkill/keep-awake`.
- **Localization**: 15 UI languages, generated from Python catalogs in
  `tools/localization/` (`gen_strings.py`, the `catalog_*.py` files, and the
  per-language `extra/*` overlays). Never hand-edit `*.lproj/Localizable.strings`.
  Run `python3 tools/localization/check_all.py` after any string change.
- **Distribution**: the tag-triggered `.github/workflows/release.yml` builds,
  signs, notarizes, and publishes the DMG + signed Sparkle appcast on every `v*`
  tag. Each release also bumps `Casks/keepresso.rb` (`version` + `sha256`) in the
  `gyorgysh/homebrew-keepresso` tap. The Sparkle updater seam is
  `Sources/Keepresso/Updater.swift`.
- **Docs**: `docs/BUILDING.md` (build it yourself), `docs/AUTOMATION_SYNC.md`
  (Scheduled AI runs design), `docs/AGENT_BRANDS.md` (agent brand assets).

## Commands

```sh
# Core logic (KeepressoCore), runs anywhere with a Swift toolchain
swift build                 # build the core library
swift test                  # run the test suite (needs full Xcode, not just CLT)
swift test --filter timedSessionExpiresOnReconcile   # a single test

# The app, needs full Xcode + xcodegen (brew install xcodegen)
xcodegen generate           # regenerate Keepresso.xcodeproj from project.yml
open Keepresso.xcodeproj    # build/run the Keepresso scheme with Cmd-R

# The checks CI runs besides the build and tests
python3 tools/localization/check_all.py
bash scripts/check-versions.sh
python3 scripts/check-location-permission.py
```

**Toolchain caveat:** with only Command Line Tools (no Xcode.app), `swift test`
fails, since neither XCTest nor swift-testing ships with CLT. The app target
(`MenuBarExtra`, Info.plist bundling, the `.icon` app icon) requires full Xcode.

## Core control flow

`SessionController` (`@Observable`, `@MainActor`) is the heart. It does **not**
run its own timer. The host drives it:

1. `start(...)` / `stop()` / `toggle()` set session state.
2. The app's `SessionTicker` calls `reconcile(now:systemIdleSeconds:...)` once a
   second, feeding real HID idle time (`SessionTicker.systemIdleSeconds()` reads
   `IOHIDSystem`'s `HIDIdleTime`) plus battery, thermal, and display readings.
3. `reconcile` expires timed sessions and computes the desired assertion set via
   `desiredAssertions(...)`, then hands it to a `PowerAsserting`.

This injection is intentional: tests advance a fake clock and call `reconcile`
directly with a `FakeAssertions` standing in for IOKit. **Preserve this seam.**
Keep new time, idle, or power inputs injectable rather than reaching for `Date()`
or IOKit inside the controller.

`PowerAsserting` abstracts IOKit. `IOKitPowerAssertionManager` holds at most one
assertion per `PowerAssertionKind` (`.system` →
`kIOPMAssertPreventUserIdleSystemSleep`, `.display` → `...DisplaySleep`).
`apply(_:reason:)` is **idempotent**, so calling it every second is fine. The
system and display assertions are independent on purpose: "allow screen saver
after N min" keeps `.system` while dropping `.display` once HID idle passes the
threshold.

## Conventions

- New testable behavior goes in `KeepressoCore` behind a protocol seam if it
  touches the system, mirroring `PowerAsserting`. The app wires the real
  implementation, tests use a fake.
- The controller and anything it touches are `@MainActor`.
- A new feature generally means: a Core component + protocol + tests first, then
  thin SwiftUI in the app.

## Writing and UI style

- Never use em dashes in any prose: docs, comments, commit messages, UI copy.
  Use a comma, a colon, parentheses, or two sentences instead.
- Keep the UI clean and professional: restrained spacing and color, system fonts
  and SF Symbols, no gratuitous animation or decoration. Prefer clear, plain
  labels over clever ones.
