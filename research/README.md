# Research: in-process Cursor host (parked)

This directory contains an experimental Node host that loads the Cursor agent
bundle once and tries to drive turns via Cursor's internal `pw.client.run`
transport directly, with the goal of removing the per-turn `agent --print`
cold-spawn (~18s) tax on the proxy.

## Why it's parked

`pw.client.run(ctx, asyncIterable, opts)` is the connect-rpc bidi transport
under Cursor's `me.run` orchestration layer. Calling it in isolation:
- opens an HTTP/2 stream to `agent.v1.AgentService/Run`
- the server returns immediately with an empty body (closed cleanly with no
  events)
- our iterator finishes with zero messages

`agent --print` works in seconds because `runChat` (in
`./src/commands/chat.ts` of the bundle) instantiates a full collaborator
graph - `ControlledConversationActionManager`, an interaction responder
(`{sendUpdate, query}`), a checkpoint manager, an exec resource registry
populated with local read/write/grep/ls/shell/etc. implementations, an MCP
lease, statsig/analytics/telemetry init, etc. - and then calls
`me.run(ctx, conversationState, action, modelDetails,
interactionResponder, resources, blobStore,
conversationActionManager, checkpointManager,
mcpToolDescriptors, options)`.

Replicating that graph in our embedded VM would require either:

1. Calling `runChat` directly. It hard-depends on Ink/React (TTY render
   paths) and statsig/analytics flushers; running it headlessly outside
   the agent CLI is non-trivial and unstable across `agent` updates.
2. Hand-rolling the collaborator graph. That's a LOT of surface (every
   exec resource, the React-shaped agent store, hook executor, MCP
   lease) and equally fragile.

The pivot we shipped instead is a pre-warmed `agent --print` worker pool,
which keeps each turn under single-digit seconds without reaching into
Cursor internals. See `bin/conduit-cursor-proxy` for that.

If anyone picks this back up, the entry points are:

- `agent --print --output-format stream-json` is the closest reference
  flow; instrument it with `CURSOR_DEBUG=1` to see how `runChat`
  constructs collaborators.
- `pw = require('./src/client.ts').hO(credentialManager, opts)`; the
  exec resource registry is `agent-exec/dist/index.js`'s `v` class
  (export `h`); the controlled exec manager is `n6` (export `h`).
- `agent-core/dist/index.js` exports `hg` (the
  `ControlledConversationActionManager` / interaction responder).
- The full 11-arg `me.run` call site is in `7434.index.js` (search for
  `agentClient.run(F,`); the compact 10-arg variant is in
  `7414.index.js`.

The bundle layout drifts every release, so any in-process approach must
be expressed in terms of `typeName` lookups rather than minified export
names.
