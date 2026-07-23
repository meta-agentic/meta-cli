#!/usr/bin/env node
// acp-run.mjs — minimal Agent Client Protocol (ACP) client for the meta-cli ACP lane.
//
// Speaks ACP (JSON-RPC 2.0, newline-delimited, over the agent's stdio) to a provider's
// ACP agent — e.g. `claude-code-acp` for claude. This is the warm/persistent execution
// lane described in meta-os systems/engine.md: initialize -> session/new|load ->
// session/prompt -> stream session/update, then persist the session id so the next run
// resumes warm.
//
// It is deliberately small: it borrows the *contract shape* (ACP + Paperclip's adapter
// idea), not an orchestration plane. Budget/quota enforcement is NOT here.
//
// Usage:
//   node acp-run.mjs --agent-cmd <cmd> [--agent-arg <a> ...] \
//       --prompt <text> [--cwd <dir>] [--state-dir <dir>] [--timeout <sec>] [--yolo]
//
// stdout: the agent's final assistant text (what the CLI lane would print).
// stderr: protocol diagnostics.
// exit:   0 ok; 124 timeout; 2 usage/prereq error; 1 protocol/agent error.
//
// Node >= 22.12 is required (the ACP agent packages target it). The bash caller checks
// this before invoking; we re-check so the file is safe to run standalone.

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join, resolve, relative, isAbsolute } from 'node:path';

const PROTOCOL_VERSION = 1; // ACP protocol version we negotiate

// ── node version guard ───────────────────────────────────────────────────────
function nodeAtLeast(major, minor) {
  const [ma, mi] = process.versions.node.split('.').map((n) => parseInt(n, 10));
  return ma > major || (ma === major && mi >= minor);
}
if (!nodeAtLeast(22, 12)) {
  process.stderr.write(`acp-run: Node >= 22.12 required, have ${process.versions.node}\n`);
  process.exit(2);
}

// ── args ─────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const out = { agentCmd: '', agentArgs: [], prompt: '', cwd: process.cwd(), stateDir: '', timeout: 0, yolo: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) { process.stderr.write(`acp-run: missing value for ${a}\n`); process.exit(2); }
      return argv[++i];
    };
    switch (a) {
      case '--agent-cmd': out.agentCmd = next(); break;
      case '--agent-arg': out.agentArgs.push(next()); break;
      case '--prompt': out.prompt = next(); break;
      case '--cwd': out.cwd = resolve(next()); break;
      case '--state-dir': out.stateDir = resolve(next()); break;
      case '--timeout': out.timeout = parseInt(next(), 10) || 0; break;
      case '--yolo': out.yolo = true; break;
      default: process.stderr.write(`acp-run: unknown arg ${a}\n`); process.exit(2);
    }
  }
  if (!out.agentCmd) { process.stderr.write('acp-run: --agent-cmd required\n'); process.exit(2); }
  if (!out.prompt) { process.stderr.write('acp-run: --prompt required\n'); process.exit(2); }
  return out;
}
const args = parseArgs(process.argv.slice(2));

// ── keep fs requests inside cwd (the confinement engine.md documents) ──────────
function insideCwd(p) {
  const abs = isAbsolute(p) ? p : resolve(args.cwd, p);
  const rel = relative(args.cwd, abs);
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel)) ? abs : null;
}

// ── spawn the agent ────────────────────────────────────────────────────────────
let child;
try {
  child = spawn(args.agentCmd, args.agentArgs, { cwd: args.cwd, stdio: ['pipe', 'pipe', 'inherit'] });
} catch (e) {
  process.stderr.write(`acp-run: cannot spawn agent '${args.agentCmd}': ${e.message}\n`);
  process.exit(2);
}
child.on('error', (e) => {
  process.stderr.write(`acp-run: agent process error: ${e.message}\n`);
  process.exit(2);
});

// ── JSON-RPC plumbing ───────────────────────────────────────────────────────
let nextId = 1;
const pending = new Map(); // id -> {resolve, reject}

function send(obj) {
  child.stdin.write(JSON.stringify(obj) + '\n');
}
function request(method, params) {
  const id = nextId++;
  send({ jsonrpc: '2.0', id, method, params });
  return new Promise((res, rej) => pending.set(id, { res, rej }));
}
function respond(id, result) { send({ jsonrpc: '2.0', id, result }); }
function respondError(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message } }); }

const rl = createInterface({ input: child.stdout });
let assistantText = '';

rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try { msg = JSON.parse(s); } catch { process.stderr.write(`acp-run: non-JSON line: ${s}\n`); return; }

  // Response to one of our requests
  if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      msg.error ? p.rej(new Error(msg.error.message || 'agent error')) : p.res(msg.result);
    }
    return;
  }

  // Request or notification FROM the agent
  if (msg.method) {
    handleAgentMessage(msg);
  }
});

function handleAgentMessage(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case 'session/update': {
      // Streamed content: accumulate assistant text chunks (the CLI-lane equivalent output)
      const u = params?.update;
      if (u?.sessionUpdate === 'agent_message_chunk' && u.content?.type === 'text') {
        assistantText += u.content.text;
        process.stdout.write(u.content.text);
      }
      // notifications have no id -> no response
      break;
    }
    case 'session/request_permission': {
      // Headless: allow only under --yolo, else reject the option (cancelled).
      const opt = params?.options?.[0];
      if (args.yolo && opt) respond(id, { outcome: { outcome: 'selected', optionId: opt.optionId } });
      else respond(id, { outcome: { outcome: 'cancelled' } });
      break;
    }
    case 'fs/read_text_file': {
      const abs = insideCwd(params?.path || '');
      if (!abs || !existsSync(abs)) return respondError(id, -32001, 'path not readable within cwd');
      try { respond(id, { content: readFileSync(abs, 'utf8') }); }
      catch (e) { respondError(id, -32002, e.message); }
      break;
    }
    case 'fs/write_text_file': {
      const abs = insideCwd(params?.path || '');
      if (!abs) return respondError(id, -32001, 'path not writable within cwd');
      try { writeFileSync(abs, params?.content ?? ''); respond(id, null); }
      catch (e) { respondError(id, -32002, e.message); }
      break;
    }
    default:
      // Unknown request -> method not found (per JSON-RPC). Notifications: ignore.
      if (id !== undefined) respondError(id, -32601, `method not supported: ${method}`);
  }
}

// ── session state (sessionCodec: minimal — persist the resumable id) ───────────
function loadSessionId() {
  if (!args.stateDir) return null;
  const f = join(args.stateDir, 'session.json');
  if (!existsSync(f)) return null;
  try { return JSON.parse(readFileSync(f, 'utf8')).sessionId || null; } catch { return null; }
}
function saveSessionId(sessionId) {
  if (!args.stateDir || !sessionId) return;
  mkdirSync(args.stateDir, { recursive: true });
  writeFileSync(join(args.stateDir, 'session.json'),
    JSON.stringify({ sessionId, cwd: args.cwd, protocolVersion: PROTOCOL_VERSION }, null, 2) + '\n');
}

// ── the run ────────────────────────────────────────────────────────────────
let timer;
function fail(code, why) {
  if (why) process.stderr.write(`acp-run: ${why}\n`);
  try { child.kill('SIGTERM'); } catch {}
  process.exit(code);
}

async function main() {
  if (args.timeout > 0) {
    timer = setTimeout(() => fail(124, `timed out after ${args.timeout}s`), args.timeout * 1000);
  }

  await request('initialize', {
    protocolVersion: PROTOCOL_VERSION,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
  });

  // Resume a warm session if we have one persisted, else open a new one.
  const prior = loadSessionId();
  let sessionId = prior;
  if (prior) {
    try { await request('session/load', { sessionId: prior, cwd: args.cwd, mcpServers: [] }); }
    catch (e) { process.stderr.write(`acp-run: session/load failed (${e.message}); starting fresh\n`); sessionId = null; }
  }
  if (!sessionId) {
    const r = await request('session/new', { cwd: args.cwd, mcpServers: [] });
    sessionId = r?.sessionId;
    if (!sessionId) fail(1, 'agent did not return a sessionId');
  }

  const result = await request('session/prompt', {
    sessionId,
    prompt: [{ type: 'text', text: args.prompt }],
  });

  saveSessionId(sessionId);
  if (timer) clearTimeout(timer);

  // Emit the session id on stderr as a machine-readable marker the bash caller parses.
  process.stderr.write(`acp-run: session_id=${sessionId} stop_reason=${result?.stopReason || 'end_turn'}\n`);
  if (!assistantText) process.stderr.write('acp-run: (no assistant text streamed)\n');

  try { child.kill('SIGTERM'); } catch {}
  process.exit(0);
}

main().catch((e) => fail(1, e.message || String(e)));
