# Command reference

Run `dsh-control COMMAND [options]`. Request flags and a single JSON object on stdin are alternatives; do not mix them. JSON input is limited to 1 MiB. Unknown fields, repeated flags, incorrect types and conflicting selectors are rejected. Boolean JSON fields require booleans; turn/retry counts require nonnegative integers up to 1,000,000. Connection flags are separate from request fields and can accompany either form.

Exit codes: `0` success, `2` nothing performed, `3` uncertain outcome. Each invocation prints one versioned JSON object.

## Shared options

| Flag | Default / purpose |
|---|---|
| `--port N` | `9222`; app-owned loopback CDP port, 1–65535 |
| `--timeout SECONDS` | `10`; positive verification/wait deadline, at most 3600 |
| `--app PATH` | `/Applications/DeepSeek Harness.app` |
| `--state-dir PATH` | `~/Library/Application Support/dsh-control`; private locks, receipts and reservations |
| `--dsh-home PATH` | `~/.dsh`; read-only session/workspace observation root |

State overrides are for isolated tests or deliberately separate installations. Agents controlling the same app must share the state directory. `--help` returns help in the normal JSON envelope.

## Observe

| Command | Request flags | Equivalent JSON fields |
|---|---|---|
| `inspect` | `--session ID`, `--compact`, `--fields a,b`, `--controls composer\|sidebar\|messages` | `session`, `compact`, `fields`, `controls` |
| `read` | `--session ID`, `--last-assistant`, `--turn N` or `--since CURSOR`, `--full`, `--out NEW_FILE` | `session`, `lastAssistant`, `turn`, `since`, `full`, `out` |
| `status` | `--session ID` | `session` |
| `changes` | `--session ID`, `--turn N`, `--diff` | `session`, `turn`, `diff` |
| `wait` | `--session ID`, one of `--request-id ID`, `--input-id ID`, `--turn N`; `--retry-transient N` | `session`, `requestId`, `inputId`, `turn`, `retryTransient` |
| `receipt` | required `--request-id ID`, optional `--reconcile` | `requestId`, `reconcile` |

`inspect` needs the GUI and returns the target, guard, `expect`, session identity, composer state, controls, messages and capabilities. `--session` scopes observation to one exact conversation occurrence, including a visible sidebar subagent. An unavailable occurrence returns no usable token. Compact output and filters change only the report; the complete UI guard still authorizes actions. `--fields` selects existing top-level fields after compact filtering.

`read`, `status`, `changes` and `wait` with `--session` read the configured store without connecting to the app. Omitting the session from `read`/`status`/`changes` uses the displayed GUI identity. Released v4 raw JSONL and `.jsonl.zstd` are supported; future generations fail without fallback. Inherited seed events are excluded. Unknown durable liveness stays unknown: an open turn or recorded pending approval/question does not prove a live runtime. Root, fork and subagent identities depend on recorded ancestry/catalog evidence; missing evidence is not invented.

`read --last-assistant` selects the latest successful human turn, or the selected turn with `--turn`. Default text is capped at 16,000 characters; `--full` preserves the complete body. `--since` accepts the opaque cursor returned by observation and requires a continuous unchanged log prefix. `--out` implies full output, creates an owner-only file and refuses an existing path or symlink. Parent directories must exist.

`changes` reports only validated metadata hunks from successful recorded `write`/`edit` calls. `--diff` includes recorded old/new hunk text. Coverage is partial; absence is unavailable, not proof of no changes. It is neither a Git diff nor a complete host change summary.

`wait` binds the specified input or turn; with no selector it binds the latest recorded human input. A verified receipt is the preferred anchor. Completion returns `settled`; other recorded terminal reasons return `terminated`; pending interaction returns `blocked`. Timeout returns `wait_timeout` with unknown outcome. No input is retried. `--retry-transient` (default 3) bounds transient store-read retries. A session-bound wait already follows the same session through GUI view changes; `--follow-session` makes this default explicit. It does not switch to future turns.

`receipt --reconcile` can promote an existing prepared/uncertain v2 receipt only when matching post-cursor durable admission is observed. It never dispatches input. Legacy receipts remain readable but lack v2 reconciliation evidence. A reused send ID remains permanent regardless of outcome.

## Draft, send and stop

All commands below require `--expect TOKEN`; `--session ID` is optional and must match a displayed, usable conversation for input.

| Command | Additional request flags | Equivalent JSON fields |
|---|---|---|
| `draft` | required `--text TEXT` | `expect`, `text`, `session` |
| `click` | required `--ref REF` | `expect`, `ref`, `session` |
| `scroll` | required `--direction up\|down` | `expect`, `direction`, `session` |
| `send` | required `--request-id ID`; optional `--file FILE`, `--long-brief attach\|reference`, `--allow-slash`, `--allow-references` | `expect`, `requestId`, `session`, `file`, `longBrief`, `allowSlash`, `allowReferences` |
| `send-and-wait` | same as `send`, plus `--retry-transient N` | send fields plus `retryTransient` |
| `cancel` | optional `--include-subagents` | `expect`, `session`, `includeSubagents` |

`draft` replaces unsent text, normalizes line endings and permits empty text to clear it. The draft limit is 200,000 UTF-8 bytes; ordinary sends are limited to 12,000 UTF-16 units. Inspect `composer.reason` for `session_not_displayed`, `ambiguous_composer`, `composer_unavailable`, `read_only`, `pending_interaction` or `settling`; do not infer a hidden-window problem from a timeout.

`send` proves admission using a matching durable event, or for ordinary text an exact new user echo and an emptied composer. It does not prove completion. `send-and-wait` releases the mutation lock before waiting. If its wait fails, the verified send evidence remains in the error details; read the existing receipt and never resend to repair a wait.

`--file` reads valid UTF-8 up to 16 MiB and requires an empty composer without pending attachments, commands or references. Files within the ordinary send limit are drafted as text. Overlong files require a `.md` extension and `--long-brief attach`; a supported GUI upload sends a short instruction containing its filename and SHA-256. Verification requires a durable file reference whose SHA-256 attachment identity and byte count match the receipt. Upload readiness alone does not confirm submission. Desktop rc.5 inserts local non-image files as filesystem-reference chips instead of uploading bytes; this route returns `native_file_reference`, preserves the staged chip, and sends nothing. It cannot meet the byte-attachment guarantee, and a matching filename does not prove file contents.

`--long-brief reference --file /absolute/path/brief.md` explicitly uses the desktop filesystem-reference route. It requires a durable session with a known working directory and an empty composer, stages one native Markdown chip, and appends an instruction without replacing the chip. The receipt distinguishes `nativeFileReference` from uploaded attachments and verifies the exact serialized `@path` in durable user input. The local SHA-256 is checked before and after staging; it does not prove uploaded bytes or that the model read the file. A pre-existing chip remains a draft conflict because its hidden path cannot be established from its filename alone.

```sh
dsh-control send-and-wait --session '<id>' --expect '<fresh-token>' \
  --request-id '<unique-id>' --file /absolute/path/brief.md --long-brief attach
```

Slash commands and references are refused unless `--allow-slash` / `--allow-references` is supplied. Only an unambiguous offered GUI item is selected. Selection can execute a command before Send; missing choices, nested choosers and uncertain execution require receipt reconciliation, not another attempt. Command receipts may have no model turn to wait for.

A registered skill offered by the native slash menu is selected and sent as ordinary `/skill-name` prompt text, including when it has no arguments. Its receipt uses `operation: skill` and requires durable user-input admission rather than `command/run`; this confirms submission, not that the skill's instructions completed. Unknown or ambiguous slash entries remain blocked.

`cancel --include-subagents` attempts the parent and known direct children through their GUI conversations. Its result is partial: new, external, unobserved and deeper descendants may remain active. Check each returned outcome. Generic `click` refuses Send, Stop, Queue, Steer, non-menu composer actions and plugin creation; use dedicated commands.

## Sessions, workspaces and configuration

Each command requires a fresh `--expect TOKEN`. Model and access changes require the exact main conversation to be selected.

| Command | Additional request flags | Equivalent JSON fields |
|---|---|---|
| `new-session` | required `--request-id ID` and exactly one of `--workspace NAME`, `--workspace-id ID`, `--cwd ABSOLUTE_DIRECTORY`; optional `--title TITLE` | `expect`, `requestId`, `workspace`, `workspaceId`, `cwd`, `title` |
| `select-session` | `--id ID` or unique `--title TITLE` | `expect`, `id`, `title` |
| `release-session` | required `--id ID --request-id CREATION_OWNER_ID` | `expect`, `id`, `requestId` |
| `add-workspace` | required positional absolute directory | `expect`, `path` |
| `set-model` | required `--model ID`; optional `--provider ID`, `--effort VALUE`, `--session ID` | `expect`, `model`, `provider`, `effort`, `session` |
| `set-access-mode` | required `--mode MODE`; optional `--confirm-risk`, `--session ID` | `expect`, `mode`, `confirmRisk`, `session` |

`new-session` uses the product's workspace action and may reuse an empty provisional row. It reserves the observed exact identity for the creation request; it does not send a synthetic prompt. Replaying that request returns its saved result instead of creating again. A supplied title is pending until the first verified human send and does not overwrite an existing user title. `release-session` releases only the controller reservation owned by that creation request; it does not delete or close the product session.

`--cwd` can register an existing directory when needed. Workspace paths are canonicalized and must exist. Workspace/session names must identify one record; use IDs when ambiguous. `add-workspace` verifies existing registry membership or uses the native folder chooser. It requires existing Accessibility/event-posting permission, the user's interactive console and one verified visible app window. The chooser fails closed on ambiguous ownership, unrelated dialogs or an unverifiable selected directory; inspect the app before any repeat.

`set-model` chooses only an offered provider/model. Omit the provider only when the model identifies exactly one offered provider. Effort values are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `default`. A model selection can succeed before effort selection fails; inspect the reported partial result.

Access modes are `read-only`, `workspace-write`, `full-access`, `auto-review`; `danger-full-access` and `auto` are accepted aliases. Full access and auto review require `--confirm-risk` as well as user authorization for that change. Selection and risk confirmation use the real GUI.

## App lifecycle and legacy JSON

`start` and `quit` accept connection flags and need no request object. `start` cold-launches with loopback debugging only when stopped; `requires_restart` never restarts a running app. `quit` requests normal termination and may return `quit_pending`. Neither command force-kills. Foreign listeners are rejected; the custom inspector on 9230 is not used.

Legacy JSON action requests are preserved:

```sh
printf '%s\n' '{"expect":"<token>","text":"unsent text"}' | dsh-control draft
printf '%s\n' '{"expect":"<token>","requestId":"<unique-id>"}' | dsh-control send
printf '%s\n' '{"requestId":"<unique-id>","reconcile":true}' | dsh-control receipt
```

Legacy `wait` accepts `{"anchor":"<user-node-key>","context":{...}}` from the verified send state. It requires the exact user anchor and matching conversation/document identity; an unresolved anchor is unknown, never a reason to infer the latest turn. Prefer an exact session and verified request ID for new work.

## Agent skill installation

Run from the repository root. These are conventional local skill locations; configure only the agents you use. Existing files and links are left unchanged. Keep this checkout in place because the links point to it.

```sh
for directory in \
  "$HOME/.agents/skills" \
  "$HOME/.claude/skills" \
  "$HOME/.cursor/skills" \
  "$HOME/.config/opencode/skills" \
  "$HOME/.codeium/windsurf/skills" \
  "$HOME/.copilot/skills" \
  "$HOME/.trae/skills" \
  "$HOME/.gemini/config/skills" \
  "$HOME/.gemini/antigravity-cli/skills" \
  "$HOME/.pi/agent/skills"
do
  mkdir -p "$directory"
  if [ ! -e "$directory/dsh-control" ] && [ ! -L "$directory/dsh-control" ]; then
    ln -s "$PWD/skills/dsh-control" "$directory/dsh-control"
  fi
done
```

Reload your agent or start a fresh chat if it caches skills. A readable skill link does not establish activation in every agent. The executable and Harness app must be accessible on the same Mac. Agents controlling the same app must share the controller state directory.

## Development checks

Run Swift tests with `swift test`. Optional DOM tests require an already-installed Playwright and Chrome; replace both paths below:

```sh
PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs \
CHROME_PATH=/absolute/path/to/chrome node --test Tests/DOM/adapter.test.mjs
```
