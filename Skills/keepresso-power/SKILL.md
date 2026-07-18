---
name: keepresso-power
description: Manage bounded Keepresso wake leases for long-running or unattended AI coding tasks. Use when work must survive idle sleep or a closed MacBook lid, when several agents run concurrently, or when task cleanup must restore normal sleep behavior after success, failure, cancellation, or timeout.
---

# Keepresso Power

Use the `keepresso lease` CLI to declare the task lifecycle explicitly. Acquire only for work that needs sleep protection. Keep the lease alive while work continues, then release the exact lease in cleanup code.

## Run the lease lifecycle

1. Verify the CLI is available with `command -v keepresso`.
2. Choose a short TTL and a bounded maximum lifetime. Prefer a TTL of 300 seconds and renew it by the halfway point. Set the maximum lifetime to the expected task duration plus a reasonable recovery margin.
3. Acquire before starting protected work:

   ```sh
   lease_json="$(keepresso lease acquire \
     --owner "${USER:-automation}" \
     --agent codex \
     --task "repository-task-name" \
     --ttl 300 \
     --max-lifetime 14400 \
     --message "Working on the requested change")"
   lease_id="$(printf '%s' "$lease_json" | \
     /usr/bin/plutil -extract lease.id raw -o - -)"
   ```

4. Confirm that the response has `"ok": true` and a non-empty lease ID. If acquisition fails, stop or tell the user that the task is not protected from sleep.
5. Renew during long work, no later than half of the current TTL:

   ```sh
   keepresso lease heartbeat "$lease_id" \
     --ttl 300 \
     --message "Task is still running"
   ```

6. Release in a `finally`, `defer`, or exit-trap path. Report the actual result as `success`, `failure`, `cancelled`, or `timeout`:

   ```sh
   lease_result=failure
   cleanup_lease() {
     keepresso lease release "$lease_id" \
       --result "$lease_result" \
       --message "Task finished" >/dev/null || true
   }
   trap cleanup_lease EXIT
   trap 'lease_result=cancelled; exit 130' INT
   trap 'lease_result=cancelled; exit 143' TERM

   # Run the protected task here.
   lease_result=success
   ```

Set `lease_result=timeout` when a task deadline is reached. Leave the default as `failure` until the task has verifiably succeeded.

## Inspect without disturbing other agents

Use these read operations for recovery and diagnostics:

```sh
keepresso lease status "$lease_id"
keepresso lease status
keepresso lease list --owner "${USER:-automation}" --agent codex
keepresso lease list --all
```

Treat lease IDs as ownership tokens. Release only the ID acquired for the current task. Other active leases are independent, and their presence may correctly keep the Mac awake after this task releases its lease.

Do not rely on process names, CPU use, or transcript changes when an explicit lease is available. Do not renew past the configured maximum lifetime. If the agent crashes or cleanup does not run, allow the TTL to expire so Keepresso can recover safely.
