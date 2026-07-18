<p align="center">
  <img src="docs/assets/icon.png" width="128" height="128" alt="Keepresso app icon">
</p>

<h1 align="center">Keepresso</h1>

<p align="center">
  Keep your Mac awake, on your terms, with smart triggers, presets, timed
  sessions, and closed-display mode in a clean, native menu-bar app, built on a
  modern foundation for the next decade of computing.
</p>

<p align="center">
  <a href="https://github.com/gyorgysh/keepresso/actions/workflows/ci.yml"><img src="https://github.com/gyorgysh/keepresso/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-orange" alt="Swift + SwiftUI">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPLv3-green" alt="GPL-3.0 License"></a>
</p>

---

Keepresso is a native **Swift + SwiftUI** menu-bar app. It uses macOS power
assertions (`IOPMAssertion`) to prevent system and display sleep, and layers on
condition-based **triggers** so your Mac only stays awake when it actually should.
It lives quietly in the menu bar, no Dock icon, no clutter.

<p align="center">
  <img src="docs/assets/menu_idle.webp" width="250" alt="Keepresso menu brewing indefinitely, with the keep-awake toggle, duration picker, and Stop-in buttons">
  &nbsp;
  <img src="docs/assets/menu_countdown.webp" width="250" alt="Keepresso brewing a timed session, with a live countdown and one-tap Stop-in buttons">
  &nbsp;
  <img src="docs/assets/menu_trigger.webp" width="250" alt="Keepresso brewing because a trigger condition is met, with the live condition list">
</p>

## Features

- ☕ **Keep awake, your way.** Prevent system sleep and/or display sleep as
  independent toggles, indefinitely, for a timed session (presets or any custom
  duration), or **until a wall-clock time** ("until 18:00", today or tomorrow).
- 🌙 **Yield the screen saver.** Let the screen saver or display sleep kick in
  after _N_ minutes idle while the system itself stays awake.
- 🟢 **Keep me active (defeat idle detectors).** A plain power assertion keeps the
  Mac awake but doesn't reset app-level or enterprise idle detection. Optionally
  tell macOS you're active too, so remote-desktop and VDI sessions, meeting
  presence (Teams, Slack), and corporate idle-logout don't mark you away. It only
  steps in once you've been idle a few seconds, so it never nudges the pointer
  while you're using the Mac or gaming. Off by default, and prompt-free (no
  Accessibility permission).
- ⚡ **Trigger engine.** Stay awake only while charging or on battery, an external
  display is connected, you're on a chosen Wi-Fi network, **a VPN is
  connected**, the **camera or microphone is in use**, **audio is playing**, a
  chosen **Bluetooth device is connected** (headphones, a controller), a
  **calendar event is in progress**, a specific app or process is running, a
  chosen **volume is mounted**, **CPU usage** sits above a threshold (builds,
  renders, training runs), **network throughput** stays above a threshold (a
  large download, upload, or sync), a **download is in progress** in a folder you
  choose (keep awake until it finishes), **a game is in front**, or during a
  **scheduled time window** (weekdays 9:00-18:00, overnight hours). Combine
  conditions with **any** (OR) or **all** (AND). A one-click "Pause Triggers"
  in the menu bar stops brewing without touching your rules.
- 🤖 **Agent-aware.** The "AI agent is working" condition keeps the Mac awake
  while a coding agent (claude, codex, gemini, grok, aider, goose, and friends)
  is actually working, and lets it sleep once every session goes quiet, after a
  grace you choose. Agents that stream a transcript to disk prove their work
  directly, even through long zero-CPU network waits; the rest are judged on the
  CPU of their processes and tool calls against each session's own learned idle
  level. **Claude Code** can report its state exactly, via an opt-in hook
  integration you install in one click: a session is working when Claude says it
  is, a pending permission prompt counts as working (so the Mac waits for your
  answer), and background subagents count too. The menu lists every session with
  a live working / idle state and where it runs.
- 🔐 **Explicit Agent wake leases.** Codex, Claude Code, Gemini CLI, and other
  agents can acquire, heartbeat, and release a bounded wake lease through the
  CLI, bundled Skill, or local MCP server. Leases compose across concurrent
  agents, so Keepresso sleeps only after the final task releases. TTL and maximum
  lifetime watchdogs recover from crashes and forgotten cleanup, while the
  Activity pane keeps a prompt-free structured audit trail.
- ⏰ **Unattended Codex automations.** Keepresso can follow enabled local Codex
  schedules, wake the Mac five minutes early, hold a system assertion, wait for
  power, battery, network, and the Codex app, then hand ownership to the Agent's
  explicit lease. When the final lease completes or the handoff times out, it
  restores normal sleep and sleeps the Mac. The screen is locked and turned off
  by default while background work continues.
- ⏹️ **Stop in 15, one click.** A row of quick "Stop in" buttons (15 min, 30 min,
  1 h out of the box, editable) turns a running session into a timed one, so the
  Mac goes back to sleeping on its own without you remembering to toggle off.
  Optionally get a heads-up a few minutes before any timed session ends.
- 🎥 **Never sleeps mid-meeting.** The camera/microphone conditions catch every
  meeting app at once, including calls running in a browser tab, and read only
  the device's in-use state (the green-dot signal), never the stream, so no
  camera or microphone permission is ever requested.
- 🎮 **Game-aware.** The "Playing a game" condition spots apps that declare a
  games category, anything running from a **Steam** library (many Steam games
  skip the declaration), and the cloud and game-streaming clients: **GeForce
  NOW, Boosteroid, Parsec, Moonlight, Shadow**. A five-minute grace means
  alt-tabbing to Discord doesn't drop the session.
- 📶 **Gaming & Streaming Setup.** macOS hops the Wi-Fi radio off-channel for
  AWDL (AirDrop, Handoff, Sidecar) about once a second, which shows up as
  50-100 ms ping spikes mid-game or mid-stream. A dedicated window diagnoses
  it with a built-in **jitter test**, and fixes it with a session-scoped
  **AWDL pause**: no password at all with the administrator helper installed
  (once per launch without it), instant toggling, and everything restores
  itself the moment you stop (even after a crash). An
  **automatic mode** watches for a game (or a cloud-gaming app) on its own with
  no trigger setup, authorizes once up front so it never pops a password dialog
  over a running game, and shows a live status with a grace countdown when a
  game closes. Optional notifications when it pauses and resumes. Plus
  radio-hygiene checks: wired network, Wi-Fi channel alignment with AWDL's
  social channels (44 in the EU, 149 in the US and Canada), Bluetooth, Game Mode.
- 🎛️ **Presets.** Apply a named trigger bundle in one click, built-in (AI Agent,
  Meetings, Cloud Gaming, Remote Control, On AC Power, External Display
  Connected, Remote Session (SSH), Backup Running, Media Render) or your own
  saved rule sets. Deleted a built-in? "Restore default presets" brings it back.
- 👋 **First-run setup.** A welcome window on a new Mac points out that Keepresso
  lives in the menu bar (no Dock icon) and sets you up in one click for how you
  work: agentic coding, gaming and streaming, meetings and calls, or remote
  access. Reopen it any time from Preferences.
- 🧩 **Desktop widgets and a Control Center toggle.** A small widget that's a
  one-tap toggle (the brand cup fills and steams while brewing, with a live
  countdown), a medium widget with Start/Stop and Pause/Resume Triggers
  buttons, and on macOS 26 a Keep Awake control for Control Center.
- 🔍 **Awake explainer.** The Activity pane shows every app's live power
  assertions, a readable `pmset -g assertions`, so you can see exactly what's
  preventing sleep (whoever's doing it), a seven-day held-awake summary, and a
  decision log of why each Keepresso session started or stopped that survives
  relaunch. The menu bar even names another app that's holding the Mac awake
  ("Held by Google Chrome") when Keepresso itself is idle.
- 🪪 **Auto app detection.** Caffeinate while listed apps run or are frontmost,
  with an optional grace period before it lets go.
- 🔋 **Battery-aware auto-pause.** Let the Mac sleep once charge drops below a
  threshold you choose, even mid-session, so it never runs the battery flat.
- 🌡️ **Thermal safety net.** Holding a Mac awake through heavy load can also
  hold in the heat, so Keepresso can watch it: macOS's own thermal pressure
  (works on every Mac) or specific temperature sensors picked from a live
  list. If the reading stays over your threshold for a sustained time it
  escalates, first (optionally) boosting the fans to a chosen strength, never
  below what the system already chose, then pausing the session so the Mac
  can cool, with a notification saying why. Everything restores itself once
  temperatures recover. A built-in **"Test Fans"** check proves the fan path
  end to end in about 12 seconds ("All good. Fan 1: 0 → 4800 rpm"), so you
  can trust the boost before a heavy render needs it. Watching and pausing
  work everywhere. The fan boost runs through the administrator helper, so
  it's silent and never prompts.
- ⏱️ **Menu-bar countdown.** An optional live countdown next to the cup icon for
  timed sessions.
- ⌨️ **Global hotkey.** A system-wide keyboard shortcut to toggle keep-awake from
  any app, recorded in Preferences (Carbon-based, so no Input Monitoring or
  Accessibility permission).
- 🚀 **Start on launch.** Optionally begin a keep-awake session the moment
  Keepresso launches, for an always-on Mac that shouldn't need a rule.
- 💾 **Export and import.** Back up your settings, triggers, and presets to a JSON
  file, or move them to another Mac, from Preferences > General. The file is
  version-stamped and validated on import.
- 🔗 **Shortcuts and URL scheme.** Native Shortcuts actions (Start, Stop,
  Toggle) for Shortcuts, Spotlight, and Siri, plus a URL scheme for Raycast,
  Alfred, or a shell script: `keepresso://start?duration=60`,
  `keepresso://start?until=18:00`, `stop`, or `toggle`.
- 💻 **Closed-display mode.** Keep running with the **lid shut** and no external
  display, on power or battery, for an always-on Mac or one you carry mid-task.
  The screen itself turns off when the lid closes, so it's not sitting lit
  inside a closed lid. An optional **"Only while brewing"** mode ties it to the
  session instead of leaving it on globally: on when a keep-awake session
  starts, off when it ends (or the app quits, even after a crash). This scoped
  automatic mode requires the administrator helper, whose durable journal can
  restore the exact original setting after an app crash, helper restart, or
  Mac reboot. The persistent manual switch still has a one-time password
  fallback.
  A thermal stop temporarily permits sleep inside the same scoped transaction,
  then restores the exact manual and automatic ownership after cooling.
- 🔑 **One password, ever.** An optional **administrator helper**, a small
  system service installed from Preferences > General (or the welcome screen),
  handles the privileged switches for Keepresso: closed-display mode, the
  thermal fan boost, and the AWDL pause become instant and silent, with no
  password prompt on any launch. macOS asks for your password once, when you
  approve the helper under Login Items, and the approval survives restarts
  and updates, and app updates replace the service automatically, never a
  reinstall. The helper can only flip those specific switches, restores
  everything if the app quits or crashes, puts the `keepresso` CLI on PATH
  for DMG installs, and can be removed at any time. Without it, persistent
  manual switches can still use the announced password fallback. Scheduled
  wake, scoped closed-lid automation, unattended Agent work, and thermal fan
  boost stay disabled because background safety and recovery must never rely
  on a password prompt or a non-durable restore snapshot.
- 🔔 **Reminders, end actions, and event hooks.** A "still brewing" notification
  (with an optional sound) after _N_ minutes, one-time or recurring, so a
  forgotten session can't quietly drain the battery. When a session ends on its
  own (a timer expiring, triggers dropping), optionally notify, then sleep the
  display, lock the screen, start the screen saver, or sleep the Mac. And when
  something happens (session start/end, trigger fire/release, agent went idle,
  thermal stage, battery pause), run a Shortcut, POST a webhook, or a shell
  command, handy for a push to your phone when an overnight agent finishes.
  Schedule a system wake through the administrator helper and optionally start
  keep-awake when the Mac comes back (wake, work, sleep).
- 💽 **Disk keep-alive.** Periodic no-op disk I/O to stop an external drive or NAS
  from spinning down.
- 🖥️ **Headless Setup checklist.** Probes the system settings an always-on,
  headless Mac needs (sleep, auto-restart, auto-login, FileVault, remote access)
  and guides you to fix each one.
- 🖼️ **Headless virtual display (experimental).** On a Mac with no monitor,
  create a higher-resolution HiDPI virtual display so Screen Sharing and VNC look
  crisp instead of a fuzzy 1920×1080. Off by default; uses a private macOS API,
  so it's a no-dummy-plug software alternative you should treat as experimental.
- ✨ **Native and quiet.** A menu-bar agent with an animated cup while brewing, a
  live summary of what's holding the session on, a Liquid Glass app icon (Icon
  Composer, with light, dark, and tinted appearances), and Liquid Glass window
  styling on macOS 26+. The dropdown's glass is yours to tune, from frosty to
  fully clear (Preferences > General > Appearance).
- 🌍 **Fifteen languages.** English, German, Spanish, French, Hungarian, Italian,
  Japanese, Korean, Russian, Brazilian Portuguese, Turkish, Polish, Ukrainian,
  Simplified Chinese, and Traditional Chinese, across the menu, every window,
  notifications, VoiceOver labels, and the widgets. Pick one in Preferences or on
  the Welcome screen, or follow the system language (the default).
- ⬆️ **Self-updating.** Built-in auto-updates via [Sparkle](https://sparkle-project.org),
  with an EdDSA-signed appcast on GitHub Releases.

## Screenshots

<table>
<tr>
<td align="center" width="50%">
  <img src="docs/assets/prefs_general.webp" width="320" alt="Preferences: General tab with keep-awake toggles, startup, a global shortcut, and the app language"><br>
  <sub>General: keep-awake toggles, launch at login, a global shortcut, your language</sub>
</td>
<td align="center" width="50%">
  <img src="docs/assets/prefs_triggers.webp" width="320" alt="Preferences: the Triggers tab with presets and a rule list of AI agent working, AC power, playing a game, and CPU conditions"><br>
  <sub>Trigger engine: combine conditions with any or all, or apply a preset</sub>
</td>
</tr>
<tr>
<td align="center" width="50%">
  <img src="docs/assets/prefs_activity.webp" width="320" alt="Preferences: Activity tab listing live power assertions and session decisions"><br>
  <sub>Awake explainer: every app's live power assertions, plus why each session started or stopped</sub>
</td>
<td align="center" width="50%">
  <img src="docs/assets/prefs_display.webp" width="320" alt="Preferences: experimental headless virtual display"><br>
  <sub>Headless virtual display: crisp Screen Sharing on a Mac with no monitor</sub>
</td>
</tr>
<tr>
<td align="center" colspan="2">
  <img src="docs/assets/prefs_conditions.webp" width="320" alt="Preferences: the Triggers tab with an Add row grouping power and display, network and devices, and apps and activity conditions, and Claude Code connected"><br>
  <sub>Adding a condition: grouped menus for power and display, network and devices, apps and activity, with Claude Code connected</sub>
</td>
</tr>
</table>

## Built for the agentic era

**The only app you'll ever need for a headless Mac setup**, whether it's running
AI agents, a server, a render farm, or anything reachable over HTTP or SSH.
Keepresso fits the way Macs are used now, and where they're headed:

- 🤖 **AI agents.** Keep a Mac awake and reachable so agents can operate it around
  the clock without it dozing off mid-task.
- 💻 **MacBooks on the go.** Closed-display mode keeps work running on power or
  battery while you pack up and move.
- 🧑‍💻 **Builders and vibe coders.** Long builds, training runs, and overnight jobs
  finish instead of getting cut short by sleep.
- 🏢 **Business and enterprise, no charge.** Headless Mac minis and Mac Studios
  powering local LLMs, agent fleets, CI, or a render farm stay up without a
  license fee.
- 🎬 **Studios.** Long renders and exports run to completion, untended.
- 🎮 **Gamers and streamers.** Sessions stay awake while you play (native,
  Steam, or cloud), and the AWDL pause smooths out the once-a-second ping
  spikes that stutter cloud gaming and live streams.

The use cases are effectively limitless. Modern UI, a solid and well-tested
foundation, and a quiet must-have for the next decade of computing.

## Install

**Homebrew:**

```sh
brew install --cask gyorgysh/keepresso/keepresso
```

**Manual:** download the latest signed, notarized DMG from
[Releases](https://github.com/gyorgysh/keepresso/releases), drag **Keepresso** to
Applications, and launch it.

Either way, Keepresso keeps itself up to date from there.

## Using Keepresso

Click the cup in the menu bar to open Keepresso. Right-click (or control-click)
it for a compact context menu with the app entries: Preferences, Headless
Setup, Gaming & Streaming, About, Check for Updates, and Quit.

- **Quick toggle.** Flip **Keep awake** on or off and pick a duration:
  indefinitely, a preset (15 minutes, 1 hour, 4 hours), any custom duration, or
  until a time of day. The cup fills and animates while brewing.
- **Show less.** The disclosure row at the bottom of the panel folds the option
  toggles and app entries away, leaving just the status and the keep-awake
  controls. Keepresso remembers the choice, and everything hidden stays
  reachable from the right-click menu.
- **Keep awake with lid closed.** Toggle it right from the menu before you shut
  the lid or unplug. It flips a system setting (`pmset disablesleep`), so it
  needs administrator rights: silent with the helper installed, one password
  ask without it. Works on power or battery; turn it off when you're done, on
  battery in a bag it can drain and heat up. Or set it to **"Only while
  brewing"** in Preferences > General and it follows the session on its own:
  on at session start, off at session end or app quit.
- **Preferences** (⌘,) holds the set-and-forget configuration, in tabs:
  - **General**: what to keep awake, the administrator helper, menu-bar
    countdown, battery auto-pause, closed-display mode, launch at login,
    settings backup (export/import), and the welcome screen.
  - **Triggers**: turn on rule-based activation, apply a preset, and build your
    rule set.
  - **Reminder**: a one-time or recurring "still brewing" alert, with a sound,
    plus end notifications and the ending-soon warning.
  - **Automation**: end-of-session actions, outbound event hooks, and scheduled
    wake (with optional wake-and-brew).
  - **Disk**: choose a volume to keep spun up and how often to touch it.
  - **Display**: create an experimental high-resolution headless virtual display.
  - **Activity**: what's keeping the Mac awake right now, a weekly held-awake
    summary, and why each session started or stopped (persisted across relaunch).
- **Headless Setup** checks that an always-on Mac (say a Mac mini with no display)
  is configured to stay reachable, and links you straight to the right settings.
- **Gaming & Streaming** diagnoses the once-a-second Wi-Fi lag spikes AWDL
  causes (jitter test), pauses AWDL for the session with one toggle, and
  checks the radio hygiene around it: wired network, Wi-Fi channel, Bluetooth,
  Game Mode.

Keepresso has no Dock icon by design. Everything lives in the menu bar.

### Driving it from Shortcuts or a script

Keepresso ships native **Shortcuts actions**: Start Keeping Awake (optionally
for _N_ minutes), Stop Keeping Awake, and Toggle Keep Awake, usable from the
Shortcuts app, Spotlight, and Siri.

It also registers a `keepresso://` URL scheme so Raycast, Alfred, or a shell
script can start or stop a session without opening the menu:

```
open "keepresso://start"              # indefinite session
open "keepresso://start?duration=60"  # timed session, in minutes
open "keepresso://start?until=18:00"  # until a wall-clock time (24h HH:MM)
open "keepresso://stop"
open "keepresso://toggle"
```

Either way, if triggers are on they pause first (same as the menu's Pause
Triggers), so the command actually takes effect.

### The `keepresso` command-line tool

The app bundle ships a caffeinate-style CLI. The Homebrew cask links it onto
your PATH; on a DMG install, the administrator helper creates the
`/usr/local/bin/keepresso` link for you. It drives the app for session
commands and can also hold its own assertion when you need to block in a
pipeline:

```sh
keepresso start --for 90     # tell the app to brew for 90 minutes
keepresso stop               # end the session
keepresso status             # exit 0 awake, 1 not, 2 app not running
keepresso status --json      # machine-readable, jq-friendly

keepresso -t 3600            # hold an assertion itself for an hour
keepresso -w $!              # stay awake until a process exits
keepresso -d -i              # also keep the display awake, until Ctrl-C
keepresso -u                 # wake the display now
```

The standalone holds work even when the app is not running; `keepresso help`
lists everything. Installed from a DMG instead of Homebrew? Symlink it
yourself: `ln -s /Applications/Keepresso.app/Contents/Helpers/keepresso /usr/local/bin/`.

### Agent wake leases, Skill, and MCP

An Agent should declare its lifecycle instead of asking Keepresso to infer it
from a process name, CPU use, or log activity. A minimal shell lifecycle is:

```sh
lease_request_id="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
lease_json="$(keepresso lease acquire \
  --lease-id "$lease_request_id" \
  --owner "$USER" --agent codex --task "nightly-refactor" \
  --ttl 300 --max-lifetime 14400)"
lease_id="$(printf '%s' "$lease_json" | \
  /usr/bin/plutil -extract lease.id raw -o - -)"

keepresso lease heartbeat "$lease_id" --ttl 300
keepresso lease release "$lease_id" --result success
```

Every command returns a stable JSON envelope. A lease heartbeat extends its TTL
but never its absolute maximum lifetime. Release only the ID owned by the current
task. Reusing the same caller-generated UUID with the exact acquire request is
safe after a lost response and returns the original active lease. Other agents
remain protected independently.

The app also embeds:

- `Keepresso.app/Contents/Helpers/keepresso-mcp`, a local stdio MCP server with
  `acquire_wake_lease`, `renew_wake_lease`, `heartbeat_wake_lease`,
  `release_wake_lease`, `list_wake_leases`, and `wake_status` tools.
- `Keepresso.app/Contents/Resources/keepresso-power`, a Codex-compatible Skill
  containing the complete acquire, heartbeat, and cleanup workflow.

Preferences > Automation shows the exact MCP path and can reveal the bundled
Skill. It can also follow enabled local Codex automations. Install and approve
the administrator helper before relying on scheduled wake or lid-closed work.
See [Agent power orchestration](docs/AGENT_POWER.md) for setup and recovery
details.

## Why not the Mac App Store?

The App Sandbox blocks the `IOPMAssertion` power APIs Keepresso depends on, so
it's distributed **outside** the store, as a direct, notarized DMG download.

## Building from source

Keepresso uses **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** to generate
the Xcode project from [`project.yml`](project.yml) (the `.xcodeproj` is **not**
checked in), and **Swift Package Manager** for the testable core
([`KeepressoCore`](Sources/KeepressoCore)).

**Requirements:** macOS 14+, Xcode 26+ with the macOS 26 SDK, and `xcodegen`
(`brew install xcodegen`). The deployment target remains macOS 14; APIs added
later are runtime availability-gated in the built app.

```sh
git clone https://github.com/gyorgysh/keepresso.git
cd keepresso

./scripts/run.sh            # generate the project and open it in Xcode (⌘R to run)
```

### Working on the core logic

The sleep-control state machine lives in `KeepressoCore` and is fully unit
tested, independent of any UI:

```sh
swift build      # build the core library
swift test       # run the test suite (requires the full Xcode toolchain)
```

### How it works

Two layers, by design:

- **`KeepressoCore`** is a SwiftUI-free SwiftPM library: the `SessionController`
  state machine plus protocol seams over every system touchpoint (power
  assertions, power source, displays, network, workspace, disk, notifications).
  This is where behavior lives and where the tests are.
- **`Keepresso`** is the thin SwiftUI `MenuBarExtra` app: views and lifecycle
  glue wired to the real system backends.

The controller doesn't run its own timer; the app ticks it once a second. Tests
advance a fake clock and inject fakes for the system seams, so the logic is
verified without touching real hardware.

### Scripts

- `scripts/run.sh`: generate the project and open it in Xcode.
- `scripts/make-icon.swift`: regenerate the app icon asset catalog.

See [docs/BUILDING.md](docs/BUILDING.md) for a full build walkthrough and
[CLAUDE.md](CLAUDE.md) for the architecture and contributor workflow.

## Contributing

Issues and pull requests are welcome. New behavior goes in `KeepressoCore` behind
a protocol seam with tests, then a thin SwiftUI layer in the app.

## License

[GNU GPL v3.0](LICENSE) © 2026 Keepresso contributors.

Keepresso is free software: use it, study it, fork it, and contribute back. The
copyleft terms mean any distributed version (including forks and modifications)
must stay open-source under the same license, so nobody can take it closed and
ship a proprietary product from it.

If Keepresso is useful to you, you can [support its development](https://gyorgy.sh/donate).
