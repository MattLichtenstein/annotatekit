import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { tick } from '../../Sources/AnnotateT3CLI/Resources/t3-outbox.mjs';
import { acknowledgeOwnedBatch } from '../../Sources/AnnotateT3CLI/Resources/t3-owned-delivery.mjs';
import { privateJSON, callTool } from '../../Sources/AnnotateT3CLI/Resources/t3-bridge.mjs';

const conversationID = 'b76fed10-a9d8-4e6d-887a-33f7f640a999';
const credential = { grantID: 'grant-one' };
async function fixture(fn) {
  const root = await mkdtemp(join(tmpdir(), 'annotate-t3-'));
  try { await fn(root); } finally { await rm(root, { recursive: true, force: true }); }
}
async function bundle(root, id, threadID) {
  const directory = join(root, 'sessions', id);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, 'prompt.md'), 'Move the synthetic button.');
  await writeFile(join(directory, 'session.json'), JSON.stringify({ schemaVersion: 1, id,
    t3Route: { projectID: 'koa', conversationID, ...(threadID ? { threadID } : {}) } }));
  return directory;
}
function server({ loseFirstSend = false, wrongProject = false, supportsKeys = true } = {}) {
  const calls = [];
  const effects = new Map();
  let lost = false;
  return { calls, effects, async call(name, args) {
    calls.push({ name, args });
    if (name === 'tools/list') return { tools: ['t3_thread_send', 't3_thread_launch'].map(name => ({ name,
      inputSchema: { properties: supportsKeys ? { clientRequestId: {}, workspaceStrategy: {}, message: {}, attachments: {} } : {} } })) };
    if (name === 't3_thread_list') return { projectId: 'koa', threads: [] };
    if (name === 't3_project_read') return { id: 'koa', workspaceRoot: '/synthetic/project' };
    if (name === 't3_thread_read') return { thread: { projectId: wrongProject ? 'other' : 'koa', title: 'Review', link: 'local-link' } };
    if (name === 't3_thread_launch') {
      effects.set(args.clientRequestId, 'thread-new');
      return { projectId: 'koa', threadId: 'thread-new', runId: args.message ? 'initial-run' : null, status: args.message ? 'queued' : null };
    }
    if (name === 't3_thread_send') {
      effects.set(args.clientRequestId, args.message);
      if (loseFirstSend && !lost) { lost = true; throw Error('Response lost after queueing'); }
      return { delivery: 'queued', threadId: args.threadId };
    }
    throw Error('Unexpected tool');
  } };
}

test('offline batches share one new thread, use project defaults, and queue once', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one');
  await bundle(root, '20261112-010102-two');
  const remote = server();
  const deliveryClient = workspaceClient();
  await tick(root, 'koa', credential, remote.call, { deliveryClient });
  await tick(root, 'koa', credential, remote.call, { deliveryClient });
  const launches = remote.calls.filter(call => call.name === 't3_thread_launch');
  assert.equal(launches.length, 1);
  assert.deepEqual(Object.keys(launches[0].args).sort(), ['attachments', 'clientRequestId', 'message', 'projectId', 'title', 'workspaceStrategy']);
  assert.deepEqual(launches[0].args.workspaceStrategy, { type: 'worktree', baseRef: 'main', startFromOrigin: false });
  const sends = remote.calls.filter(call => call.name === 't3_thread_send');
  assert.equal(sends.length, 1);
  assert.ok(launches[0].args.message.includes('Move the synthetic button.'));
  assert.ok(sends.every(call => call.args.mode === 'queue' && call.args.threadId === 'thread-new'));
  assert.ok(sends[0].args.message.includes(join(root, 'sessions', '20261112-010102-two')));
}));

test('lost acknowledgement retries with the same idempotency key', async () => fixture(async root => {
  const directory = await bundle(root, '20261112-010101-one', 'existing');
  const remote = server({ loseFirstSend: true });
  await assert.rejects(tick(root, 'koa', credential, remote.call));
  await assert.rejects(readFile(join(directory, 't3-delivery.json')));
  await tick(root, 'koa', credential, remote.call);
  const sends = remote.calls.filter(call => call.name === 't3_thread_send');
  assert.equal(sends.length, 2);
  assert.equal(sends[0].args.clientRequestId, sends[1].args.clientRequestId);
  assert.equal(remote.effects.size, 1);
  assert.equal(JSON.parse(await readFile(join(directory, 't3-delivery.json'))).threadID, 'existing');
}));

test('sign-in replacement holds ambiguous delivery instead of duplicating', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one', 'existing');
  const remote = server({ loseFirstSend: true });
  await assert.rejects(tick(root, 'koa', credential, remote.call));
  await assert.rejects(tick(root, 'koa', { grantID: 'replacement' }, remote.call), /reconciling/);
  assert.equal(remote.calls.filter(call => call.name === 't3_thread_send').length, 1);
}));

test('rechecks current project and refuses an older non-idempotent T3 server', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one', 'existing');
  const wrong = server({ wrongProject: true });
  await assert.rejects(tick(root, 'koa', credential, wrong.call), /outside/);
  assert.equal(wrong.calls.filter(call => call.name === 't3_thread_send').length, 0);
  const old = server({ supportsKeys: false });
  await assert.rejects(tick(root, 'koa', credential, old.call), /safely retry/);
  assert.equal(old.calls.length, 1);
}));

test('private JSON writes replace atomically and restrict local permissions', async () => fixture(async root => {
  const path = join(root, 'auth', 'credentials.json');
  await privateJSON(path, { token: 'fake' });
  await privateJSON(path, { token: 'replacement' });
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.equal((await stat(join(root, 'auth'))).mode & 0o777, 0o700);
  assert.equal(JSON.parse(await readFile(path)).token, 'replacement');
}));

test('MCP initializes, handles JSON/SSE, and closes transport without leaking credentials', async () => {
  const calls = [];
  const fetcher = async (_url, options) => {
    calls.push(options);
    if (options.method === 'DELETE') return new Response(null, { status: 204 });
    const request = JSON.parse(options.body);
    if (request.method === 'notifications/initialized') return new Response(null, { status: 202 });
    const result = request.method === 'initialize' ? { protocolVersion: '2025-06-18' }
      : { structuredContent: { threads: [] } };
    return new Response(`data: ${JSON.stringify({ jsonrpc: '2.0', id: request.id, result })}\n\n`, {
      headers: { 'content-type': 'text/event-stream', 'mcp-session-id': 'mock-session' }
    });
  };
  const result = await callTool({ origin: 'http://127.0.0.1:3773', token: 'fake-token', expiresAt: Date.now() + 10000 }, 't3_thread_list', {}, fetcher);
  assert.deepEqual(result, { threads: [] });
  assert.equal(calls.at(-1).method, 'DELETE');
  assert.equal(calls[2].headers['Mcp-Session-Id'], 'mock-session');
  await assert.rejects(callTool({ origin: 'http://untrusted.example', expiresAt: Infinity }, 'x', {}, fetcher), /HTTPS/);
});


test('owned delivery is capability-gated and never falls back to a deletable file reference', async () => fixture(async root => {
  const directory = await bundle(root, '20261112-010101-owned', 'existing');
  const path = join(directory, 'session.json');
  const session = JSON.parse(await readFile(path));
  session.t3Route.delivery = 't3-owned-bundle-v1';
  session.app = { name: 'Synthetic App' };
  await writeFile(path, JSON.stringify(session));
  const remote = server();
  await assert.rejects(tick(root, 'koa', credential, remote.call), /retained/);
  assert.equal(remote.calls.filter(call => call.name === 't3_thread_send').length, 0);
  assert.equal((await stat(path)).isFile(), true);
  let delivered;
  await tick(root, 'koa', credential, remote.call, { deliveryClient: { fake: true }, deliver: async input => { delivered = input; } });
  assert.equal(delivered.threadID, 'existing');
  assert.equal(delivered.session.t3Route.delivery, 't3-owned-bundle-v1');
  assert.equal(JSON.parse(await readFile(join(root, 't3-threads.json'))).supportsOwnedDelivery, true);
}));

test('local host credentials are not requested when OAuth project authorization fails', async () => fixture(async root => {
  const remote = server();
  let requested = false;
  const call = (name, args) => name === 't3_thread_list' ? Promise.reject(Error('Unauthorized')) : remote.call(name, args);
  await assert.rejects(tick(root, 'koa', credential, call, { makeDeliveryClient: async () => { requested = true; } }));
  assert.equal(requested, false);
}));


function workspaceClient() {
  const settings = { defaultThreadEnvMode: 'worktree', newWorktreesStartFromOrigin: false, projectSettingsFolded: true };
  const calls = [];
  return { settings, calls, async call(name) {
    calls.push(name);
    if (name === 'server.getConfig') return { settings };
    if (name === 'vcs.listRefs') return { isRepo: true, hasPrimaryRemote: true, refs: [{ name: 'main', isDefault: true, isRemote: false }], nextCursor: null };
    throw Error('Unexpected client operation');
  } };
}

test('an ambiguous new-thread launch keeps the same checkout choice after T3 settings change', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one');
  const remote = server();
  const deliveryClient = workspaceClient();
  let lost = false;
  const call = async (name, args) => {
    const result = await remote.call(name, args);
    if (name === 't3_thread_launch' && !lost) { lost = true; throw Error('Lost launch response'); }
    return result;
  };
  await assert.rejects(tick(root, 'koa', credential, call, { deliveryClient }));
  deliveryClient.settings.defaultThreadEnvMode = 'local';
  await tick(root, 'koa', credential, call, { deliveryClient });
  const launches = remote.calls.filter(c => c.name === 't3_thread_launch');
  assert.deepEqual(launches[0].args, launches[1].args);
  assert.equal(launches[1].args.workspaceStrategy.type, 'worktree');
  assert.equal(deliveryClient.calls.filter(n => n === 'server.getConfig').length, 1);
}));

test('new-thread settings failures retain feedback without silently launching in the root', async () => fixture(async root => {
  const directory = await bundle(root, '20261112-010101-one');
  const remote = server();
  await assert.rejects(tick(root, 'koa', credential, remote.call), /settings.*unavailable/);
  assert.equal(remote.calls.filter(c => c.name === 't3_thread_launch').length, 0);
  assert.equal((await stat(join(directory, 'session.json'))).isFile(), true);
}));

test('pre-upgrade interrupted launches preserve their original root binding', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one');
  await privateJSON(join(root, '.routing', `conversation-${conversationID}.json`), { projectID: 'koa', grantID: credential.grantID });
  const remote = server();
  await tick(root, 'koa', credential, remote.call);
  assert.equal(remote.calls.find(c => c.name === 't3_thread_launch').args.workspaceStrategy, undefined);
}));


test('a server lacking explicit workspace binding cannot silently create a root thread', async () => fixture(async root => {
  await bundle(root, '20261112-010101-one');
  const remote = server();
  const call = async (name, args) => {
    const result = await remote.call(name, args);
    if (name === 'tools/list') delete result.tools.find(t => t.name === 't3_thread_launch').inputSchema.properties.workspaceStrategy;
    return result;
  };
  await assert.rejects(tick(root, 'koa', credential, call, { deliveryClient: workspaceClient() }), /configured checkout/);
  assert.equal(remote.calls.filter(c => c.name === 't3_thread_launch').length, 0);
}));


async function ownedBundle(root, id) {
  const directory = await bundle(root, id);
  const path = join(directory, 'session.json');
  const session = JSON.parse(await readFile(path));
  session.t3Route.delivery = 't3-owned-bundle-v1';
  await writeFile(path, JSON.stringify(session));
  return directory;
}
async function preparedFeedback({ state, statePath }) {
  await privateJSON(statePath, state);
  return { message: 'Fix: soften the screen glow.', attachments: [{ id: 'upload-one', type: 'file', name: 'feedback.zip', mimeType: 'application/zip', sizeBytes: 42 }] };
}

test('new owned feedback is the opening message so T3 names its branch from the actual task', async () => fixture(async root => {
  const id = '20261112-010101-owned';
  const directory = await ownedBundle(root, id);
  const remote = server();
  await tick(root, 'koa', credential, remote.call, { deliveryClient: workspaceClient(), prepare: preparedFeedback,
    deliver: async () => { throw Error('Opening feedback must not be queued twice'); } });
  const launch = remote.calls.find(c => c.name === 't3_thread_launch').args;
  assert.equal(launch.message, 'Fix: soften the screen glow.');
  assert.equal(launch.attachments[0].id, 'upload-one');
  assert.equal(launch.workspaceStrategy.branch, undefined); // T3's naming policy owns the name.
  assert.equal(remote.calls.filter(c => c.name === 't3_thread_send').length, 0);
  assert.equal(JSON.parse(await readFile(join(root, 'deliveries', `${id}.json`))).contentStoredInT3, true);
  await assert.rejects(stat(directory));
  const conversation = JSON.parse(await readFile(join(root, '.routing', `conversation-${conversationID}.json`)));
  assert.equal(conversation.threadID, 'thread-new');
  assert.equal(conversation.launchArguments.message, undefined);
  assert.equal(conversation.launchArguments.attachments, undefined);
}));

test('lost opening-message acknowledgement retries the exact launch without uploading or sending twice', async () => fixture(async root => {
  const directory = await ownedBundle(root, '20261112-010101-owned');
  const remote = server();
  let lost = false;
  let prepared = 0;
  const call = async (name, args) => {
    const result = await remote.call(name, args);
    if (name === 't3_thread_launch' && !lost) { lost = true; throw Error('Lost acknowledgement'); }
    return result;
  };
  const options = { deliveryClient: workspaceClient(), prepare: async input => { prepared++; return preparedFeedback(input); } };
  await assert.rejects(tick(root, 'koa', credential, call, options));
  assert.equal((await stat(directory)).isDirectory(), true);
  await tick(root, 'koa', credential, call, options);
  const launches = remote.calls.filter(c => c.name === 't3_thread_launch');
  assert.deepEqual(launches[0].args, launches[1].args);
  assert.equal(prepared, 1);
  assert.equal(remote.calls.filter(c => c.name === 't3_thread_send').length, 0);
}));

test('failure to save an opening-message receipt resumes cleanup without dispatching another message', async () => fixture(async root => {
  await ownedBundle(root, '20261112-010101-owned');
  const remote = server();
  let acknowledgements = 0;
  const options = { deliveryClient: workspaceClient(), prepare: preparedFeedback,
    acknowledge: async input => {
      if (++acknowledgements === 1) throw Error('Receipt write failed');
      return acknowledgeOwnedBatch(input);
    }, deliver: async () => { throw Error('Duplicate dispatch'); } };
  await assert.rejects(tick(root, 'koa', credential, remote.call, options));
  await tick(root, 'koa', credential, remote.call, options);
  assert.equal(remote.calls.filter(c => c.name === 't3_thread_launch').length, 1);
  assert.equal(acknowledgements, 2);
}));

test('an idle-only launch acknowledgement cannot authorize opening-feedback cleanup', async () => fixture(async root => {
  const directory = await ownedBundle(root, '20261112-010101-owned');
  const remote = server();
  const call = async (name, args) => {
    const result = await remote.call(name, args);
    return name === 't3_thread_launch' ? { ...result, runId: null } : result;
  };
  await assert.rejects(tick(root, 'koa', credential, call, { deliveryClient: workspaceClient(), prepare: preparedFeedback }), /initial feedback/);
  assert.equal((await stat(directory)).isDirectory(), true);
  await assert.rejects(readFile(join(root, 'deliveries', '20261112-010101-owned.json')));
}));
