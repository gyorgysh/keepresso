# Changelog

All notable changes to Keepresso are documented here. Versions follow
[Semantic Versioning](https://semver.org).

## 1.7.0

Theme: remote-work presence and everyday control.

### New

- **Keep me active (defeat idle detectors).** A plain power assertion keeps the
  Mac awake but doesn't reset app-level or enterprise idle detection, so
  remote-desktop and VDI sessions, meeting presence (Teams, Slack), and
  corporate idle-logout still mark you away. An opt-in "Keep me active" mode
  reports activity to macOS too, on the supported prompt-free path. It only
  steps in once you've been idle a few seconds, so it never nudges the pointer
  while you're using the Mac or gaming.
- **Global hotkey.** A system-wide keyboard shortcut to toggle keep-awake from
  any app, recorded in Preferences. Carbon-based, so it needs no Input
  Monitoring or Accessibility permission.
- **Start on launch.** Optionally begin a keep-awake session the moment
  Keepresso launches, for an always-on Mac that shouldn't need a rule.
- **"Held by <app>" in the menu.** When Keepresso is idle but the Mac still
  won't sleep, the dropdown names the app holding it awake (Chrome, coreaudiod).
- **Session-end notification and action.** Optionally get notified when a
  session ends on its own (a timer expiring, triggers dropping), and run an
  action: sleep the display or start the screen saver. Off by default.

### Gaming & Streaming

- **Auto AWDL pause just works.** Automatic mode now watches for a game (or a
  cloud-gaming app) on its own, with no "Playing a game" trigger to set up.
- **One password, up front.** Enabling auto mode authorizes the AWDL helper once,
  right then, so it never pops a password dialog over a running game. The prompt
  now explains what it's for (and that the "osascript" dialog is Keepresso).
- **Live status.** The Gaming & Streaming window and the menu show whether AWDL
  is paused for a game, paused manually, or counting down a grace after a game
  closes; a manual "Pause AWDL now" off cancels the countdown instead of letting
  it re-engage.
- **Optional notifications** when auto mode pauses and resumes, plus an always-on
  notice when your password is needed (even behind a fullscreen game).
- **Clearer Wi-Fi channel advice.** The 5 GHz suggestion now names the right
  social channel by region: 44 in the EU, 149 in the US, Canada, and elsewhere
  UNII-3 is allowed. The 2.4 GHz warning points at the 5 GHz channel to move to.
- A trigger condition in its grace window now shows amber with a countdown in the
  menu, so a lingering "Playing a game" reads as timed rather than stuck.

### Fixed

- The menu dropdown no longer stays open behind the windows it opens
  (Preferences, Setup, Gaming & Streaming, About).
- Battery auto-pause now only kicks in while actually running on battery: a low
  charge on AC (even while charging up) no longer pauses the session, and a
  gate-held session no longer flaps right at the cutoff. The menu explains a
  battery pause instead of just looking idle.
- The 5-minute gaming grace (and other grace windows) is no longer silently lost
  when combined with other conditions under "any"/"all".
- URL, Shortcuts, and widget stops are logged accurately instead of as "Stopped
  manually".
- Assorted correctness and accessibility fixes, and a house-rule copy pass.

### Under the hood

- Fewer per-second system reads on the common configuration, and a leaner
  internal structure (no behavior change).

## 1.6.0

- **Gaming trigger.** A "Playing a game" condition: stay awake while a game
  is in front. Detects apps that declare a games category, anything running
  from a Steam library (many Steam games skip the declaration), and the
  cloud and game-streaming clients: GeForce NOW, Boosteroid, Parsec,
  Moonlight, Shadow. A five-minute grace means alt-tabbing to Discord or a
  walkthrough doesn't drop the session.
- **Gaming & Streaming Setup.** A new window from the menu, answering "why
  does my stream or cloud game stutter every second". macOS hops the Wi-Fi
  radio off-channel for AWDL (AirDrop, Handoff, Sidecar) about once a
  second, which shows up as 50 to 100 ms ping spikes; the window has a
  built-in jitter test that pings for ten seconds and says in plain words
  whether your connection is clean, congested, or showing exactly that
  once-a-second AWDL signature.
- **AWDL pause.** The fix, session-scoped and no daemon: a toggle keeps AWDL
  off while Keepresso runs, restoring everything (AirDrop, Handoff, Sidecar,
  Continuity Camera) the moment you turn it off or quit, even after a crash.
  Your password is needed once per launch; after that the switch is instant.
  An optional automatic mode pauses AWDL while a game is keeping the Mac
  awake and resumes it when you stop playing.
- **Radio hygiene checks.** The same window checks your setup: wired network
  available (the most reliable fix), Wi-Fi channel alignment with AWDL's
  social channels (149 in the US, 44 most elsewhere, at 80 MHz) with a
  warning on 2.4 GHz, Bluetooth sharing the radio, plus plain-language notes
  on Game Mode (it turns on by itself when a game runs full screen) and
  cloud gaming in the browser (Xbox Cloud Gaming has no app to detect; the
  Audio playing condition covers it). No permission prompts anywhere on this
  screen.
- **Cloud Gaming and Remote Control presets.** Cloud Gaming pairs the gaming
  condition with the GeForce NOW and Boosteroid apps so queueing and
  downloads keep the session alive. Remote Control stays awake while you're
  actively driving another machine over TeamViewer, AnyDesk, or Parsec,
  deliberately only while the app is in front, so a host idling in the
  background never pins your Mac awake.
- **Tidier condition menu.** Adding a trigger condition is now three grouped
  menus (Power & Display, Network & Devices, Apps & Activity) instead of one
  long scrolling list.

## 1.5.0

- **Desktop widgets.** Keepresso on the desktop (and in Notification Center),
  in the brand's caramel-on-roast look with the real cup mark. The small
  widget is a one-tap toggle: the cup fills and steams while brewing, with a
  live countdown for timed sessions. The medium widget adds Start/Stop and
  Pause/Resume Triggers buttons next to the status. Widgets work on macOS 14
  and later; the buttons drive the running menu-bar app.
- **Control Center toggle (macOS 26).** A Keep Awake control for Control
  Center, wearing the brand cup as a custom symbol. Flipping it starts or
  stops the session, launching Keepresso first if it isn't running.
- **Bluetooth device trigger.** Stay awake while a chosen paired device
  (headphones, a keyboard, a controller) is connected; the condition menu
  lists your paired devices. A 30 second release grace rides out the brief
  drop when a device hops between hosts. Uses the system Bluetooth
  permission; the Setup screen warns if a saved rule lacks it.
- **Calendar trigger.** Stay awake while a calendar event is in progress,
  covering scheduled sessions the camera/mic conditions can't see. All-day
  events never count (a birthday shouldn't keep the Mac up for 24 hours).
  Needs full calendar access, requested with one click from the condition
  menu.
- **Restore default presets.** Deleted a built-in preset? The preset menu's
  new "Restore default presets" brings back the missing ones, leaving your
  own and renamed presets untouched.

## 1.4.0

- **Camera and microphone triggers, with a Meetings preset.** Stay awake
  while anything is using the camera or the mic: the same device state that
  drives the menu bar's green dot, read without ever touching the stream, so
  there is no permission prompt. One rule covers every meeting app at once,
  including calls running in a browser tab that app rules can't see. A new
  built-in Meetings preset (camera or mic) sets it up in one click.
- **Audio-playing trigger.** Stay awake while sound is playing: music, a
  video, a podcast. A 30 second release grace rides out track gaps and brief
  pauses so the session doesn't flap.
- **VPN trigger.** Stay awake while a VPN is connected, covering profile
  VPNs (IKEv2, L2TP) and Network Extension tunnels (WireGuard, Tailscale,
  OpenVPN Connect, corporate clients).
- **Activity pane: why is my Mac awake?** Preferences ▸ Activity shows every
  app's live power assertions (the readable version of
  `pmset -g assertions`), so you can see exactly what's preventing sleep,
  whoever's doing it, plus a decision log of why each Keepresso session
  started or stopped: which trigger, a timer expiring, the battery pause, or
  a manual or scripted command.
- **Brand cup in the menu bar.** The menu bar icon is now the actual brand
  mark (espresso cup with the crema stripe, handle, saucer, and steam), drawn
  as a crisp template image: filled with steam while brewing, an outline while
  idle. The dropdown header uses the same cup, so the mark matches from the
  bar to the app icon. The stock SF Symbol cup (and its shimmer, the one
  animation the snapshotted label allowed) is gone.
- **Readable glass on any wallpaper.** The menu panel and the glass windows
  (Preferences, Setup, About) now layer a subtle blur-and-tint plate under
  their content, so text stays sharp over very dark or busy desktops while
  the surfaces still read as Liquid Glass.

## 1.3.0

- **Shortcuts actions.** Keepresso now shows up in the Shortcuts app (and
  Spotlight/Siri) with Start Keeping Awake (optionally for N minutes), Stop
  Keeping Awake, and Toggle Keep Awake, no URL scheme fiddling required.
  They behave exactly like `keepresso://` commands, pausing triggers first
  so the action sticks.
- **Any duration, or until a time.** The menu's duration control now takes a
  custom duration (hours and minutes) alongside the presets, and "Until a
  Time" starts a session that ends at a wall-clock time, later today or
  tomorrow if it already passed. Scripts get the same power with
  `keepresso://start?until=18:00`.
- **Schedule trigger.** A new condition type: a daily time window on the days
  you choose, like weekdays 9:00-18:00 or an overnight 22:00-6:00 that runs
  past midnight. Add it from the condition menu (Work hours and Overnight
  starting points included) and tune the times and days in place.
- **CPU-load trigger.** Stay awake while the machine is actually working: a
  condition that holds while smoothed overall CPU usage sits above a chosen
  threshold (25/50/75/90%). Long builds, renders, and training runs keep the
  Mac up; a momentary spike doesn't, and usage hovering at the threshold
  doesn't flap the session on and off.
- **Volume trigger.** Stay awake while a chosen external drive, SD card, or
  network share is mounted; the condition menu lists what's mounted right
  now. Pairs naturally with disk keep-alive: one holds the Mac awake while
  the drive is there, the other keeps the drive spinning.
- **Three new built-in presets.** Remote Session (SSH) keeps the Mac awake
  only while someone is actually connected over SSH (not while the idle
  listener runs), Backup Running holds it through an in-flight Time Machine
  backup, and Media Render covers ffmpeg jobs. Existing users get the new
  presets once; deleted presets stay deleted.
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
