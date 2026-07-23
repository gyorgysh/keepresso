---
name: keep-awake
description: Keep this Mac awake while long unattended work runs, using Keepresso's bounded automation leases (acquire, heartbeat, release). Use before long builds, renders, downloads, test suites, or overnight agent tasks so the machine cannot sleep mid-task, and release when done so it can sleep again.
---

# Keep the Mac awake with a Keepresso lease

A lease is a bounded keep-awake grant. While at least one lease is live,
Keepresso holds the Mac awake (system sleep only, the display may sleep).
Every lease has a TTL you must keep renewing with heartbeats, plus a hard
maximum lifetime, so a crashed process can never hold the Mac awake forever.
When the last lease releases or expires, the session ends and the user's
configured end action (sleep, lock screen) may run.

The `keepresso` command is on PATH for Homebrew installs. If it is not,
use the absolute path: `/Applications/Keepresso.app/Contents/Helpers/keepresso`.

## Protocol

1. Check readiness (optional): `keepresso status --json`. Exit 2 means the
   app is not running; acquiring a lease launches it, so this is not an error.

2. Acquire one lease before the long work starts, with a UUID you generate
   once and keep:

   ```sh
   LEASE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
   keepresso lease acquire --id "$LEASE_ID" \
     --tool "<your-agent-name>" \
     --task "<one line describing the work>" \
     --ttl 300
   ```

   Exit 0 means the app acknowledged the lease. Exit 4 means the user has
   disabled automation leases in Preferences: respect that, do not retry, and
   tell the user the Mac may sleep during the work. Exit 2 means the app did
   not acknowledge (not installed, or too old): same advice.

3. Heartbeat before half the TTL elapses, from your main loop or between
   steps:

   ```sh
   keepresso lease heartbeat --id "$LEASE_ID"
   ```

   Exit 3 means the lease is gone (expired, or the user pressed Stop, which
   revokes all leases). Do not fight the user: either finish quickly, or
   re-acquire only if the work genuinely must continue and the user asked
   for it. After any exit 3, do not assume the Mac stayed awake in between.

4. Always release in your cleanup path, even on failure or interruption
   (shell `trap`, agent stop hook):

   ```sh
   keepresso lease release --id "$LEASE_ID"
   ```

   Release is idempotent. Note the user's end action may run right after
   the last lease releases, so save your work first.

## Rules of the road

- One lease per task. Reusing your id on acquire renews the same lease.
- Never release or heartbeat an id you did not acquire; other tools' leases
  are not yours.
- The acquire's UUID is an idempotency key: if you lose the response, run
  the same acquire again with the same id.
- The maximum lifetime (default and cap: 7 days) cannot be extended by
  heartbeats. Long-running pipelines should re-acquire with a fresh id when
  a lease reaches its ceiling.
- `keepresso lease list --json` shows every lease and its state.

## MCP alternative

The same operations are available as MCP tools (acquire_lease,
heartbeat_lease, release_lease, list_leases, get_status) from the bundled
stdio server. Point your MCP configuration at:

```
/Applications/Keepresso.app/Contents/Helpers/keepresso-mcp
```

## Scheduled wakes (optional, off by default)

`keepresso wake status` always works (it only reads). `keepresso wake set`
and `keepresso wake clear` change the system wake schedule and are honored
only while the user has enabled "Allow automation to change the wake
schedule" in Keepresso's Preferences. Exit 4 means it is disabled: ask the
user to enable it, never try to work around it.
