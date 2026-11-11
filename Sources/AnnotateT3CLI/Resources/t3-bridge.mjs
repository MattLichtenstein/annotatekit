// Mac-only OAuth/MCP adapter. Credentials never enter session bundles or the device mirror.
import { createServer } from 'node:http';
import { randomBytes, createHash, randomUUID } from 'node:crypto';
import { readFile, mkdir, writeFile, rename, chmod } from 'node:fs/promises';
import { dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

export async function privateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await chmod(dirname(path), 0o700);
  const temp = `${path}.${randomUUID()}.tmp`;
  await writeFile(temp, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  await rename(temp, path);
}

function safeOrigin(value) {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/') throw Error('Invalid T3 origin');
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname))) {
    throw Error('T3 requires HTTPS or a loopback address');
  }
  return url.origin;
}

async function jsonFetch(url, options = {}) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(30000), redirect: 'error' });
  if (!response.ok) throw Error(`T3 HTTP ${response.status}`);
  return response.json();
}

export async function login(originValue, credentialPath, announce = console.log) {
  const origin = safeOrigin(originValue);
  const metadata = await jsonFetch(`${origin}/.well-known/oauth-authorization-server`);
  // Discovery must not redirect a local credential to another host.
  for (const key of ['authorization_endpoint', 'registration_endpoint', 'token_endpoint']) {
    if (new URL(metadata[key]).origin !== origin) throw Error('OAuth endpoint changed origin');
  }
  const verifier = randomBytes(32).toString('base64url');
  const state = randomBytes(32).toString('base64url');
  let resolveCode;
  let rejectCode;
  const codePromise = new Promise((resolve, reject) => { resolveCode = resolve; rejectCode = reject; });
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname !== '/callback' || url.searchParams.get('state') !== state || url.searchParams.get('iss') !== origin) {
      res.writeHead(400); res.end('Invalid sign-in response'); return;
    }
    const code = url.searchParams.get('code');
    res.writeHead(code ? 200 : 400, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    res.end(code ? 'AnnotateKit connected. You can close this page.' : 'Sign-in was not approved.');
    if (code) resolveCode(code); else rejectCode(Error('T3 sign-in was not approved'));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const redirect = `http://127.0.0.1:${server.address().port}/callback`;
  const timeout = setTimeout(() => rejectCode(Error('T3 sign-in timed out')), 300000);
  try {
    const client = await jsonFetch(metadata.registration_endpoint, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_name: 'AnnotateKit on this Mac', redirect_uris: [redirect], token_endpoint_auth_method: 'none' })
    });
    const url = new URL(metadata.authorization_endpoint);
    const params = { response_type: 'code', client_id: client.client_id, redirect_uri: redirect, state,
      code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256',
      resource: `${origin}/mcp`, scope: 'orchestration:read orchestration:operate' };
    url.search = new URLSearchParams(params).toString();
    announce(JSON.stringify({ signInURL: url.href }));
    const code = await codePromise;
    const token = await jsonFetch(metadata.token_endpoint, {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirect,
        client_id: client.client_id, code_verifier: verifier, resource: `${origin}/mcp` })
    });
    if (!token.access_token || !Number.isFinite(token.expires_in)) throw Error('Invalid OAuth response');
    await privateJSON(credentialPath, { origin, token: token.access_token, expiresAt: Date.now() + token.expires_in * 1000,
      grantID: randomUUID() });
    announce(JSON.stringify({ connected: true }));
  } finally { clearTimeout(timeout); server.close(); }
}

/// One MCP session per invocation; request IDs are supplied by the durable receiver outbox.
export async function callTool(credentials, name, args, fetcher = fetch) {
  const origin = safeOrigin(credentials.origin);
  if (Date.now() >= credentials.expiresAt) throw Error('T3 sign-in expired; run annotate-t3 login');
  let sessionID;
  let protocol = '2025-06-18';
  let nextID = 0;
  const headers = () => ({ Accept: 'application/json, text/event-stream', 'Content-Type': 'application/json',
    Authorization: `Bearer ${credentials.token}`, 'MCP-Protocol-Version': protocol,
    ...(sessionID ? { 'Mcp-Session-Id': sessionID } : {}) });
  async function request(method, params, notification = false) {
    const id = String(++nextID);
    const response = await fetcher(`${origin}/mcp`, { method: 'POST', headers: headers(), redirect: 'error',
      signal: AbortSignal.timeout(30000), body: JSON.stringify({ jsonrpc: '2.0', ...(notification ? {} : { id }), method, params }) });
    sessionID = response.headers.get('mcp-session-id') ?? sessionID;
    if (!response.ok) throw Error(`T3 MCP HTTP ${response.status}`);
    const body = await response.text();
    if (notification) return;
    const messages = response.headers.get('content-type')?.includes('text/event-stream')
      ? body.split(/\r?\n\r?\n/).flatMap(block => {
        const data = block.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        return data ? [JSON.parse(data)] : [];
      }) : [JSON.parse(body)];
    const envelope = messages.find(message => message.id === id);
    if (!envelope || envelope.error) throw Error('T3 MCP request failed');
    return envelope.result;
  }
  try {
    const init = await request('initialize', { protocolVersion: protocol, capabilities: {},
      clientInfo: { name: 'annotatekit-mac', version: '1.0.0' } });
    protocol = init.protocolVersion;
    await request('notifications/initialized', {}, true);
    if (name === 'tools/list') return await request('tools/list', {});
    const result = await request('tools/call', { name, arguments: args });
    if (result.isError) throw Error('T3 rejected the operation');
    const value = result.structuredContent ?? JSON.parse(result.content.find(block => block.type === 'text').text);
    if (value.error || value._tag === 'OrchestratorMcpFailure') throw Error('T3 rejected the operation');
    return value;
  } finally {
    if (sessionID) await fetcher(`${origin}/mcp`, { method: 'DELETE', headers: headers(),
      signal: AbortSignal.timeout(3000) }).catch(() => {});
  }
}

async function main() {
  const [command, credentialPath, origin] = process.argv.slice(2);
  if (command === 'login') return login(origin, credentialPath);
  const credential = JSON.parse(await readFile(credentialPath, 'utf8'));
  if (command === 'tick') {
    const { tick } = await import('./t3-outbox.mjs');
    const { localDeliveryClient } = await import('./t3-rpc.mjs');
    const [, , root, projectID] = process.argv.slice(2);
    await tick(root, projectID, credential, undefined, { makeDeliveryClient: () => localDeliveryClient(credential, credentialPath) });
    console.log(JSON.stringify({ ok: true }));
    return;
  }
  if (command === 'identity') { console.log(JSON.stringify({ grantID: credential.grantID })); return; }
  let input = '';
  for await (const part of process.stdin) input += part;
  const { name, arguments: args } = JSON.parse(input);
  console.log(JSON.stringify(await callTool(credential, name, args)));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // JSON parser errors may quote input (including a damaged credential file); never print them.
  main().catch(() => {
    console.error('T3 routing unavailable. Check sign-in, server support, and interrupted-batch reconciliation. Saved batches are retained.');
    process.exitCode = 1;
  });
}
