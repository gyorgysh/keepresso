# Scheduled AI runs (automation wake sync)

Keepresso can wake your Mac for the recurring tasks your **local** AI tools
schedule, and hold it awake while they run. Turn it on in
**Preferences ▸ Automation ▸ Scheduled AI runs**.

## What it syncs, and what it deliberately doesn't

There are two kinds of scheduled AI task, and only one needs a Mac that's awake:

| | Where it runs | Needs the Mac awake? | Synced by Keepresso |
| --- | --- | --- | --- |
| **Local** (Claude Desktop local routine, Codex automation) | Your Mac | **Yes** — skipped if it sleeps through the time | **Yes** |
| **Cloud** (Claude cloud routine, ChatGPT task) | The vendor's servers | No — runs with the lid shut | No |

Cloud routines are neither listed nor woken for: waking the Mac wouldn't change
whether they run. Keepresso reads only the **schedule and name** of each local
task, never its prompt.

Claude Desktop's own help says the quiet part out loud for local routines:

> If your computer sleeps through a scheduled time, the run is skipped.

Keepresso fills that gap, including the case Claude Desktop's "Keep computer
awake" can't cover: a **closed lid** (its closed-display mode keeps the Mac up
with the lid shut).

## How it works

1. Keepresso discovers local tasks by reading each tool's on-disk schedule:
   - Claude Desktop: `~/Library/Application Support/Claude/claude-code-sessions/*/*/scheduled-tasks.json` (5-field cron).
   - Codex: `~/.codex/automations/*/automation.toml` (iCal RRULE).
2. It arms a firmware wake a few minutes before the next run (`pmset`, through
   the administrator helper), re-arming as runs fire.
3. When the Mac wakes for a run, Keepresso holds a keep-awake session for a
   short window (default 15 minutes; configurable).
4. For a run that lasts longer than the window, the agent can take over with a
   **lease** and the Mac stays awake until the agent releases it (below).

Installing the wake needs the administrator helper (Preferences ▸ General), the
same as the manual scheduled-wake feature.

## Creating a local task to sync

- **Claude Desktop:** open **Routines ▸ New routine ▸ Local**, give it a
  schedule (Daily, Weekly, ...). Choosing **Cloud** instead runs it on
  Anthropic's servers, where no wake is needed.
- **Codex:** create an automation with `execution_environment = "local"`.

## Let an agent hold the Mac awake for the whole run

The fixed hold window is a safety net. For a run whose length you don't know in
advance, have the agent acquire a Keepresso **lease** at the start and release
it at the end, so the Mac stays awake exactly as long as the work does and
sleeps again the moment it finishes. Keepresso ships a `keepresso` CLI and a
local MCP server for this (Preferences ▸ Automation ▸ Automation access has the
setup to copy).

Add a note like this to your agent's `CLAUDE.md` / `AGENT.md` so scheduled runs
manage their own lease:

```markdown
## Keeping this Mac awake during scheduled runs

When you start a scheduled or long-running task on this Mac, keep the machine
awake for its full duration using Keepresso leases:

1. At the start: acquire a lease (via the `keepresso` CLI or the Keepresso MCP
   server), giving it a short TTL and a task label.
2. While working: renew (heartbeat) the lease before its TTL elapses.
3. At the end (success or failure): release the lease so the Mac can sleep.

Never hold a lease past the work. A crashed run can't strand the Mac awake:
leases expire on their own once heartbeats stop.
```
