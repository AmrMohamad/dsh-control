# dsh-control

Small macOS CLI for the installed DeepSeek Harness desktop UI. Product mutations use the real GUI through native Chromium DevTools Protocol (CDP) input; session and workspace files are read only. Each invocation prints one versioned JSON object. Swift 6, macOS 13+, no daemon, Node or runtime bridge.

## Build and install

```sh
swift build -c release
swift test
mkdir -p ~/.local/bin
install -m 755 .build/release/dsh-control ~/.local/bin/dsh-control
```

Compressed session observation loads an existing `libzstd` only when needed, from Homebrew's `/opt/homebrew/opt/zstd/lib` or `/usr/local/opt/zstd/lib`, then `/usr/lib`. Raw JSONL and GUI commands do not need it. A missing library returns `zstd_unavailable`; no package is installed automatically. Homebrew zstd is already installed on this Mac.

Expose this checkout's shared skill to all ten configured agent locations. Inspect existing files or links first; the loop skips them. Keep the checkout at its installed location.

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

These locations cover shared agents including Codex and Harness, Claude Code, Cursor, OpenCode, Windsurf, Copilot, Trae, Antigravity App/IDE, Antigravity CLI and Pi. Readable links and a working executable do not prove automatic skill activation; reload an agent or start a fresh chat if it caches skills. Remote agents cannot reach this Mac's app through these paths. Restricted shells can invoke `"$HOME/.local/bin/dsh-control"` directly. This Mac also has `/opt/homebrew/bin/dsh-control` linked to that executable.

## Use

Read the [agent skill](skills/dsh-control/SKILL.md) for the operating workflow and [command reference](skills/dsh-control/references/commands.md) for every command, flag and legacy JSON request.

```sh
dsh-control inspect --compact
dsh-control draft --expect '<fresh-token>' --session '<session-id>' --text 'hello'
dsh-control send-and-wait --expect '<new-token>' --session '<session-id>' --request-id '<unique-id>'
dsh-control read --session '<session-id>' --last-assistant --full --out /tmp/reply.json
```

Request flags and one JSON object on stdin are alternatives; mixing them, unknown fields, wrong types and conflicting wait selectors are rejected. Connection flags can accompany either form. Existing JSON action requests remain supported.

## Safety and observation

- Product changes go through the GUI, including session creation, model/access selection, file attachment and workspace registration. Controller-owned locks, receipts and reservations are stored separately. Session logs and workspace registry files are never edited.
- `inspect` binds a fresh `expect` token to the exact target and UI guard. Mutations recheck it before dispatch. Compact output, field selection and control filters do not weaken that guard. Session-specific input requires a displayed, usable composer; inspect `composer.reason` when it is unavailable, read only, blocked or settling.
- `send` verifies admission, not completion. Ordinary text can be confirmed by an exact new user echo with an emptied composer, or matching post-cursor durable input. Attachment sends require durable file references matching the prepared SHA-256 and byte count. Use `wait` or `send-and-wait` for the bound turn's terminal result; waiting does not hold the mutation lock.
- Send IDs are permanent deduplication keys. Hash-based receipts are persisted before executing input. Read `receipt --request-id ID --reconcile` after uncertainty; never resend automatically or invent a new ID. Corrupt or ambiguous evidence remains unknown. Slash commands and references require explicit opt-in and can execute during GUI selection.
- `read`, `status`, `changes` and `wait` can observe an exact session without CDP. They support released v4 JSONL and Zstandard files and exclude inherited seed history. Newer unsupported generations fail without falling back. Durable open turns have unknown liveness; recorded pending approvals/questions are not proof that their runtime is still active.
- Subagent identity comes from recorded parent/catalog data and visible GUI occurrences. Cancellation covers the parent and known direct children only and reports partial coverage. `changes` exposes validated metadata hunks from successful recorded `write`/`edit` calls; it is partial, not a Git diff or a complete host change summary.
- `read --full` preserves complete recorded text; default reads truncate bodies above 16,000 characters. `--out` implies full output and creates a new owner-only file, refusing an existing destination or symlink. GUI observations remain rendered-only and mark truncation at 12,000 UTF-16 units.

## Desktop requirements and limits

Cold-launch the app with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9222`; `start` does this if the app is stopped. A running app without CDP returns `requires_restart`. The tool never restarts or force-kills it. Only the installed app's loopback listener and `dsh-app://app/` page are accepted; the custom inspector on 9230 is not used.

Debugger access allows local processes to control the app. If that access was opened for the task, normally quit and reopen without debugging flags when no user or agent still needs it. Preserve shared active work.

Native workspace selection needs existing Accessibility/event-posting permission, the user's interactive console and one visible verified app window. It fails closed if chooser ownership or the selected path cannot be verified; it does not grant permissions or dismiss unrelated dialogs. Composer readiness is reported explicitly; a hidden or occluded window alone is not a diagnosis.

English and Chinese controls are supported. Release-specific DOM knowledge lives in `Sources/DSHControlCore/Page.swift`; future UI changes may require adapter updates. Large briefs use a UTF-8 Markdown file with `--file brief.md --long-brief attach`; other overlong text is refused. Do not bypass unavailable controls with private application APIs or direct store writes.

## Validation

The current enhancement integration pass reported 63 Swift tests and 26 isolated DOM tests passing. Live checks against Harness 0.2.1-rc.5 covered the core workflow described below. Automated results do not establish every GUI path.

Optional DOM tests use an already-installed Playwright and Chrome:

```sh
PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs \
CHROME_PATH=/absolute/path/to/chrome node --test Tests/DOM/adapter.test.mjs
```

Live rc.5 checks on 2026-10-31 verified native workspace registration, safe blank-session reuse, Read Only selection, Unicode-safe draft staging, durable send admission, session-bound completion, and full-answer export (`DSH_CONTROL_OK`). Other command paths have focused fixture coverage; full live cancellation/subagent and command/reference/attachment acceptance is not established.

Follow-up validation on 2026-10-31: 69 Swift tests and 29 DOM tests passed. Live `--long-brief reference` returned `DSH_ATTACHMENT_OK`; registered `/ponytail-help` submission settled with durable admission. Parent cancellation was verified as aborted. Full child cancellation remains unresolved: the tested child completed naturally. Native picker ownership remains fail-closed when Apple hosts the path field in another process. Strict `--long-brief attach` refuses native filesystem mentions rather than claiming uploaded bytes. The installed release and all ten shared skill links were checked.
