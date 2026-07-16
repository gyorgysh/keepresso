# Changelog

All notable changes to Keepresso are documented here, grouped by release.
Versions follow [Semantic Versioning](https://semver.org).

## [1.14.0] - 2026-07-16

Theme: Keepresso learns when your AI agent is actually working.

### Added

- **Stop in 15, one click.** While a session runs, the menu shows a row of quick
  "Stop in" buttons (15 min, 30 min, 1 h out of the box) that convert the running
  session to end that much later, so the Mac goes back to sleeping on its own and
  you don't have to remember to toggle it off. The countdown continues the
  session rather than restarting it, clicking another button simply replaces the
  countdown, and the durations are editable (up to four) in Preferences ▸
  General. An optional heads-up in Preferences ▸ Reminder warns you a few minutes
  before any timed session ends.
- **A trigger that knows when your AI agent is actually working.** The new
  "AI agent is working" condition (Preferences ▸ Triggers ▸ Add ▸ Apps &
  Activity) detects coding-agent sessions (claude, codex, gemini, grok, agy,
  aider, goose, and friends) in your terminals and keeps the Mac awake only
  while one is actually working. Where an agent streams a session transcript
  to disk (claude, grok, codex), a fresh write counts as direct proof of
  work, even through long zero-CPU network waits; everywhere else the
  decision uses the CPU of the agent's processes and tool calls, measured
  against each session's own learned idle level, so a TUI that animates
  while idle and a near-silent one are both judged fairly. Once every
  session goes idle, the Mac may sleep after a configurable grace
  (instantly, 1, 5, or 10 minutes) with a gaming-style countdown in the
  menu. The menu lists each detected session with a live working / idle
  state, and the built-in "AI Agent" preset now applies this rule instead
  of its old process-name rules, so an agent left open no longer pins the
  Mac awake around the clock.
- **Claude Code can tell Keepresso exactly what it's doing.** An opt-in
  integration (Preferences ▸ Triggers ▸ the AI agent rule) installs Claude Code
  hooks that report each session's real state, so there's no guessing from CPU
  at all: a session is working when Claude says it is, and at rest when it says
  that. A pending permission prompt counts as working, so the Mac stays awake
  while it waits for your answer, but an abandoned prompt settles back to rest
  instead of pinning the Mac awake forever. Sessions are listed by where they
  run ("claude (Claude app)", "claude (IDE)", or the terminal), and background
  subagents count as work even when the main turn has ended.
- **The menu panel does more, in less space.** The low-battery pause moved out
  of Preferences and into the menu, as a switch with an inline 10-90% slider
  that shows the level you're picking (it only commits when you let go, so
  dragging past the current charge can't stop your session). "Only while
  brewing" joins it, the lid-closed and battery rows appear only on machines
  with a battery, and small (i) buttons explain what each one does. Every switch
  in the app now lines up flush right at one size, in the menu, the Gaming &
  Streaming window, and the welcome screen. Working sessions pulse with Claude
  Code's console spinner, in Claude's terracotta for Claude rows and green for
  other agents.
- **Preferences reads as one window.** The Triggers tab is now a grouped form
  like every other tab, with its own Triggers and Presets sections. Every tab
  leads with a section header (Reminder, Disk, Presence, Menu bar, Battery,
  Welcome), and General is ordered by what you reach for most: Startup, the
  global shortcut, and Language right under Keep awake, hardware-specific
  settings further down, maintenance last. The battery threshold is the same
  slider as the menu's, so the two always agree.

### Fixed

- **Built-in presets keep up with updates.** An improved built-in preset (the
  AI Agent preset gaining the new working rule) never reached you if an older
  version had already seeded it, so the welcome screen and the presets menu
  offered two different rule sets under one name. Un-renamed built-ins now
  refresh to their current definitions on launch. Renamed ones are yours and
  stay untouched, deleted ones stay deleted.
- **Windows opened from the menu are properly in front.** A window opened from
  the menu bar could come up half active, drawn in the inactive gray style with
  clicks inside it doing nothing until you switched away and back. Keepresso now
  detects that state and repairs it.

## [1.13.0] - 2026-07-12

Theme: Keepresso now speaks fifteen languages.

### Added

- **Keepresso speaks fifteen languages.** English, German, Spanish, French,
  Hungarian, Italian, Japanese, Korean, Russian, Brazilian Portuguese, Turkish,
  Polish, Ukrainian, Simplified Chinese, and Traditional Chinese. A Language
  picker in Preferences and on the Welcome screen switches between them, or
  follow the system language (the default). Everything is translated: the menu,
  the Setup and Gaming & Streaming screens, notifications, VoiceOver labels, and
  the desktop widgets.
- **The battery pause explains itself.** When Keepresso pauses a session because
  the battery ran low, it now says so in a notification (the charge level, and
  that plugging in resumes it) instead of just going quiet. The menu-bar cup
  shows the pause as a last sip of coffee in the system's low-power yellow, and
  the dropdown's cup matches. Desktops with no battery hide the battery controls
  entirely.
- **Readiness rows lead with their subject.** Each row on the Setup and Gaming &
  Streaming screens now opens with its own icon (Wi-Fi, Ethernet, game
  controller, lock, bell) tinted by its status, with a small corner badge so ok,
  tip, and warning still read by shape.

### Fixed

- **Clicking a notification no longer opens a second Keepresso.** A click on one
  of Keepresso's notifications could make macOS launch a duplicate copy that ran
  alongside the first, each holding its own power assertions. A launch that finds
  an older copy of itself already running now hands back to it and quits.
- **The welcome window comes back until you press Get Started.** Switching your
  language on the Welcome screen (which relaunches the app) no longer counts as
  finishing onboarding, so the welcome returns on each launch until you confirm
  in the language you settled on.
- **Old copies stuck in the Trash are handled properly.** When an update leaves a
  previous copy in the Trash and macOS blocks Keepresso from removing it,
  Keepresso now posts a notification you can click to open the Trash and delete
  it yourself, instead of letting the leftover copy quietly disable the
  background helper.

## [1.12.0] - 2026-07-09

Theme: a livelier cup, and updates that clean up after themselves.

### Added

- **The cup now pours.** Starting a session fills the menu panel's cup with
  a short pour animation, the steam rising once the pour lands, and stopping
  drains it. The welcome window leads with the same brewing cup and pours it
  the moment you pick how you use your Mac.
- **The menu panel moves like it means it.** Countdowns roll their digits
  like a timer, trigger checkmarks swap in place, and the panel morphs
  smoothly between its states instead of jump-cutting. Everything respects
  the system's Reduce Motion setting.
- **Liquid Glass, where it belongs.** On macOS Tahoe the primary buttons and
  the accented cards use the real glass material with the same warm copper
  tint everywhere; earlier systems keep the familiar frosted look.
- **Readable on ultra-dense screens.** On native 4K/5K resolutions and
  laptop More Space modes, where a point is physically tiny, the menu panel
  and the welcome window scale their text and layout up based on the
  screen's actual density. Normal configurations are untouched.
- **Windows open where you expect.** Preferences, Setup, Gaming & Streaming,
  About, and the welcome open centered and in front now, instead of wherever
  macOS last left them (or behind the app you were using), and they don't
  stay on top of anything afterwards.

### Fixed

- **Updates remove the old app copy properly.** The previous version that an
  update pushes into the Trash is now deleted before Keepresso first talks
  to macOS's background-task records, closing the last gap that could get
  the helper disabled after an update (previously that could take a manual
  Trash empty).
- **The helper hands off cleanly across updates.** The app no longer keeps
  the old helper process serving after an update: the freshly installed
  binary takes over within moments, and anything the helper was holding
  carries over without a password prompt.
- **The welcome window fits every screen.** On low resolutions it scrolls
  inside the visible screen, with a clear "more below" cue and the Get
  Started button always in view, instead of running off under the Dock; it
  also adapts when the resolution changes while Keepresso is running.
- **The Triggers tab sits left like every other tab** instead of floating
  centered while the trigger switch is off.

## [1.11.2] - 2026-07-09

Theme: the helper stays on.

### Fixed

- **The helper's background switch no longer keeps turning itself off.** Old
  copies of Keepresso left in the Trash by an update (Homebrew upgrades and
  manual reinstalls both put one there) made macOS re-disable the helper
  minutes after every repair or reinstall, over and over. Keepresso now finds
  those stale copies, by remembering where it last ran from and by reading
  macOS's own background-item records, and deletes them by itself before
  repairing, so the fix finally sticks.
- **The repair window tells the truth now.** Before offering a reinstall,
  Keepresso checks the system's records: if the real problem is that the
  background switch is off, the window says exactly that (System Settings,
  Login Items & Extensions, App Background Activity) and flips to "All set"
  by itself the moment you turn it on, even when macOS's status API never
  notices the change.
- **Removing the helper explains what you'll see.** After a removal, System
  Settings can keep showing a leftover Keepresso row under App Background
  Activity until macOS refreshes its list (a restart clears it). The status
  in Keepresso now says so instead of looking like the removal failed.
- **Development builds keep their hands off.** A copy of Keepresso running
  from outside the Applications folder no longer touches the helper's
  registration at all; even a status check from one could hand the
  registration to the wrong copy and get the helper disabled.

## [1.11.1] - 2026-07-08

Theme: the helper heals itself.

### Fixed

- **The helper survives updates and reboots for real now.** macOS could lose
  the helper's launch registration after an app update followed by a restart
  (the system record kept pointing at the old app copy), leaving the helper
  installed but unreachable: closed-display mode and AWDL pausing then failed
  with a confusing flag-file error. Keepresso now checks the helper at launch
  and whenever a privileged switch fails, and repairs the registration by
  itself, silently and without a password, in the common case. Errors from
  the helper path now say what actually happened ("the helper isn't
  responding") instead of blaming a flag file.
- **When the repair does need you, it's unmissable.** If macOS insists on a
  fresh approval, or the helper stays unresponsive after a repair, a small
  window opens front and center and walks through the single step (approve in
  Login Items, or reinstall), updating live and confirming success on its
  own. The menu also shows a warning row with a Fix button until it's
  resolved, and a failed engage retries in the same session once the helper
  is back.

### Added

- **Pick the AWDL resume delay.** Gaming & Streaming now has a "Resume AWDL
  after leaving the game" picker (10 seconds to 5 minutes, 1 minute as
  before), so quick alt-tabs don't flap the radios but AirDrop and Handoff
  can come back as fast as you like. Changes apply immediately, even to a
  countdown already running.

## [1.11.0] - 2026-07-07

Theme: one password, ever.

### Added

- **The administrator helper: one password, ever.** A small privileged helper
  service (Preferences > General > Administrator helper) now handles
  closed-display mode and AWDL pausing. Install it once, approve it under
  System Settings > Login Items (macOS asks for your administrator password
  that one time), and every privileged switch after that is instant and
  silent: no more password prompt on each app launch for "Only while brewing"
  or the AWDL watchdog. The helper survives restarts and app updates, can
  only flip those specific switches, restores everything if the app quits or
  crashes, and can be removed again from the same place. Without it,
  everything keeps working the old way, with the per-run prompt. The helper
  sits at the top of Preferences > General, and the welcome screen offers it
  as a one-time setup step on first launch.
- **The CLI on PATH for DMG installs.** The helper also creates the
  `/usr/local/bin/keepresso` link (and re-heals it after the app moves or
  updates), so the command-line tool just works on a drag-installed copy, not
  only via Homebrew. It never touches a file it didn't create.

### Fixed

- When the old-style password prompt is triggered in the background (a
  trigger-started session engaging "Only while brewing"), Keepresso now also
  posts a notification saying the password is needed and why, instead of
  leaving an unexplained dialog behind other windows. That notification was
  previously dropped by macOS whenever Keepresso was the active app; it now
  shows reliably. The in-app notes point at the helper as the way to stop
  the prompts for good, and no longer flash under a toggle during quick,
  prompt-free operations.

## [1.10.0] - 2026-07-07

Theme: closed-display mode that follows the session, and the website's copper
inside the app.

### Added

- **Closed-display mode, only while brewing.** A new "Only while brewing"
  option (Preferences > General > Closed-display mode) ties the lid-closed
  keep-awake to the session: it switches on when a keep-awake session starts
  and back off when the session ends or the app quits (even after a crash),
  instead of staying on globally until you remember to turn it off. Your
  administrator password is asked once per app run, not at every flip;
  enabling the option authorizes right away so a trigger-started session
  never pops a surprise password dialog. The manual toggle still works and
  still wins mid-session.

### Changed

- The app's accent now matches the website's burnt-copper palette (copper in
  light mode, soft copper in dark), across the menu, Preferences, the setup
  windows, and the widgets.

## [1.9.0] - 2026-07-06

Theme: a command-line tool, and reliability fixes from a full-history review.

### Added

- **The `keepresso` command-line tool.** A caffeinate-style CLI, shipped inside
  the app bundle and linked onto PATH by the Homebrew cask. `keepresso start /
  stop / toggle / status` drive the app; `keepresso -t <seconds>`, `-w <pid>`,
  `-i`, `-d`, and `-u` hold a power assertion directly, so scripts and
  pipelines can block on it even when the app is not running. `keepresso help`
  lists everything.
- The app now mirrors its session state to
  `~/Library/Application Support/Keepresso/status.json` (JSON, ISO 8601 dates)
  for the CLI and other tooling to read.

### Fixed

- Battery auto-pause no longer fights a manual start. Starting a session (menu,
  hotkey, widget, or URL) while paused on low battery used to activate for one
  second and then stop again, firing the session-end notification or action;
  the pause now holds, the menu explains it, and plugging in lifts it.
- The desktop widget buttons and the Control Center toggle now launch Keepresso
  when it isn't running, instead of silently doing nothing.
- The widgets no longer show "Brewing" after a crash or force quit: they check
  that the app is actually running, and a timed session whose end already
  passed renders as off.
- Idle widget text is readable in light mode (it could blend into the dark
  tile before).
- On a first launch from the DMG, the welcome window now appears after the app
  moves itself to Applications, not in the copy that is about to quit (which
  lost it forever).

## [1.8.0] - 2026-07-06

Theme: onboarding, portability, and two new triggers.

### Fixed

- App-based trigger conditions now show the app's name instead of its raw bundle
  identifier. The menu's condition list and the rules editor read "NVIDIA
  GeForce NOW is running" rather than "App com.nvidia.gfnpc.mall is running";
  the Cloud Gaming and Remote Control presets and any rule added from the
  running-apps menu carry a friendly name.
- The global keep-awake shortcut no longer springs back when triggers are
  active. Pressing it now pauses trigger gating (the same in-memory pause as the
  menu's Pause Triggers), so the toggle sticks and the menu shows "Resume
  Triggers", instead of the gate turning the session back on a second later.

### Added

- **Export and import settings.** Back up your settings, triggers, and presets
  to a JSON file, or move them to another Mac, from Preferences > General. The
  file is version-stamped and validated on import.
- **Keep awake until a download finishes.** A new trigger that watches a folder
  you pick (Downloads by default) and holds the Mac awake while an in-progress
  download file (.crdownload, .download, .part, and the like) is present, then
  lets it sleep once the transfer completes. Holds for 30 seconds between files
  in a batch. Add it from Triggers > Apps & Activity > Downloads.
- **Network-activity trigger.** Keep awake while a large transfer is running,
  even when no single app or process rule fits. Fires while smoothed throughput
  stays above a threshold you choose, with the same moving-average and hysteresis
  the CPU-load trigger uses so a brief burst doesn't start a session. Add it from
  Triggers > Network & Devices > Network activity.
- **Welcome window.** A short first-run window points out that Keepresso lives in
  the menu bar (no Dock icon) and offers one-click setup: pick how you use your
  Mac (agentic coding, gaming and streaming, meetings and calls, remote access)
  to apply the matching triggers, plus launch-at-login and notifications. Shown
  once on a new Mac; reopen it any time from Preferences > General. Existing
  users aren't shown it on upgrade.
- **Liquid Glass app icon.** A new macOS 26 app icon built with Icon Composer,
  with light, dark, and tinted appearances and the Liquid Glass material.

## [1.7.0] - 2026-07-06

Theme: remote-work presence and everyday control.

### Added

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

## [1.6.0] - 2026-07-05

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

## [1.5.0] - 2026-07-04

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

## [1.4.0] - 2026-07-03

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

## [1.3.0] - 2026-07-03

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

## [1.2.0] - 2026-07-01

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

## [1.1.1] - 2026-07-01

- Fixed a crash in the headless-readiness Setup screen.
- Corrected stale distribution docs.

## [1.1.0] - 2026-07-01

- **Battery-aware auto-pause.** Let the Mac sleep once charge drops below a
  threshold you choose, even mid-session, so it never runs the battery flat.
- **Menu-bar countdown.** An optional live countdown next to the cup icon for
  timed sessions.
- **URL scheme.** Drive a session from Shortcuts, Raycast, Alfred, or a shell
  script with `keepresso://start?duration=60`, `stop`, or `toggle`.
- **Presets.** Apply a named trigger bundle in one click, built-in (AI Agent,
  On AC Power, External Display Connected) or your own saved rule sets.

## [1.0.0] - 2026-07-01

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
