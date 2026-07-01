# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Keepresso is a macOS **menu-bar keep-awake app** (Swift + SwiftUI, macOS 14+),
distributed open-source via GitHub/Homebrew Cask — **not** the Mac App Store,
because the App Sandbox blocks the `IOPMAssertion` power APIs it depends on. Keep
`ENABLE_APP_SANDBOX: false` in `project.yml`; sandboxing the app silently breaks
its core function.

The full feature scope and milestone status live in `docs/ROADMAP.md` (kept local,
not published yet).
v0.1 through v0.6 are implemented (core engine, trigger engine, auto app
detection, alarm/reminder, disk keep-alive, headless-readiness Setup screen),
along with all Polish (next-trigger summary, Preferences window, launch-at-login,
settings persistence, animated icon) and the App shell (About window, menu
entries). v1.1 (battery auto-pause, menu-bar countdown, `keepresso://` URL
scheme, presets) is done too. The Sparkle auto-updater is fully wired in
(SwiftPM dependency, app-side `Updating` seam in `Keepresso/Updater.swift`,
Info.plist `SUFeedURL` + a real `SUPublicEDKey` + `SUEnableAutomaticChecks`). A
closed-display mode (keep running with the lid shut, no external display) is also
done: since `IOPMAssertion` can't override clamshell sleep, it flips the global
`pmset disablesleep` setting via an admin prompt (Core seam
`SleepSettingControlling`/`ClosedDisplayController` in `KeepressoCore/ClosedDisplay.swift`,
toggle in Preferences ▸ General). Distribution is live end to end: the
tag-triggered `.github/workflows/release.yml` builds, signs, notarizes, and
publishes a real DMG + signed Sparkle appcast to GitHub Releases on every `v*`
tag (v1.0.0 and v1.1.0 have both shipped this way; see `docs/RELEASING.md`).
What remains is publishing `Casks/keepresso.rb` to the `gyorgysh/homebrew-keepresso`
tap so `brew install --cask keepresso` works.
A headless virtual-display proof-of-concept (private `CGVirtualDisplay` API,
behind an off-by-default flag) is also done, still needing validation on real
headless hardware. Current version: 1.1.0 (build 8). The code is pushed to a
**private** GitHub repo (`git@github.com:gyorgysh/keepresso.git`, branch
`main`); history is provisional and may be squashed/rebased to a clean initial
state before going public, so commit freely but keep messages tidy.

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
logic in that situation, compile the sources plus a small `@main` driver with
`swiftc -parse-as-library Sources/KeepressoCore/*.swift driver.swift` and run it.
The app target (`MenuBarExtra`, Info.plist bundling) requires full Xcode to build.

## Architecture

Two-layer split, deliberately keeping all testable logic out of the UI:

- **`KeepressoCore`** (`Sources/KeepressoCore`) — a SwiftPM library with **no
  SwiftUI**. This is where behavior lives and where tests go.
- **`Keepresso`** app (`Sources/Keepresso`) — the SwiftUI `MenuBarExtra` shell.
  Thin: views + lifecycle glue, depends on `KeepressoCore`.

`project.yml` (XcodeGen) defines the app target and references the local package;
the generated `.xcodeproj` is **git-ignored** — never commit it, regenerate it.

### Core control flow

`SessionController` (`@Observable`, `@MainActor`) is the heart. It does **not**
run its own timer — the host drives it:

1. `start(mode:options:)` / `stop()` / `toggle()` set session state.
2. The app's `SessionTicker` calls `reconcile(now:systemIdleSeconds:)` once a
   second, feeding real HID idle time (`SessionTicker.systemIdleSeconds()` reads
   `IOHIDSystem`'s `HIDIdleTime`).
3. `reconcile` expires timed sessions and computes the desired assertion set via
   `desiredAssertions(systemIdleSeconds:)`, then hands it to a `PowerAsserting`.

This timer-injection is intentional: tests advance a fake clock and call
`reconcile` directly (see `Tests/KeepressoCoreTests`), with a `FakeAssertions`
standing in for IOKit. **Preserve this seam** — keep new time/idle/power inputs
injectable rather than reaching for `Date()` or IOKit inside the controller.

### Power assertions

`PowerAsserting` abstracts IOKit. `IOKitPowerAssertionManager` is the real
backend; it holds at most one assertion per `PowerAssertionKind` (`.system` →
`kIOPMAssertPreventUserIdleSystemSleep`, `.display` →
`...DisplaySleep`). `apply(_:reason:)` is **idempotent** — it reconciles live
assertions to exactly the requested set, so calling it every second is fine.

The system and display assertions are independent on purpose. The "allow screen
saver after N min" feature works by keeping `.system` while dropping `.display`
once HID idle passes the threshold — that's the only reason the controller needs
idle time.

## Conventions

- New testable behavior goes in `KeepressoCore` behind a protocol seam if it
  touches the system (power, network, workspace, disk), mirroring
  `PowerAsserting`. The app wires the real implementation; tests use a fake.
- The controller and anything it touches are `@MainActor`.
- Adding a roadmap feature (triggers, app detection, alarm, disk keep-alive)
  generally means: a Core component + protocol + tests first, then thin SwiftUI
  in the app, then check the box in `docs/ROADMAP.md`.

## Writing and UI style

- Never use em dashes in any prose: docs, comments, commit messages, UI copy, or
  chat replies. Use a comma, a colon, parentheses, or two sentences instead.
- Keep the UI clean and professional: restrained spacing and color, system
  fonts and SF Symbols, no gratuitous animation or decoration. Prefer clear,
  plain labels over clever ones.
