// Resolves T3's new-thread workspace preference once, before an idempotent launch is persisted.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

async function projectFileMode(root) {
  let contents;
  try { contents = await readFile(join(root, 't3.json'), 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return 'local'; throw error; }
  // Match T3's lenient JSON reader: preserve strings while removing comments and trailing commas.
  const stripped = contents.replace(/("(?:[^"\\]|\\.)*")|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
    (match, string) => string ? match : ' ').replace(/("(?:[^"\\]|\\.)*")|,(\s*[}\]])/g,
    (match, string, bracket) => string ? match : bracket);
  const file = JSON.parse(stripped);
  return file.defaultThreadEnvMode ?? 'local';
}

export async function newThreadWorkspace(projectID, call, client, { readFileMode = projectFileMode } = {}) {
  if (!client) throw Error('T3 workspace settings are unavailable; feedback retained');
  const project = await call('t3_project_read', { projectId: projectID });
  if (project.id !== projectID || typeof project.workspaceRoot !== 'string' || !project.workspaceRoot) {
    throw Error('Unexpected T3 project workspace');
  }
  const { settings } = await client.call('server.getConfig', {});
  if (!settings || typeof settings.newWorktreesStartFromOrigin !== 'boolean') throw Error('Unsupported T3 workspace settings');
  const overrides = settings.projectSettingsOverrides?.[projectID] ?? {};
  // Older servers expose project fields directly; folded settings use only the override record.
  let mode = settings.defaultThreadEnvMode;
  if (!settings.projectSettingsFolded && project.defaultThreadEnvMode != null) mode = project.defaultThreadEnvMode;
  if (Object.hasOwn(overrides, 'defaultThreadEnvMode')) mode = overrides.defaultThreadEnvMode;
  if (mode == null) mode = await readFileMode(project.workspaceRoot);
  if (mode === 'local') return { type: 'root' };
  if (mode !== 'worktree') throw Error('Unsupported T3 workspace preference');
  const startFromOrigin = overrides.newWorktreesStartFromOrigin ?? settings.newWorktreesStartFromOrigin;
  if (typeof startFromOrigin !== 'boolean') throw Error('Unsupported T3 worktree preference');

  // Let T3 create/bind the checkout. Read its default ref; never make a shell worktree or use HEAD.
  let cursor;
  let remoteDefault;
  const seen = new Set();
  while (true) {
    const page = await client.call('vcs.listRefs', { cwd: project.workspaceRoot, limit: 100, ...(cursor == null ? {} : { cursor }) });
    if (page.isRepo === false) return { type: 'root' }; // Matches T3's non-repository behavior.
    if (page.isRepo !== true || !Array.isArray(page.refs)) throw Error('T3 branch defaults are unavailable');
    const local = page.refs.find(ref => ref.isDefault && !ref.isRemote && typeof ref.name === 'string' && ref.name);
    if (local) return { type: 'worktree', baseRef: local.name, startFromOrigin: startFromOrigin && page.hasPrimaryRemote === true };
    remoteDefault ??= page.refs.find(ref => ref.isDefault && ref.isRemote && typeof ref.name === 'string' && ref.name);
    if (page.nextCursor == null) break;
    if (!Number.isSafeInteger(page.nextCursor) || seen.has(page.nextCursor)) throw Error('Invalid T3 branch pagination');
    seen.add(page.nextCursor);
    cursor = page.nextCursor;
  }
  if (startFromOrigin && remoteDefault) return { type: 'worktree', baseRef: remoteDefault.name, startFromOrigin: true };
  throw Error('T3 default branch is unavailable; feedback retained');
}
