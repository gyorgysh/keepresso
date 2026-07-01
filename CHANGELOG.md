# Changelog

All notable changes to Keepresso are documented here. Versions follow
[Semantic Versioning](https://semver.org).

## 1.2.0

- **Pause Triggers.** A one-click "Pause Triggers" / "Resume Triggers" button
  in the menu bar, for when you want to stop brewing without going into
  Preferences and turning the whole trigger system off. Pausing stops the
  session immediately and hands control to the manual toggle; resuming hands
  it back to your conditions. It's a temporary, in-memory switch: quitting and
  relaunching Keepresso always comes back active, unpaused.
- **The screen actually turns off with the lid closed.** Closed-display mode
  used to keep the Mac running with the lid shut, but the internal panel
  stayed lit inside the closed lid. Keepresso now detects the lid closing and
  puts the display itself to sleep (unless an external display is attached),
  so it's not wasting battery or trapping heat against a closed screen. The
  display wakes normally the instant you open the lid.
- **Cleaner menu bar.** Reworked button styling so the one action that matters
  (Pause/Resume Triggers) stands out, and navigation items (Preferences,
  Headless Setup, About, Check for Updates, Quit) read as quiet menu rows
  instead of competing boxed buttons. Minor copy fixes to some captions.

## 1.1.1

- Fixed a crash in the headless-readiness Setup screen.
- Corrected stale distribution docs.

## 1.1.0

- **Battery-aware auto-pause.** Let the Mac sleep once charge drops below a
  threshold you choose, even mid-session, so it never runs the battery flat.
- **Menu-bar countdown.** An optional live countdown next to the cup icon for
  timed sessions.
- **URL scheme.** Drive a session from Shortcuts, Raycast, Alfred, or a shell
  script with `keepresso://start?duration=60`, `stop`, or `toggle`.
- **Presets.** Apply a named trigger bundle in one click, built-in (AI Agent,
  On AC Power, External Display Connected) or your own saved rule sets.

## 1.0.0

Initial public release.

- Keep system sleep and/or display sleep at bay, indefinitely or for a timed
  session, with an "allow the screen saver after N minutes idle" yield.
- Trigger engine: stay awake only while charging or on battery, an external
  display is connected, you're on a chosen Wi-Fi network, or a specific app is
  running (any/all combine logic).
- Auto app detection with a grace period, reminders for a forgotten session,
  disk keep-alive, closed-display mode (keep running with the lid shut, no
  external display), and a headless Setup checklist.
- Signed, notarized, self-updating via Sparkle; distributed as a DMG on
  GitHub Releases and via Homebrew Cask.
