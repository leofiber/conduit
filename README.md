# Conduit

```
                       __     _ __
   _______  ___  ___/ /_ __(_) /_
  / __/ _ \/ _ \/ _  / // / / __/
  \__/\___/_//_/\_,_/\_,_/_/\__/

   ▸▸▸  codex auth → openai-compat  ▸▸▸
```

> Bridge your ChatGPT Business / Enterprise Codex auth into any OpenAI-compatible tool.

If you have a ChatGPT Business or Enterprise plan, you already have Codex access — but Codex's tokens are scoped for Codex's private backend, **not** the public OpenAI API. So you can't drop your Codex login into [opencode](https://opencode.ai), Continue, Cursor BYOK, or anything else.

Conduit fixes that. It runs a tiny local proxy that:

- Reads your `~/.codex/auth.json` (created by `codex login`)
- Speaks the standard **OpenAI Chat Completions API** (`/v1/chat/completions`, `/v1/models`)
- Forwards each request to `https://chatgpt.com/backend-api/codex/responses` using your tokens
- Translates the Responses API event stream back into Chat Completions SSE chunks (with proper `tool_calls`, `reasoning_content`, `usage`)
- Auto-refreshes expired tokens; if refresh fails, falls back to interactive `codex login`
- Surfaces real model metadata (context window, modalities, supported reasoning levels) live from Codex's `/models` endpoint

The result: any OpenAI-compatible tool can use **gpt-5.5**, **gpt-5.4 (1M context)**, etc. — billed against your existing Business/Enterprise plan.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/install.sh | bash
```

The installer will:

1. Verify Homebrew is installed (it'll ask you to install it first if not — Conduit can't help with that)
2. Install [`codex`](https://github.com/openai/codex) and [`opencode`](https://opencode.ai) via brew if missing
3. Run `codex login` if you're not already authenticated (browser-based SSO works)
4. Drop the proxy + a wrapper into `~/.local/bin`
5. Register a `launchd` agent so the proxy runs at login and auto-restarts on crash
6. Add a `codex-proxy` provider to your `~/.config/opencode/opencode.json` (merging — your other providers are untouched)
7. Smoke-test the whole stack

After install, just run:

```bash
opencode --model codex-proxy/gpt-5.5
```

## What you get

| Feature | Status |
|---|---|
| Streaming chat completions | ✅ |
| Tool / function calling (with multi-turn) | ✅ |
| Image inputs (data URLs) | ✅ |
| Reasoning streams (`reasoning_content` deltas) | ✅ |
| Real token usage in `usage` field | ✅ |
| Live model metadata via `/v1/models` | ✅ |
| Token auto-refresh | ✅ |
| Browser fallback when refresh fails | ✅ |
| Survives reboot / crash (launchd) | ✅ |

## Models

Conduit fetches the authoritative model list from Codex on every cold start. As of today:

| Model | Context | Notes |
|---|---|---|
| `gpt-5.5` | 272K | Frontier model, default `reasoning_effort: xhigh` |
| `gpt-5.4` | up to **1M** | Strong everyday coding model, the only one with 1M context |
| `gpt-5.4-mini` | 272K | Faster, cheaper |

In opencode, address them as `codex-proxy/gpt-5.5`, `codex-proxy/gpt-5.4`, etc.

## How it works

```
┌─────────────────┐                ┌───────────────┐               ┌─────────────────────────┐
│  opencode       │  POST /v1/chat │  Conduit      │  POST /codex/ │  chatgpt.com            │
│  (or any        │ ─────────────► │  localhost:   │  responses    │  /backend-api/codex     │
│   OpenAI-compat │                │  8081         │ ────────────► │  (your tokens)          │
│   tool)         │ ◄───────────── │               │ ◄──────────── │                         │
└─────────────────┘   SSE chunks   └───────────────┘   SSE chunks  └─────────────────────────┘
                      (Chat                            (Responses
                       Completions                      API events)
                       format)
```

The proxy:
- **Translates message format** — Chat Completions `messages[]` ↔ Responses API `input[]` items, including `tool_calls` ↔ `function_call`, tool results ↔ `function_call_output`, and `image_url` ↔ `input_image`.
- **Tracks streaming state** — emits `finish_reason: tool_calls` correctly when the model invoked a tool (otherwise you get duplicated assistant turns in the UI).
- **Surfaces real usage** — extracts `input_tokens` / `output_tokens` / `cached_tokens` / `reasoning_tokens` from the `response.completed` event and emits them in the OpenAI `usage` field.
- **Refreshes tokens silently** — uses `refresh_token` grant against `auth.openai.com/oauth/token`. Updates `~/.codex/auth.json` in place, the same file `codex` uses, so the two tools stay in sync.

## Files

| Path | Purpose |
|---|---|
| `~/.local/bin/conduit-proxy` | The Python proxy |
| `~/.local/bin/opencode-codex` | Wrapper that ensures auth + proxy are healthy before launching opencode |
| `~/Library/LaunchAgents/com.leofiber.conduit.plist` | launchd agent definition |
| `~/.codex/auth.json` | Your Codex tokens (created by `codex login`, used by Conduit) |
| `/tmp/conduit.log` | Proxy logs |
| `~/.config/opencode/opencode.json` | opencode config (Conduit adds the `codex-proxy` provider) |

## Manual control

```bash
# Stop / start
launchctl bootout gui/$(id -u)/com.leofiber.conduit
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.leofiber.conduit.plist

# Restart
launchctl kickstart -k gui/$(id -u)/com.leofiber.conduit

# Tail logs
tail -f /tmp/conduit.log

# Health check
curl -s http://localhost:8081/v1/models | jq
```

## Troubleshooting

**Proxy not responding**
```bash
launchctl list | grep conduit         # status (PID + last exit code)
tail -50 /tmp/conduit.log              # check the log
launchctl kickstart -k gui/$(id -u)/com.leofiber.conduit
```

**`401 Not authenticated` / token expired**
```bash
codex login    # re-auth in browser; conduit will pick up the new tokens immediately
```

**Cost shows $0.00 in opencode**
That's not Conduit — opencode doesn't have a price-per-token table for the `codex-proxy/...` model ids. Token *counts* are accurate; only the dollar conversion is missing. Since this is a flat-rate Business/Enterprise plan, the dollar number isn't really meaningful anyway.

**Default model in opencode**
Set `"model": "codex-proxy/gpt-5.5"` in `~/.config/opencode/opencode.json`, or pass `--model codex-proxy/gpt-5.5` at runtime.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/leofiber/conduit/main/uninstall.sh | bash
```

This removes the launchd agent, binaries, and the `codex-proxy` provider from your opencode config. It does **not** touch your Codex login (`~/.codex/auth.json`) or the `codex` / `opencode` CLIs themselves.

## A note on Terms of Service

Conduit uses **your own** Codex tokens, obtained legitimately via `codex login` — the same way the official Codex CLI uses them. Requests go to the same backend, billed against the same plan; there's no scope escalation, no third-party token transfer, no rate-limit circumvention. The only "novel" thing is which client makes the request.

That said, this is unofficial. OpenAI hasn't published a public spec for the Codex backend, so nothing here is a stable contract. If you're at a company that needs a defensible answer, ask your infosec / legal team before deploying widely.

## Caveats

- **macOS only** for now (uses `launchd`). Linux port would need a `systemd --user` unit; PRs welcome.
- The Codex backend (`/codex/responses`) is private and undocumented — fields and event types could change without warning. If something breaks, file an issue.
- This is not affiliated with OpenAI in any way.

## License

MIT - see `LICENSE`.
