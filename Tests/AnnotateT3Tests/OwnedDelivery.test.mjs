import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deliverOwnedBatch, acknowledgeOwnedBatch } from '../../Sources/AnnotateT3CLI/Resources/t3-owned-delivery.mjs';
import { callRpc } from '../../Sources/AnnotateT3CLI/Resources/t3-rpc.mjs';

async function fixture(fn) {
  const root = await mkdtemp(join(tmpdir(), 'annotate-owned-'));
  const id = '20261112-120000-test';
  const directory = join(root, 'sessions', id);
  await mkdir(join(directory, 'screens'), { recursive: true });
  await writeFile(join(directory, 'prompt.md'), 'Move the synthetic button.');
  await writeFile(join(directory, 'screens/1.png'), 'synthetic-pixels');
  const session = { id, t3Route: { projectID: 'koa', conversationID: 'b76fed10-a9d8-4e6d-887a-33f7f640a999' }, screens: [{ annotatedImage: 'screens/1.png' }] };
  await writeFile(join(directory, 'session.json'), JSON.stringify(session));
  const state = { grantID: 'stable-grant', threadID: 'thread' };
  const options = { root, directory, session, state, statePath: join(root, '.routing', `batch-${id}.json`), threadID: 'thread', thread: { title: 'App feedback' } };
  let count = 0;
  const calls = [];
  const client = { credential: { origin: 'http://127.0.0.1:3773' }, call: async (name, args) => {
    calls.push({ name, args });
    if (name === 'attachments.createUploadUrl') return { attachmentId: `file-${++count}`, relativeUrl: `/upload/${count}` };
    return { sequence: 10 };
  } };
  const archive = (_source, target) => { return target; };
  // Production uses ditto. The test keeps deterministic bytes without duplicating its implementation.
  await mkdir(join(root, '.routing'), { recursive: true });
  await writeFile(join(root, '.routing', `batch-${id}.zip`), 'complete-synthetic-bundle');
  try { await fn({ ...options, client }, { archive, fetcher: async () => new Response(null, { status: 200 }) }, calls); }
  finally { await rm(root, { recursive: true, force: true }); }
}

test('uploads all content before queueing and deletes only after a durable T3 acknowledgement', async () => fixture(async (input, dependencies, calls) => {
  const receipt = await deliverOwnedBatch(input, dependencies);
  const dispatch = calls.find(call => call.name === 'orchestration.dispatchCommand').args;
  assert.equal(dispatch.attachments.length, 2);
  assert.equal(dispatch.dispatchMode.type, 'queue_after_active');
  assert.equal(dispatch.threadId, 'thread');
  assert.ok(dispatch.text.includes("Make app changes in this thread's assigned checkout"));
  assert.equal(receipt.contentStoredInT3, true);
  await assert.rejects(readFile(join(input.directory, 'prompt.md')));
  await assert.rejects(readFile(input.statePath));
  assert.equal(JSON.parse(await readFile(join(input.root, 'deliveries', `${input.session.id}.json`))).contentStoredInT3, true);
}));

test('lost queue response retains content and retries the identical command and attachment IDs', async () => fixture(async (input, dependencies) => {
  const original = input.client.call;
  const sends = [];
  input.client.call = async (name, args) => {
    if (name === 'orchestration.dispatchCommand') {
      sends.push(args);
      if (sends.length === 1) throw Error('Lost acknowledgement');
    }
    return original(name, args);
  };
  await assert.rejects(deliverOwnedBatch(input, dependencies));
  assert.equal(await readFile(join(input.directory, 'prompt.md'), 'utf8'), 'Move the synthetic button.');
  input.state = JSON.parse(await readFile(input.statePath));
  await deliverOwnedBatch(input, dependencies);
  assert.deepEqual(sends[0], sends[1]);
}));

test('failed uploads and malformed acknowledgements preserve source feedback', async () => fixture(async (input, dependencies) => {
  await assert.rejects(deliverOwnedBatch(input, { ...dependencies, fetcher: async () => new Response(null, { status: 500 }) }));
  assert.equal(await readFile(join(input.directory, 'prompt.md'), 'utf8'), 'Move the synthetic button.');
  const original = input.client.call;
  input.client.call = (name, args) => name === 'orchestration.dispatchCommand' ? Promise.resolve({}) : original(name, args);
  await assert.rejects(deliverOwnedBatch(input, dependencies));
  assert.equal(await readFile(join(input.directory, 'prompt.md'), 'utf8'), 'Move the synthetic button.');
}));

test('refuses symbolic links before copying a bundle into T3', async () => fixture(async (input, dependencies, calls) => {
  await symlink('/etc/hosts', join(input.directory, 'escaped'));
  await assert.rejects(deliverOwnedBatch(input, dependencies), /Unsafe/);
  assert.equal(calls.length, 0);
}));

test('RPC handles the public unary protocol', async () => {
  const messages = [];
  class Socket {
    constructor() { queueMicrotask(() => this.onopen()); }
    send(value) {
      messages.push(JSON.parse(value));
      if (messages.at(-1)._tag === 'Request') queueMicrotask(() => this.onmessage({ data: JSON.stringify({ _tag: 'Exit', requestId: '1', exit: { _tag: 'Success', value: { sequence: 42 } } }) }));
    }
    close() {}
  }
  const result = await callRpc({ origin: 'http://127.0.0.1:3773', token: 'fake' }, 'orchestration.dispatchCommand', { fake: true }, {
    Socket, fetcher: async () => Response.json({ ticket: 'fake-ticket' })
  });
  assert.equal(result.sequence, 42);
  assert.equal(messages[0].tag, 'orchestration.dispatchCommand');
});


test('RPC rejects a dropped connection without authorizing content deletion', async () => {
  class DroppedSocket {
    constructor() { queueMicrotask(() => this.onopen()); }
    send() { queueMicrotask(() => this.onclose?.()); }
    close() {}
  }
  await assert.rejects(callRpc({ origin: 'http://127.0.0.1:3773', token: 'fake' }, 'orchestration.dispatchCommand', {}, {
    Socket: DroppedSocket, fetcher: async () => Response.json({ ticket: 'fake-ticket' })
  }), /disconnected/);
});


test('confirmed cleanup scrubs opening notes even when the shared session directory was already cleared', async () => fixture(async input => {
  const conversationID = input.session.t3Route.conversationID;
  input.state.conversationID = conversationID;
  await writeFile(input.statePath, JSON.stringify(input.state));
  const path = join(input.root, '.routing', `conversation-${conversationID}.json`);
  await writeFile(path, JSON.stringify({ launchBatchID: input.session.id, threadID: 'thread',
    launchArguments: { title: 'App feedback', message: 'Private feedback text', attachments: [{ id: 'attachment' }], workspaceStrategy: { type: 'worktree' } } }));
  const temporary = `${path}.interrupted.tmp`;
  const unrelated = join(input.root, '.routing', 'conversation-unrelated.json.interrupted.tmp');
  await writeFile(temporary, 'Private feedback text');
  await writeFile(unrelated, 'Unrelated pending feedback');
  await rm(input.directory, { recursive: true });
  await acknowledgeOwnedBatch(input);
  const retained = JSON.parse(await readFile(path));
  assert.equal(retained.launchArguments.message, undefined);
  assert.equal(retained.launchArguments.attachments, undefined);
  assert.equal(retained.launchArguments.workspaceStrategy.type, 'worktree');
  await assert.rejects(readFile(temporary));
  assert.equal(await readFile(unrelated, 'utf8'), 'Unrelated pending feedback');
  await assert.rejects(readFile(input.statePath));
}));
