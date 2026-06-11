#!/usr/bin/env node
/* eslint-disable */
/**
 * Conduit Cursor Host
 *
 * Long-lived Node process that loads Cursor's `agent` bundle once and serves
 * many turns over stdio JSON-RPC, removing the cold-spawn tax that shelling
 * out to `agent --print` per turn would otherwise pay.
 *
 * Wire format (NDJSON over stdio):
 *
 *   request:
 *     {"id": <number>, "kind": "run",
 *      "prompt": "...",
 *      "model": "kimi-k2.5",
 *      "workspace": "/abs/path",
 *      "session_id": "<existing-cursor-session-id-or-null>"}
 *
 *   responses (multiple per request, all tagged with the same id):
 *     {"id":1,"event":"system_init", "session_id":"..."}
 *     {"id":1,"event":"thinking_delta","text":"..."}
 *     {"id":1,"event":"text_delta","text":"..."}
 *     {"id":1,"event":"tool_started","name":"Read","args":{...},"call_id":"..."}
 *     {"id":1,"event":"tool_completed","name":"Read","call_id":"..."}
 *     {"id":1,"event":"result", "text":"...","usage":{...}}
 *     {"id":1,"event":"error", "message":"..."}
 *
 *   ready signal at startup:
 *     {"event":"ready","model_default":"composer-2.5","models":[...]}
 *
 * Concurrent requests are serialized: only ONE active turn at a time. The
 * proxy gates concurrency anyway, so this is fine.
 */

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const readline = require('node:readline');
const { MessagePort, MessageChannel } = require('node:worker_threads');
const { randomUUID, webcrypto } = require('node:crypto');
const streamWeb = require('node:stream/web');

// ---------------------------------------------------------------------------
// IPC helpers
// ---------------------------------------------------------------------------

function emit(obj) {
  try {
    process.stdout.write(JSON.stringify(obj) + '\n');
  } catch (e) {
    process.exit(0);
  }
}

function logDebug(...args) {
  if (process.env.CONDUIT_HOST_DEBUG === '1') {
    process.stderr.write('[host] ' + args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ') + '\n');
  }
}

function findLatestBundle() {
  const explicit = process.env.CURSOR_AGENT_BUNDLE;
  if (explicit && fs.existsSync(explicit)) return explicit;
  const root = path.join(require('node:os').homedir(), '.local', 'share', 'cursor-agent', 'versions');
  if (!fs.existsSync(root)) {
    throw new Error('cursor-agent versions dir not found at ' + root);
  }
  const versions = fs.readdirSync(root).sort();
  if (!versions.length) throw new Error('no cursor-agent versions installed');
  return path.join(root, versions[versions.length - 1], 'index.js');
}

// ---------------------------------------------------------------------------
// Async iterable used as the request half of the bidi run
// ---------------------------------------------------------------------------

class PushAsyncIterable {
  constructor() {
    this.queue = [];
    this.waiters = [];
    this.done = false;
    this.error = null;
    this._nextCalls = 0;
    this._pushes = 0;
  }
  push(value) {
    if (this.done) throw new Error('stream closed');
    this._pushes++;
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      process.stderr.write('[host] PushAsyncIterable.push #' + this._pushes + '\n');
    }
    if (this.waiters.length) {
      this.waiters.shift().resolve({ value, done: false });
      return;
    }
    this.queue.push(value);
  }
  end() {
    this.done = true;
    while (this.waiters.length) this.waiters.shift().resolve({ value: undefined, done: true });
  }
  fail(err) {
    this.error = err;
    this.done = true;
    while (this.waiters.length) this.waiters.shift().reject(err);
  }
  [Symbol.asyncIterator]() { return this; }
  next() {
    this._nextCalls++;
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      process.stderr.write('[host] PushAsyncIterable.next() #' + this._nextCalls + ' queue=' + this.queue.length + ' done=' + this.done + '\n');
    }
    if (this.queue.length) return Promise.resolve({ value: this.queue.shift(), done: false });
    if (this.error) return Promise.reject(this.error);
    if (this.done) return Promise.resolve({ value: undefined, done: true });
    return new Promise((resolve, reject) => this.waiters.push({ resolve, reject }));
  }
  return() { this.end(); return Promise.resolve({ value: undefined, done: true }); }
  throw(err) { this.fail(err); return Promise.reject(err); }
}

// ---------------------------------------------------------------------------
// Bundle loader (vm.runInNewContext) + minimal browser-like globals
// ---------------------------------------------------------------------------

class BareEvent {
  constructor(type, init = {}) { this.type = type; Object.assign(this, init); }
}
class BareEventTarget {
  addEventListener() {} removeEventListener() {} dispatchEvent() { return true; }
}

function loadBundle(bundlePath) {
  let src = fs.readFileSync(bundlePath, 'utf8');
  src = src.replace(
    'var __webpack_exports__=__webpack_require__("./src/main.tsx")})();',
    'globalThis.__cursor_require__=__webpack_require__;})();'
  );
  const ctx = {
    require, process, console, Buffer,
    setTimeout, clearTimeout, setInterval, clearInterval, setImmediate, clearImmediate,
    URL, URLSearchParams, TextEncoder, TextDecoder,
    AbortController, AbortSignal,
    Headers, Request, Response, fetch, FormData, Blob, File,
    ReadableStream: globalThis.ReadableStream || streamWeb.ReadableStream,
    WritableStream: globalThis.WritableStream || streamWeb.WritableStream,
    TransformStream: globalThis.TransformStream || streamWeb.TransformStream,
    crypto: webcrypto,
    queueMicrotask, performance, structuredClone,
    Event: globalThis.Event || BareEvent,
    EventTarget: globalThis.EventTarget || BareEventTarget,
    DOMException: globalThis.DOMException,
    MessagePort, MessageChannel,
  };
  ctx.global = ctx; ctx.globalThis = ctx; ctx.__filename = bundlePath; ctx.__dirname = path.dirname(bundlePath);
  vm.runInNewContext(src, ctx, { filename: bundlePath, timeout: 60000 });
  return ctx.__cursor_require__;
}

// ---------------------------------------------------------------------------
// Cursor client construction
// ---------------------------------------------------------------------------

function makeClient(req) {
  const clientMod = req('./src/client.ts');
  const credMod = req('../cli-credentials/dist/index.js');

  const credentialManager = credMod.jo({ domain: 'cursor', inMemory: false });

  const cfgPath = path.join(require('node:os').homedir(), '.cursor', 'cli-config.json');
  if (!fs.existsSync(cfgPath)) {
    throw new Error('Cursor CLI config not found at ' + cfgPath + '. Run `agent login` first.');
  }
  const data = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  const provider = {
    get() { return data; },
    async transform(fn) { Object.assign(data, fn(data)); },
  };

  const cfg = provider.get();
  const pw = clientMod.hO(credentialManager, {
    backendUrl: cfg.serverConfigCache.backendUrl,
    configProvider: provider,
    serverHttp2Config: cfg.serverConfigCache.serverHttp2Config,
    serverAgentUrlConfig: cfg.serverConfigCache.agentUrlConfig,
    insecure: false,
  });
  return { pw, configProvider: provider, credentialManager };
}

function makeRequestHelpers(req) {
  return {
    svc: req('../proto/dist/generated/agent/v1/agent_service_pb.js'),
    pb: req('../proto/dist/generated/agent/v1/agent_pb.js'),
    execPb: req('../proto/dist/generated/agent/v1/exec_pb.js'),
    reqCtxPb: req('../proto/dist/generated/agent/v1/request_context_exec_pb.js'),
    kvMod: req('../agent-kv/dist/index.js'),
    contextMod: req('../context/dist/index.js'),
    agentExec: req('../agent-exec/dist/index.js'),
    mcpPb: req('../proto/dist/generated/agent/v1/mcp_pb.js'),
    utils: req('../utils/dist/index.js'),
  };
}

async function fetchModels(req, pw) {
  try {
    const svc = req('../proto/dist/generated/agent/v1/agent_service_pb.js');
    const contextMod = req('../context/dist/index.js');
    const root = contextMod.q6().withName('conduit-cursor-host.models');
    const headers = new Headers({ 'x-request-id': randomUUID() });
    const usable = await pw.client.getUsableModels(root, new svc.KD({ customModelIds: [] }), { headers });
    const def = await pw.client.getDefaultModelForCli(root, new svc.Tu({}), { headers });
    const list = (usable.usableModels || usable.models || []).map((m) => m.modelId || m.id || String(m));
    const dflt = (def && (def.defaultModelId || def.modelId)) || list[0] || 'composer-2.5';
    return { models: list, default: dflt };
  } catch (e) {
    return { models: ['auto', 'composer-2.5', 'gemini-3-flash', 'kimi-k2.5'], default: 'composer-2.5' };
  }
}

// ---------------------------------------------------------------------------
// Per-turn driver
// ---------------------------------------------------------------------------

async function runTurn(state, req, msg) {
  const { svc, pb, execPb, reqCtxPb, kvMod, contextMod, agentExec, mcpPb, utils } = state.helpers;
  const turnId = msg.id;
  const prompt = String(msg.prompt || '').slice(0, 200000);
  const workspace = String(msg.workspace || process.cwd());
  const model = String(msg.model || state.defaultModel || 'composer-2.5');
  const sessionId = msg.session_id || randomUUID();

  const send = (event, extra = {}) => emit(Object.assign({ id: turnId, event }, extra));

  // Use the bundle's own writable-iterable factory: that's what the bundle's
  // connect-rpc bidi-wrapper expects on the request-half of the stream.
  const input = utils.createWritableIterable();

  // KV side-channel using Cursor's own controlled KV manager.
  const kvServer = new PushAsyncIterable();
  const kvClientWriter = {
    write(message) {
      input.write(new svc.KS({ message: { case: 'kvClientMessage', value: message } }));
      return Promise.resolve();
    },
  };
  const kvStore = new kvMod.ve();
  const kvMgr = new kvMod.hC(kvServer, kvClientWriter, kvStore);
  const ctxRoot = contextMod.q6().withName('conduit-cursor-host.run');
  const kvRunPromise = kvMgr.run(ctxRoot.withName('kv'));

  // Build the AgentRunRequest. Match the exact shape `agent --print` sends:
  // requestedModel only (no modelDetails), explicit empty mcpTools wrapper,
  // and selectedSubagentModels=[default, composer-2.5{fast:false}].
  const runReq = new pb.AgentRunRequest({
    conversationState: new pb.ConversationStateStructure({}),
    action: new pb.ConversationAction({
      action: { case: 'userMessageAction', value: new pb.UserMessageAction({
        userMessage: new pb.UserMessage({
          text: prompt,
          messageId: randomUUID(),
          mode: pb.AgentMode?.AGENT ?? 1,
        }),
      }) },
    }),
    mcpTools: new mcpPb.Or({ mcpTools: [] }),
    requestedModel: new pb.RequestedModel({ modelId: model }),
    selectedSubagentModels: [
      new pb.RequestedModel({ modelId: 'default' }),
      new pb.RequestedModel({
        modelId: 'composer-2.5',
        parameters: [new pb.RequestedModel_ModelParameterValue({ id: 'fast', value: 'false' })],
      }),
    ],
    conversationId: sessionId,
    conversationGroupId: sessionId,
  });
  input.write(new svc.KS({ message: { case: 'runRequest', value: runReq } }));
  // PROBE: try ending the request half immediately so the server starts streaming.
  // If this is the issue, we'll see events flow. (We'll re-add ongoing input later.)
  if (process.env.CONDUIT_HOST_PROBE_HALF_CLOSE === '1') {
    input.close();
  }

  send('system_init', { session_id: sessionId, model });

  const ac = new AbortController();
  const requestId = randomUUID();
  const headers = new Headers({ 'x-request-id': requestId, 'x-original-request-id': requestId });

  let resp;
  try {
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      process.stderr.write('[host] pw keys=[' + Object.keys(state.pw || {}).join(',') + ']\n');
      process.stderr.write('[host] pw.client keys=[' + Object.keys((state.pw && state.pw.client) || {}).join(',') + ']\n');
    }
    resp = await state.pw.client.run(ctxRoot, input, { headers });
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      const ownKeys = Object.keys(resp || {});
      const hasIter = !!(resp && resp[Symbol.asyncIterator]);
      const hasMessage = !!(resp && resp.message);
      const messageHasIter = !!(resp && resp.message && resp.message[Symbol.asyncIterator]);
      process.stderr.write('[host] run() -> ownKeys=[' + ownKeys.join(',') + '] hasIter=' + hasIter + ' hasMessage=' + hasMessage + ' msgHasIter=' + messageHasIter + '\n');
    }
  } catch (e) {
    send('error', { message: 'pw.client.run failed: ' + (e && e.message || String(e)) });
    kvServer.end(); input.close();
    try { await kvRunPromise; } catch {}
    return;
  }

  const stream = resp && resp[Symbol.asyncIterator] ? resp : resp && resp.message;
  if (!stream || !stream[Symbol.asyncIterator]) {
    send('error', { message: 'run() did not return an async iterable' });
    kvServer.end(); input.close();
    try { await kvRunPromise; } catch {}
    return;
  }

  // Manually drive the iterator so we can see exactly when/where it ends.
  const iter = stream[Symbol.asyncIterator]();
  let resultText = '';
  let usage = null;
  let assistantBuf = '';
  let nMsgs = 0;

  try {
    while (true) {
      let result;
      try {
        if (process.env.CONDUIT_HOST_DEBUG === '1') process.stderr.write('[host] awaiting iter.next() ...\n');
        result = await iter.next();
      } catch (e) {
        if (process.env.CONDUIT_HOST_DEBUG === '1') process.stderr.write('[host] iter.next() THREW: ' + (e && (e.stack || e.message) || String(e)) + '\n');
        throw e;
      }
      if (process.env.CONDUIT_HOST_DEBUG === '1') {
        process.stderr.write('[host] iter.next() done=' + result.done + ' valueType=' + (result.value && (result.value.constructor && result.value.constructor.name)) + '\n');
      }
      if (result.done) break;
      const m = result.value;
      nMsgs++;
      const top = m.message?.case;
      if (process.env.CONDUIT_HOST_DEBUG === '1') {
        process.stderr.write('[host] msg ' + top
          + (top === 'execServerMessage' ? ' inner=' + (m.message.value.message?.case) : '')
          + (top === 'interactionUpdate' ? ' upd=' + (m.message.value.update?.case) : '')
          + '\n');
      }

      if (top === 'kvServerMessage') {
        kvServer.push(m.message.value);
        continue;
      }

      if (top === 'execServerMessage') {
        const exec = m.message.value;
        const inner = exec.message?.case;
        if (inner === 'requestContextArgs') {
          const reqCtx = new reqCtxPb.bb({
            env: new reqCtxPb.GE({
              osVersion: process.platform,
              workspacePaths: [workspace],
              shell: (process.env.SHELL || 'zsh').split('/').pop(),
              sandboxEnabled: false,
              projectFolder: workspace,
              timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            }),
            envInfoComplete: true,
            rulesInfoComplete: true,
            repositoryInfoComplete: true,
            customSubagentsInfoComplete: true,
            agentSkillsInfoComplete: true,
            mcpFileSystemInfoComplete: true,
            gitStatusInfoComplete: true,
            mcpInfoComplete: true,
            gitRepoInfoComplete: true,
          });
          const reqCtxResult = new reqCtxPb._G({ result: { case: 'success', value: new reqCtxPb.yW({ requestContext: reqCtx }) } });
          input.write(new svc.KS({ message: { case: 'execClientMessage', value: new execPb.yT({
            id: exec.id, execId: exec.execId,
            message: { case: 'requestContextResult', value: reqCtxResult },
          }) } }));
          input.write(new svc.KS({ message: { case: 'execClientControlMessage', value: new execPb.$Y({
            message: { case: 'streamClose', value: new execPb.D9({ id: exec.id }) },
          }) } }));
          continue;
        }
        send('tool_unhandled', { inner });
        continue;
      }

      if (top === 'interactionUpdate') {
        const upd = m.message.value.update;
        const c = upd?.case;
        if (c === 'textDelta') {
          const text = upd.value.text || '';
          resultText += text;
          assistantBuf += text;
          send('text_delta', { text });
        } else if (c === 'thinkingDelta') {
          const text = upd.value.text || '';
          send('thinking_delta', { text });
        } else if (c === 'toolCallStarted') {
          send('tool_started', {});
        } else if (c === 'toolCallCompleted') {
          send('tool_completed', {});
        } else if (c === 'turnEnded') {
          const v = upd.value;
          usage = {
            input_tokens: v.inputTokens ? Number(v.inputTokens) : 0,
            output_tokens: v.outputTokens ? Number(v.outputTokens) : 0,
            cache_read_tokens: v.cacheReadTokens ? Number(v.cacheReadTokens) : 0,
            cache_write_tokens: v.cacheWriteTokens ? Number(v.cacheWriteTokens) : 0,
          };
        }
        continue;
      }
    }
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      process.stderr.write('[host] iteration finished. total messages=' + nMsgs + '\n');
    }
    send('result', { text: resultText, usage, session_id: sessionId });
  } catch (e) {
    if (process.env.CONDUIT_HOST_DEBUG === '1') {
      process.stderr.write('[host] iteration error: ' + (e && e.stack || e) + '\n');
    }
    send('error', { message: e && e.message || String(e) });
  } finally {
    kvServer.end();
    input.close();
    try { await kvRunPromise; } catch {}
  }
}

// ---------------------------------------------------------------------------
// Top-level main loop
// ---------------------------------------------------------------------------

async function main() {
  const t0 = Date.now();
  const bundlePath = findLatestBundle();
  logDebug('loading bundle', bundlePath);
  const req = loadBundle(bundlePath);
  const { pw, configProvider, credentialManager } = makeClient(req);
  const helpers = makeRequestHelpers(req);
  const meta = await fetchModels(req, pw);
  const state = { pw, configProvider, credentialManager, helpers, defaultModel: meta.default };
  emit({ event: 'ready', boot_ms: Date.now() - t0, model_default: meta.default, models: meta.models });

  const rl = readline.createInterface({ input: process.stdin });
  let queue = Promise.resolve();
  rl.on('line', (line) => {
    line = line.trim();
    if (!line) return;
    let msg;
    try { msg = JSON.parse(line); } catch (e) {
      emit({ event: 'error', message: 'invalid JSON on stdin: ' + e.message });
      return;
    }
    if (msg.kind === 'shutdown') {
      emit({ event: 'goodbye' });
      process.exit(0);
    }
    if (msg.kind === 'run') {
      queue = queue.then(() => runTurn(state, req, msg)).catch((err) => {
        emit({ id: msg.id, event: 'error', message: 'turn failed: ' + (err && err.message || String(err)) });
      });
      return;
    }
    emit({ id: msg.id, event: 'error', message: 'unknown kind: ' + msg.kind });
  });
  rl.on('close', () => process.exit(0));
}

main().catch((e) => {
  process.stderr.write('host fatal: ' + (e && e.stack || e) + '\n');
  process.exit(1);
});
