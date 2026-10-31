---
name: dsh-control
description: Control the installed DeepSeek Harness desktop UI through dsh-control, including submitting tasks, reading responses, choosing sessions and models. Use for the desktop app; excludes standalone headless dsh runs.
---

# dsh-control

Use `dsh-control` from PATH, or `"$HOME/.local/bin/dsh-control"` in a restricted shell. It drives the real `dsh-app://app/` page through native CDP and reads released session files for observation. Keep product mutations in the GUI; do not substitute headless `dsh`, private application APIs, direct store edits or credential changes.

Check `dsh-control --help` before using a new command; an older installed binary may not match this skill. Missing commands require updating the executable, not guessing another action.

Read [commands.md](references/commands.md) for command syntax, JSON fields, file briefs, native folder selection and result limits. Use the same state directory for agents sharing this app; separate directories split locks and deduplication history.

## Workflow

1. Work within the user's authorized scope and preserve unrelated drafts and selections. Debugger launch/restart, sending, cancellation and access changes need authorization for that scope; do not ask again when already authorized. `start` cold-launches debugging only when stopped; `requires_restart` needs a normal authorized quit/reopen. Never force-kill or use the non-CDP inspector on 9230.
2. `inspect` first, optionally with `--session ID --compact`. Use its fresh `expect` token and transient control refs. Token checks include the complete observed guard even when output is filtered. `uiAvailable: false` means observation cannot authorize input there; inspect `composer.reason` and capabilities before text actions. Re-inspect after any change.
3. Use dedicated commands for sending, stopping, sessions, workspaces, models and access. Generic `click` refuses executing composer actions. All product changes use verified GUI controls; native workspace pickers also require existing Accessibility/event permission and an interactive desktop.
4. Give each send or session creation a permanent `requestId` of 1–80 ASCII letters, digits, `_` or `-`. Reusing a send ID never dispatches again. Preserve the exact inspected request while resolving a receipt; different parameters can return `request_conflict`. Slash/reference opt-ins can execute during selection, so ambiguous selection is uncertain and must be reconciled.
5. A verified send establishes admission, not model completion. Prefer `wait --session ID --request-id ID` or `send-and-wait`; waiting is read only and leaves cancellation available. Terminal results are `settled` or `terminated`; recorded interaction yields `blocked`. Durable open turns and subagent state do not establish live execution.
6. Exit 3 / outcome `unknown`: inspect, read and reconcile the existing receipt (`receipt --request-id ID --reconcile`). Never resend automatically or switch IDs. If uncertainty remains consequential, return it to the user. Inspect before repeating any uncertain draft, click or toggle. A valid `not_sent` / `not_performed` receipt permits a fresh inspected request within existing authorization; malformed receipts do not.

Output is one JSON object: `{"version":1,"ok":true,"result":...}` or `{"version":1,"ok":false,"error":{code,message,outcome,details}}`. Exit 2 reports `not_performed`; exit 3 reports `unknown`. A wait timeout never retries input. `--retry-transient` only bounds observation retries.

Use `read --session ID --last-assistant --full` for complete recorded reply text, and `--out NEW_FILE` for an owner-only export. GUI messages may be virtualized or truncated. Known-child cancellation and recorded tool changes report partial coverage; never present them as all descendants or a complete filesystem diff.

Only when debugger access was opened for this task and no other user or agent needs it, close that access with normal quit/reopen without debugging flags. Otherwise preserve the shared running app.
