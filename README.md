# Conduit (Cursor edition)

```
                   ____                             __
  _______  _______/ __ \____ ___  _________  _____/ /
 / ___/ / / / ___/ / / / __ `/ / / / ___/ / / / __/
/ /__/ /_/ / /  / /_/ / /_/ / /_/ / /  / /_/ / /_
\___/\__,_/_/   \____/\__,_/\__,_/_/   \__,_/\__/

   ▸▸▸  cursor agent auth → opencode harness  ▸▸▸
```

Use your native **Cursor Agent** auth and models (Kimi K2.5, Composer 2.5,
Gemini 3 Flash, Auto) through the **opencode** UI.

Conduit runs a small local adapter on `http://localhost:8091/v1` that:

- speaks OpenAI-style `POST /v1/chat/completions`
- shells out to `agent --print --output-format stream-json` for each turn
- translates Cursor's NDJSON event stream into OpenAI-compatible streaming
  chunks (assistant text + reasoning deltas + tool activity markers)
- preserves Cursor's auth, billing/usage, and model selection

This repo is **Cursor-specific**.

## What works today

End-to-end through `opencode` against the cursor-proxy provider, verified by
`tests/e2e.sh`:

| category                | tool surface                               | status |
| ----------------------- | ------------------------------------------ | ------ |
| plain chat              | text + reasoning deltas + usage            | ok     |
| file read               | Cursor `Read` tool                         | ok     |
| file write + run        | Cursor `Write` + `Shell`                   | ok     |
| file edit               | Cursor `Edit`                              | ok     |
| grep / glob / ls        | Cursor `Grep`, `Glob`, `Ls`                | ok     |
| delete                  | Cursor `Delete`                            | ok     |
| web fetch               | Cursor `WebFetch` / `Fetch`                | ok     |
| subagent / task         | Cursor `Task` / subagent                   | ok     |
| MCP servers             | any Cursor-loaded MCP (`~/.cursor/mcp.json` or workspace `.cursor/mcp.json`) | ok |
| inline images           | passed through as workspace files          | ok     |

Reasoning is surfaced as OpenAI `reasoning_content` deltas. Tool activity is
surfaced as inline `[tool:Name] args (id=...)` markers in the same channel so
opencode shows you what Cursor is doing per turn.

## Architecture

```
            ┌────────────┐  HTTP /v1/chat/completions   ┌──────────────────────┐
opencode ───▶ Conduit Cursor Proxy ───spawns subprocess▶ agent --print
            │ (Python, port 8091)                      │  --output-format     │
            └────────────┘ ◀── NDJSON stream-json ─────┤  stream-json         │
                                                       └──────────────────────┘
```

Cursor Agent is the **tool runner** for this turn. The proxy:

- builds a single prompt from opencode's OpenAI-style messages (system +
  transcript + tool transcript)
- saves any inline image data-URLs into the workspace and references them
- spawns `agent --print --output-format stream-json --trust --force --workspace
  <ws> --model <id>` with `cwd=<ws>` so workspace `.cursor/mcp.json` is found
- maps Cursor's events to OpenAI Chat Completions:
  - `thinking.delta` ➝ `delta.reasoning_content`
  - `tool_call` started/completed ➝ `delta.reasoning_content` markers
  - `assistant` text content ➝ `delta.content`
  - `result` ➝ final chunk + `usage`
- supports both streaming (`stream:true`) and non-streaming responses
- reports real `prompt_tokens` / `completion_tokens` / `cached_tokens` from
  Cursor's `result.usage`

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/install.sh | bash
```

The installer:

1. checks that `brew` exists (required)
2. requires either the standalone `agent` CLI or `cursor` CLI on PATH
3. installs `opencode` if missing
4. runs `agent login` (or `cursor agent login`) if you're not authenticated
5. installs `conduit-cursor-proxy` and `conduit-cursor-run` into `~/.local/bin`
6. registers a `launchd` agent so the proxy auto-starts at login and on crash
7. adds a `cursor-proxy` provider into your opencode config

Then run:

```bash
opencode --model cursor-proxy/kimi-k2.5
```

Or use the helper that re-checks Cursor auth and ensures the proxy is up:

```bash
conduit-cursor-run
```

## Configuration

Environment variables understood by `bin/conduit-cursor-proxy`:

| variable                  | default              | meaning                                   |
| ------------------------- | -------------------- | ----------------------------------------- |
| `CONDUIT_CURSOR_PORT`     | `8091`               | listen port                               |
| `AGENT_BIN`               | `agent`              | standalone Cursor Agent binary            |
| `CURSOR_BIN`              | `cursor`             | fallback (`cursor agent ...`)             |
| `CURSOR_MODEL`            | `kimi-k2.5`          | model used when request omits `model`     |
| `CONDUIT_CURSOR_WORKSPACE`| `$HOME`              | workspace for the spawned agent           |
| `CONDUIT_FORCE_TOOLS`     | `1`                  | pass `--force` to agent (auto-approve)    |
| `CONDUIT_LOG_REQUESTS`    | unset                | if `1`, log inbound requests to a file    |

The workspace can also be set per-request via:

- HTTP header `X-Conduit-Workspace: /path/to/repo`
- request body fields `workspace`, `metadata.workspace`, or `user`

## Tests

A full end-to-end suite lives at `tests/e2e.sh`:

```bash
bash tests/e2e.sh
```

It exercises the proxy through `opencode` against a clean
`/tmp/conduit-e2e` workspace and verifies each tool category produces the
expected real filesystem effect (file written, file deleted, MCP tool
returns its runtime-loaded secret, etc.).

To exercise MCP, the test installs a tiny stdio MCP server
(`tests/echo-mcp.py`) into `<workspace>/.cursor/mcp.json` and approves it via
`agent mcp enable conduit-echo`.

## Why a local proxy at all

Cursor Agent does **not** expose an OpenAI-compatible API. It emits its own
NDJSON event stream. opencode expects an OpenAI-compatible backend. Conduit is
the translation layer:

`opencode → conduit-cursor-proxy → agent (Cursor)`

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/uninstall.sh | bash
```

This removes Conduit's launchd job, binaries, and the `cursor-proxy` provider
entry from your opencode config. It does **not** log you out of Cursor.
