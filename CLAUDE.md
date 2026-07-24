# CLAUDE.md

Guidance for Claude Code working in this repository. This is a durable map of
what the project is and where things live, not a feature log. For what shipped
when, read `CHANGELOG.md`; for scope and what's next, `docs/ROADMAP.md` (kept
local, not published).

## What this is

Keepresso is a macOS **menu-bar keep-awake app** (Swift + SwiftUI, macOS 14+):
it holds the Mac awake, either manually or automatically while triggers hold
(on a call, downloading, gaming, an AI agent working, and so on), and lets it
sleep otherwise.

It is distributed **open-source via GitHub + Homebrew Cask, not the Mac App
Store**, because the App Sandbox blocks the `IOPMAssertion` power APIs the app
depends on. Keep `ENABLE_APP_SANDBOX: false` in `project.yml` — sandboxing the
app silently breaks its core function. The repo is **public**; keep commit
messages tidy and release-worthy.

## Layout

Two-layer split, deliberately keeping all testable logic out of the UI:

- **`Sources/KeepressoCore`** — a SwiftPM library with **no SwiftUI**. This is
  where behavior lives and where tests go (`Tests/KeepressoCoreTests`). System
  access (power, network, workspace, disk, SMC, brightness) sits behind protocol
  seams so tests can inject fakes.
- **`Sources/Keepresso`** — the SwiftUI `MenuBarExtra` app shell. Thin: views +
  lifecycle glue, depends on `KeepressoCore`. `AppModel` wires the real backends.
- **`Sources/KeepressoWidget`** — the widget + Control Center appex. Talks to the
  app through an App Group (`WidgetBridge` in Core); the group id is resolved at
  runtime from the process's own signature, never hardcoded.

`project.yml` (XcodeGen) defines the app target and references the local package.
The generated `Keepresso.xcodeproj` is **git-ignored** — never commit it,
regenerate it with `xcodegen generate`.

### Where things live

- **Privileged work** goes through a root helper (`SMAppService` daemon, source
  in `Sources/keepresso-helper`, app-side glue in `HelperManager`/`HelperService`)
  over a versioned XPC protocol: `pmset` wake schedules, closed-display
  `disablesleep`, fan holds, priority boost. Password prompts always get a
  notification first.
- **Bundled tools** under `Contents/Helpers`: the `keepresso` CLI and the
  `keepresso-mcp` stdio MCP server (both drive automation leases). A
  ready-to-install agent skill ships under
  `Contents/Resources/AgentSkill/keep-awake`.
- **Localization**: 15 UI languages, generated from Python catalogs in
  `tools/localization/` (`gen_strings.py`, `check_extra.py`, and the per-language
  `extra/*` overlays). See the localization notes in memory before a sweep.
- **Distribution**: the tag-triggered `.github/workflows/release.yml` builds,
  signs, notarizes, and publishes the DMG + signed Sparkle appcast on every `v*`
  tag. Each release also needs `Casks/keepresso.rb` bumped (`version` + `sha256`)
  and pushed to the `gyorgysh/homebrew-keepresso` tap. The Sparkle updater seam
  is `Keepresso/Updater.swift`. See `docs/RELEASING.md` and the `release` skill.
- **Docs**: `docs/ROADMAP.md` (scope/status), `docs/RELEASING.md` (ship
  process), `docs/AUTOMATION_SYNC.md` (Scheduled AI runs design).

## Commands

```sh
# Core logic (KeepressoCore) — runs anywhere with a Swift toolchain
swift build                 # build the core library
swift test                  # run the test suite (needs full Xcode, not just CLT)
swift test --filter timedSessionExpiresOnReconcile   # a single test

# The app — needs full Xcode + xcodegen (brew install xcodegen)
xcodegen generate           # regenerate Keepresso.xcodeproj from project.yml
open Keepresso.xcodeproj    # build/run the Keepresso scheme with ⌘R
```

**Toolchain caveat:** with only Command Line Tools (no Xcode.app), `swift test`
fails — neither XCTest nor swift-testing ships with CLT. To sanity-check core
logic then, compile the sources plus a small `@main` driver with
`swiftc -parse-as-library Sources/KeepressoCore/*.swift driver.swift` and run it.
The app target (`MenuBarExtra`, Info.plist bundling) requires full Xcode to build.

## Core control flow

`SessionController` (`@Observable`, `@MainActor`) is the heart. It does **not**
run its own timer — the host drives it:

1. `start(mode:options:)` / `stop()` / `toggle()` set session state.
2. The app's `SessionTicker` calls `reconcile(now:systemIdleSeconds:)` once a
   second, feeding real HID idle time (`SessionTicker.systemIdleSeconds()` reads
   `IOHIDSystem`'s `HIDIdleTime`).
3. `reconcile` expires timed sessions and computes the desired assertion set via
   `desiredAssertions(systemIdleSeconds:)`, then hands it to a `PowerAsserting`.

This timer injection is intentional: tests advance a fake clock and call
`reconcile` directly with a `FakeAssertions` standing in for IOKit. **Preserve
this seam** — keep new time/idle/power inputs injectable rather than reaching for
`Date()` or IOKit inside the controller.

`PowerAsserting` abstracts IOKit. `IOKitPowerAssertionManager` holds at most one
assertion per `PowerAssertionKind` (`.system` →
`kIOPMAssertPreventUserIdleSystemSleep`, `.display` → `...DisplaySleep`).
`apply(_:reason:)` is **idempotent**, so calling it every second is fine. The
system and display assertions are independent on purpose: the "allow screen saver
after N min" feature keeps `.system` while dropping `.display` once HID idle
passes the threshold, which is the only reason the controller needs idle time.

## Conventions

- New testable behavior goes in `KeepressoCore` behind a protocol seam if it
  touches the system, mirroring `PowerAsserting`. The app wires the real
  implementation; tests use a fake.
- The controller and anything it touches are `@MainActor`.
- A new feature generally means: a Core component + protocol + tests first, then
  thin SwiftUI in the app, then update `docs/ROADMAP.md`.

## Writing and UI style

- Never use em dashes in any prose: docs, comments, commit messages, UI copy, or
  chat replies. Use a comma, a colon, parentheses, or two sentences instead.
- Keep the UI clean and professional: restrained spacing and color, system fonts
  and SF Symbols, no gratuitous animation or decoration. Prefer clear, plain
  labels over clever ones.
</content>
