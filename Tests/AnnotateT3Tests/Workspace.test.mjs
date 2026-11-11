import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { newThreadWorkspace } from '../../Sources/AnnotateT3CLI/Resources/t3-workspace.mjs';

function fixture({ mode = 'worktree', project = {}, overrides = {}, folded = true, start = false, repo = true, pages } = {}) {
  const settings = { defaultThreadEnvMode: mode, newWorktreesStartFromOrigin: start,
    projectSettingsFolded: folded, projectSettingsOverrides: { koa: overrides } };
  const calls = [];
  const read = async () => ({ id: 'koa', workspaceRoot: '/project', ...project });
  const client = { async call(name, args) {
    calls.push({ name, args });
    if (name === 'server.getConfig') return { settings };
    return pages?.[args.cursor ?? 0] ?? { isRepo: repo, hasPrimaryRemote: true,
      refs: [{ name: 'main', isDefault: true, isRemote: false }], nextCursor: null };
  } };
  return { resolve: options => newThreadWorkspace('koa', read, client, options), calls };
}

test('uses the live app workspace setting and start-from-origin preference', async () => {
  assert.deepEqual(await fixture().resolve(), { type: 'worktree', baseRef: 'main', startFromOrigin: false });
  assert.deepEqual(await fixture({ start: true }).resolve(), { type: 'worktree', baseRef: 'main', startFromOrigin: true });
  const local = fixture({ mode: 'local' });
  assert.deepEqual(await local.resolve(), { type: 'root' });
  assert.equal(local.calls.filter(c => c.name === 'vcs.listRefs').length, 0);
});

test('honors project overrides and installed-version inheritance without restoring stale folded fields', async () => {
  assert.deepEqual(await fixture({ overrides: { defaultThreadEnvMode: 'local' } }).resolve(), { type: 'root' });
  assert.equal((await fixture({ mode: 'local', project: { defaultThreadEnvMode: 'worktree' }, folded: false }).resolve()).type, 'worktree');
  assert.equal((await fixture({ mode: 'local', project: { defaultThreadEnvMode: 'worktree' } }).resolve()).type, 'root');
  const inherited = fixture({ overrides: { defaultThreadEnvMode: null } });
  assert.equal((await inherited.resolve({ readFileMode: async () => 'worktree' })).type, 'worktree');
});

test('reads T3-compatible project-file defaults only when the setting inherits', async () => {
  const root = await mkdtemp(join(tmpdir(), 'annotate-workspace-'));
  try {
    await writeFile(join(root, 't3.json'), '{ // repository preference\n "defaultThreadEnvMode": "worktree", "url":"https://example.com", }');
    assert.equal((await fixture({ mode: null, project: { workspaceRoot: root } }).resolve()).type, 'worktree');
    await rm(join(root, 't3.json'));
    assert.deepEqual(await fixture({ mode: null, project: { workspaceRoot: root } }).resolve(), { type: 'root' });
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('uses the default branch across pages, never the current feature branch', async () => {
  const paged = fixture({ pages: {
    0: { isRepo: true, hasPrimaryRemote: true, refs: [{ name: 'feature', current: true, isDefault: false }], nextCursor: 100 },
    100: { isRepo: true, hasPrimaryRemote: true, refs: [{ name: 'master', isDefault: true }], nextCursor: null }
  } });
  assert.equal((await paged.resolve()).baseRef, 'master');
  assert.equal(paged.calls.at(-1).args.cursor, 100);
});

test('non-repositories use the project folder; unreadable or unknown settings fail closed', async () => {
  assert.deepEqual(await fixture({ repo: false }).resolve(), { type: 'root' });
  await assert.rejects(fixture({ mode: 'unknown' }).resolve(), /Unsupported/);
  await assert.rejects(newThreadWorkspace('koa', async () => ({}), null), /unavailable/);
  await assert.rejects(fixture({ pages: { 0: { isRepo: true, refs: [], nextCursor: null } } }).resolve(), /default branch/);
});
