# Agent power orchestration

Keepresso gives AI Agents an explicit, bounded way to keep a Mac awake. The
Agent owns a wake lease for exactly the lifetime of its task. Keepresso combines
all active leases and scheduled preparation work, keeps the system running while
any source remains, then restores normal sleep after the final source ends.

## Before unattended use

1. Install Keepresso and enable launch at login.
2. Install and approve the administrator helper in Preferences > General. The
   helper is required for prompt-free scheduled wake and reliable lid-closed
   operation.
3. In Preferences > Automation, review the unattended policy. Its secure
   defaults lock the screen, turn off the display, and sleep the Mac after all
   work finishes.
4. Keep thermal protection enabled for lid-closed work. For scheduled firmware
   wake, external power is the most reliable configuration.

An `IOPMAssertion` prevents idle system sleep but cannot override clamshell
sleep on its own. Keepresso's helper temporarily applies `pmset disablesleep`,
records the exact prior value, and restores that value when the last protected
session ends. Its root-owned recovery journal survives a client crash, helper
restart, and Mac reboot. The legacy password fallback is retained only for the
persistent manual switch and stale-file cleanup. It cannot start a new scoped
Agent transaction. Keepresso never assumes the original value was zero.

During a thermal stop, the same scoped transaction enters a suspended mode. It
forces `disablesleep` to zero while retaining the exact original snapshot and
recovery marker. After cooling, it moves directly back to active if Agent demand
remains, or restores the snapshot if work ended. This covers manual, automatic,
and combined ownership without a release-and-reacquire gap.

## Lease lifecycle

Acquire a lease immediately before protected work starts. Use a short TTL and
heartbeat before half of it elapses. The maximum lifetime is an absolute upper
bound that heartbeats cannot extend. Keepresso enforces a seven-day hard ceiling
on both values so a malformed request cannot create a near-permanent hold.

```sh
lease_json="$(keepresso lease acquire \
  --owner "${USER:-automation}" \
  --agent codex \
  --task "repository-task" \
  --ttl 300 \
  --max-lifetime 14400 \
  --message "Working on the requested change")"

lease_id="$(printf '%s' "$lease_json" | \
  /usr/bin/plutil -extract lease.id raw -o - -)"

lease_result=failure
cleanup_lease() {
  keepresso lease release "$lease_id" \
    --result "$lease_result" \
    --message "Task finished" >/dev/null || true
}
trap cleanup_lease EXIT
trap 'lease_result=cancelled; exit 130' INT
trap 'lease_result=cancelled; exit 143' TERM

while task_is_running; do
  run_one_task_step
  keepresso lease heartbeat "$lease_id" --ttl 300 >/dev/null
done

verify_task_result
lease_result=success
```

Leave the result as `failure` until the task has verifiably succeeded. Allowed
release results are `success`, `failure`, and `cancelled`. Timeout is reserved
for Keepresso's watchdog.

Useful read-only commands are:

```sh
keepresso lease status "$lease_id"
keepresso lease status
keepresso lease list --owner "$USER" --agent codex
keepresso lease list --all
keepresso status --json
```

Every lease command emits a stable JSON envelope. Lease IDs are ownership
tokens. A task must release only the ID it acquired. Concurrent tasks remain
independent, and the Mac stays awake until every active lease is terminal. The
response status also includes `closedLidProtectionReady` and stable `warnings`.
Before a task starts, readiness reports whether the required capability is
available. While unattended demand is active, true means either the scoped hold
was actually accepted or a live manual closed-display override was verified. It
never means merely that the helper is installed. A false or unknown warning
means the lease still protects open-lid idle sleep, but the Agent must not tell
the user that closed-lid work is safe.

## Codex Skill

The signed app bundle includes a ready-to-use Skill at:

```text
/Applications/Keepresso.app/Contents/Resources/keepresso-power
```

Preferences > Automation can reveal this directory. Copy the complete folder
into the skills directory used by the Agent. For Codex with its default home:

```sh
mkdir -p ~/.codex/skills
cp -R /Applications/Keepresso.app/Contents/Resources/keepresso-power \
  ~/.codex/skills/
```

Invoke it as `$keepresso-power`. The Skill instructs the Agent to acquire before
work, heartbeat during long waits, release through cleanup, and preserve other
agents' leases.

## MCP server

The app embeds a local newline-delimited JSON-RPC stdio server at:

```text
/Applications/Keepresso.app/Contents/Helpers/keepresso-mcp
```

For Codex, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.keepresso]
command = "/Applications/Keepresso.app/Contents/Helpers/keepresso-mcp"
enabled = true
required = true
```

The server supports MCP protocol versions `2025-06-18` and `2025-11-25`, and
exposes these tools:

- `acquire_wake_lease`
- `renew_wake_lease`
- `heartbeat_wake_lease`
- `release_wake_lease`
- `list_wake_leases`
- `wake_status`

Its standard output is reserved for protocol frames. Diagnostics go to standard
error. Tool failures use MCP tool-result errors, while malformed JSON-RPC and
unknown methods use protocol errors. The local stdio connection accepts messages
up to 1 MiB and limits each client process to 120 tool calls per minute.

## Following Codex automations

Enable Follow local Codex automations in Preferences > Automation. Keepresso
extracts only scheduling metadata from active local and worktree automation
files. Task prompts and unknown fields are discarded during parsing. They are
never retained in the model, displayed, or written to the audit log.

For each nearest scheduled run, Keepresso:

1. Installs a one-shot system wake before the run while preserving any manual
   repeating wake schedule configured in Keepresso.
2. Establishes the keep-awake demand before probing readiness.
3. Waits for the configured power, battery, network, and Codex application
   requirements with bounded retry and timeout.
4. Opens Codex and waits for each grouped automation to acquire an explicit
   lease. The lease must use `agent=codex` and put the exact automation ID in
   either `owner` or `task`, so an unrelated concurrent lease cannot claim the
   scheduled handoff.
5. Atomically replaces scheduled handoff demand with the new lease IDs, so
   there is no sleep gap.
6. Releases failed or missing handoffs at the deadline. Valid leases continue
   independently.
7. Sleeps after the final lease ends, subject to the configured unattended end
   action and battery or thermal safety controls.

If no Agent claims a lease, Keepresso does not guess from CPU, process names, or
logs. It times out the handoff and restores normal sleep.

## Persistence and recovery

The shared registry is stored at:

```text
~/Library/Application Support/Keepresso/wake-leases.json
```

Writes are atomic, guarded by both process and cross-process locks, and created
with mode `0600`. Corrupt JSON is quarantined rather than overwritten. On app
restart, active leases are recovered, expired deadlines are applied, and the
union is reconstructed before normal polling resumes.

Structured unattended activity is written to:

```text
~/Library/Application Support/Keepresso/unattended-log.jsonl
```

The log rotates at 1 MiB, tolerates a partial final line, and contains lifecycle
metadata only. It excludes automation prompts, command arguments, and executable
paths.

Battery and thermal pauses always outrank a lease. A lease expresses task intent,
not permission to bypass hardware safety. Opening the lid immediately disarms
the lid-closed thermal escalation and returns fan control to macOS.
