// Public T3 client protocol, separate from the MCP-only OAuth audience. No T3 app changes.
import { readFile, access } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { execFileSync } from 'node:child_process';
import { privateJSON } from './t3-bridge.mjs';

const protocolVersion = 2;
export async function hostCredentials(origin, path) {
  const url = new URL(origin);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) throw Error('Host delivery requires the local T3 environment');
  const runtime = JSON.parse(await readFile(join(homedir(), '.t3/userdata/server-runtime.json'), 'utf8'));
  if (runtime.origin !== origin) throw Error('Host environment changed');
  const descriptor = await (await fetch(`${origin}/.well-known/t3/environment`, { signal: AbortSignal.timeout(10000) })).json();
  if (descriptor.orchestrationProtocolVersion !== protocolVersion) throw Error('Unsupported T3 client protocol');
  try {
    const saved = JSON.parse(await readFile(path, 'utf8'));
    if (saved.origin === origin && saved.expiresAt > Date.now() + 60000) return saved;
  } catch (error) { if (error.code !== 'ENOENT') throw Error('Invalid host credential file'); }
  // The installed matching CLI is the supported host-owner credential issuer. Never run a source
  // server/CLI against live userdata. The credential grants only orchestration read/write.
  const choices = ['T3 Code (Nightly)', 'T3 Code'];
  let app;
  for (const choice of choices) {
    const candidate = `/Applications/${choice}.app/Contents`;
    try { await access(`${candidate}/MacOS/${choice}`); app = { executable: `${candidate}/MacOS/${choice}`, entry: `${candidate}/Resources/app.asar/apps/server/dist/bin.mjs` }; break; } catch {}
  }
  if (!app) throw Error('Matching installed T3 CLI unavailable');
  const result = JSON.parse(execFileSync(app.executable, [app.entry, 'auth', 'session', 'issue',
    '--scope', 'orchestration:read', '--scope', 'orchestration:operate', '--ttl', '30d',
    '--label', 'AnnotateKit local attachment delivery', '--json'], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['ignore', 'pipe', 'pipe'], timeout: 30000
  }));
  const saved = { origin, token: result.token, sessionID: result.sessionId, expiresAt: Date.parse(result.expiresAt) };
  if (!saved.token || !saved.sessionID || !Number.isFinite(saved.expiresAt)) throw Error('Host credential issuance failed');
  await privateJSON(path, saved);
  return saved;
}

export async function callRpc(credential, method, payload, { fetcher = fetch, Socket = globalThis.WebSocket } = {}) {
  if (!Socket) throw Error('Attachment delivery requires Node 22 or newer');
  const response = await fetcher(`${credential.origin}/api/auth/websocket-ticket`, {
    method: 'POST', headers: { Authorization: `Bearer ${credential.token}` }, redirect: 'error', signal: AbortSignal.timeout(15000)
  });
  if (!response.ok) throw Error('T3 client authentication failed');
  const ticket = await response.json();
  const url = new URL('/ws', credential.origin);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('wsTicket', ticket.ticket);
  url.searchParams.set('orchestrationProtocol', String(protocolVersion));
  return new Promise((resolve, reject) => {
    const socket = new Socket(url);
    const finish = (error, value) => {
      clearTimeout(timer); socket.onclose = null; socket.close();
      if (error) reject(error); else resolve(value);
    };
    const timer = setTimeout(() => finish(Error('T3 client request timed out')), 30000);
    socket.onopen = () => socket.send(JSON.stringify({ _tag: 'Request', id: '1', tag: method, payload, headers: [] }));
    socket.onerror = () => finish(Error('T3 client connection failed'));
    socket.onclose = () => finish(Error('T3 client disconnected'));
    socket.onmessage = ({ data }) => {
      try {
        const decoded = JSON.parse(data);
        for (const row of Array.isArray(decoded) ? decoded : [decoded]) {
          if (row._tag === 'Ping') socket.send(JSON.stringify({ _tag: 'Pong' }));
          if (row._tag === 'Exit' && String(row.requestId) === '1') {
            if (row.exit?._tag !== 'Success') finish(Error('T3 rejected the client operation'));
            else finish(null, row.exit.value);
          }
        }
      } catch { finish(Error('Invalid T3 client response')); }
    };
  });
}

export async function localDeliveryClient(credential, credentialPath) {
  if (!globalThis.WebSocket) throw Error('Attachment delivery requires Node 22 or newer');
  const local = await hostCredentials(credential.origin, join(dirname(credentialPath), 't3-local-delivery.json'));
  return { credential: local, call: (method, payload) => callRpc(local, method, payload) };
}
