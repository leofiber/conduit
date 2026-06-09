# How it works (deep dive)

This document walks through the implementation details for anyone curious about
the protocol bridging or who wants to fix something.

## The core mismatch

**Codex CLI** authenticates via OAuth (browser SSO), stores tokens in `~/.codex/auth.json`,
and talks to `https://chatgpt.com/backend-api/codex/responses` using the [Responses API].
The tokens are scoped for that backend; they return `403/500` against the public
`https://api.openai.com/v1/...` endpoints.

**OpenAI-compatible tools** (opencode, Continue, Cursor BYOK, the AI SDK ecosystem)
expect the [Chat Completions API] format — a different request shape, a different
streaming event vocabulary.

Conduit converts between the two, in both directions, on the fly.

## Request translation (Chat Completions → Responses API)

| OpenAI field | Codex field | Notes |
|---|---|---|
| `messages[].role == "system"` | `instructions` (top-level string) | All system messages joined with `\n\n` |
| `messages[].role == "user"` (string) | `input[]: {type: "message", role: "user", content: [{type: "input_text", text: ...}]}` | |
| `messages[].role == "user"` (array w/ images) | same, with `input_image` parts | `image_url.url` (data URLs ok) → `input_image.image_url` |
| `messages[].role == "assistant"` (text) | `input[]: {type: "message", role: "assistant", content: [{type: "output_text", text: ...}]}` | |
| `messages[].role == "assistant".tool_calls[]` | `input[]: {type: "function_call", call_id, name, arguments}` | One per tool call |
| `messages[].role == "tool"` | `input[]: {type: "function_call_output", call_id, output}` | |
| `tools[]: {type: "function", function: {...}}` | `tools[]: {type: "function", name, description, parameters, strict}` | flattened |
| `tool_choice` | `tool_choice` | passed through |
| `parallel_tool_calls` | `parallel_tool_calls` | passed through |
| (none) | `store: false` | required by Codex |
| (none) | `stream: true` | required by Codex (always, even for non-streaming clients) |
| (none) | `reasoning: {effort, summary}` | derived from model variant or `reasoning_effort` request field |

## Response translation (Responses API SSE → Chat Completions SSE)

The Codex stream emits dozens of event types. Conduit only forwards the ones
opencode's AI SDK consumes:

| Codex event | OpenAI chunk |
|---|---|
| `response.created` | (drop) |
| `response.in_progress` | (drop) |
| `response.output_item.added` (type=`function_call`) | `delta.tool_calls[0]: {index, id, type, function: {name, arguments: ""}}` |
| `response.function_call_arguments.delta` | `delta.tool_calls[0]: {index, function: {arguments: <delta>}}` |
| `response.output_text.delta` | `delta: {content: <delta>}` |
| `response.reasoning_summary_text.delta` | `delta: {reasoning_content: <delta>, reasoning: <delta>}` |
| `response.completed` | final chunk: `delta: {}, finish_reason: "stop"` or `"tool_calls"`, plus `usage` |

Two stateful tracks across the stream:

- **`has_tool_calls`**: set when we see `response.output_item.added` with `type=function_call`. Used to choose `finish_reason`. The naive approach (looking at `response.completed.response.output[]`) doesn't work because that array comes back empty in streaming mode — we have to track it as it happens.
- **`usage`**: extracted from `response.completed.response.usage` and emitted in the final OpenAI chunk per [the OpenAI streaming spec][stream-options].

## Non-streaming clients

Even if the client sends `stream: false`, Conduit *still* requests `stream: true` from
Codex (Codex always streams). It collects all the deltas into a buffer, then returns
a single `chat.completion` response with the assembled text + tool_calls + usage.

## Auth / token refresh

`auth.json` looks like this:

```json
{
  "auth_mode": "chatgpt",
  "last_refresh": "...",
  "tokens": {
    "id_token":      "<JWT>",
    "access_token":  "<JWT>",   // sent as Bearer to the backend
    "refresh_token": "rt.1.AAD...",
    "account_id":    "..."
  }
}
```

Conduit's `TokenManager`:

1. **On startup**: parse the `id_token` JWT, extract `chatgpt_account_id` for the `ChatGPT-Account-Id` request header.
2. **Before each request**: check if the access token expires within 5 minutes. If so, refresh.
3. **Refresh**: `POST https://auth.openai.com/oauth/token` with `grant_type=refresh_token`, the same `client_id` Codex uses (`app_EMoamEEZ73f0CkXaXp7hrann`), and the same scopes. Update `auth.json` in place.
4. **On 401**: same refresh path. If that fails, fall back to `codex login` (browser).

The refresh writes to the same `~/.codex/auth.json` Codex itself uses, so the two
tools share state — log in via either one, and the other picks it up immediately.

## Model metadata

`GET https://chatgpt.com/backend-api/codex/models?client_version=0.138.0` returns
the authoritative model list with `context_window`, `max_context_window`,
`input_modalities`, `supported_reasoning_levels`, etc.

Conduit caches this for 1 hour and surfaces it via `/v1/models`, so any
OpenAI-compatible tool can introspect the real numbers (not whatever I would
have guessed).

## launchd

The plist registers a `LaunchAgent` (per-user, not system-wide) with:

- `RunAtLoad: true` — start when you log in
- `KeepAlive: { Crashed: true, SuccessfulExit: false }` — restart on crash, don't restart on graceful shutdown
- `ThrottleInterval: 10` — don't restart faster than once every 10 seconds (avoids tight loops)
- `ProcessType: Background` — let the kernel deprioritize it
- Logs to `/tmp/conduit.log`

[Responses API]: https://platform.openai.com/docs/api-reference/responses
[Chat Completions API]: https://platform.openai.com/docs/api-reference/chat
[stream-options]: https://platform.openai.com/docs/api-reference/chat/create#chat-create-stream_options
