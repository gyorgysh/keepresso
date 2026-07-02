# Changelog

All notable changes to Keepresso are documented here. Versions follow
[Semantic Versioning](https://semver.org).

## 1.3.0

- **Coffee redesign.** The app now matches the website's coffee palette: a
  caramel accent (warm amber in dark mode) replaces the old periwinkle across
  the menu, Preferences, Setup, and About, and the app icon is redrawn as the
  brand mark, an espresso cup with a crema stripe and steam, on a crema
  squircle (deep roast in dark mode). The menu header shows the cup with
  gently rising animated steam while brewing, plus a faint warm glow behind
  the glass; the steam holds still with Reduce Motion on. The liquid-glass
  surfaces are unchanged.
- **Closed-display mode works right after launch.** The lid-close display
  sleep used to stay inert until the menu was opened once, because the mode's
  on/off state was only read when UI appeared. It's now read at launch, so a
  Mac that reboots with the mode on sleeps the panel when the lid closes.
- **Turning triggers off now stops the session**, matching Pause Triggers,
  instead of silently converting a trigger-held session into a manual one
  with a leftover duration.
- **`keepresso://` commands now stick when triggers are on.** They pause
  triggers first (the same temporary pause as the menu button); before, the
  trigger engine would override the command within a second, making scripts
  silently do nothing. `keepresso://toggle` also starts with your saved
  default duration now, instead of always indefinite after a relaunch.
- **The panel sleeps when the external display is unplugged with the lid
  closed.** Closed-display mode only reacted to the lid closing; unplugging
  the monitor from a closed clamshell left the internal panel lit inside the
  lid. Both edges now put the display to sleep.
- **Smarter first-launch install.** Launching from a DMG now replaces an
  older installed copy instead of silently launching it (so you actually get
  the version you downloaded), and if the installed copy is already running
  it's brought forward instead of starting a duplicate second instance.
- **Editing one trigger no longer resets the others.** Rebuilding the trigger
  engine used to discard every condition's state, so editing an unrelated
  rule (or pausing and resuming) cut short an app rule's in-flight grace
  period, dropping the session instantly. Unchanged rules now keep their
  live state across edits.
- The Headless Setup tip now points at MyAgens.

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
