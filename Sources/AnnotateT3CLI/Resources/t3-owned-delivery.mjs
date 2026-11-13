// Transfers a complete feedback bundle into T3 before acknowledging any content cleanup.
import { readFile, readdir, lstat, stat, rm, mkdir } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { privateJSON } from './t3-bridge.mjs';

async function rejectLinks(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const info = await lstat(path);
    if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) throw Error('Unsafe bundle item');
    if (info.isDirectory()) await rejectLinks(path);
  }
}

async function optionalJSON(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

export async function clearOwnedBatch(root, id) {
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) throw Error('Invalid batch ID');
  const state = await optionalJSON(join(root, '.routing', `batch-${id}.json`));
  const session = await optionalJSON(join(root, 'sessions', id, 'session.json'));
  const conversationID = session?.t3Route?.conversationID ?? state?.conversationID;
  if (/^[0-9a-f-]{36}$/i.test(conversationID ?? '')) {
    const path = join(root, '.routing', `conversation-${conversationID}.json`);
    const conversation = await optionalJSON(path);
    if (conversation?.launchBatchID === id && conversation.launchArguments) {
      // Initial-message launches temporarily persist notes for exact retries; never retain them
      // in the otherwise content-free conversation mapping after T3 owns the batch.
      const { message, attachments, ...launchArguments } = conversation.launchArguments;
      await privateJSON(path, { ...conversation, launchArguments });
      // Also remove full-message atomic-write remnants left by a killed helper process.
      for (const name of await readdir(join(root, '.routing'))) {
        if (name.startsWith(`conversation-${conversationID}.json.`) && name.endsWith('.tmp')) {
          await rm(join(root, '.routing', name), { force: true });
        }
      }
    }
  }
  await rm(join(root, 'sessions', id), { recursive: true, force: true });
  await rm(join(root, 'mac-delivery', id), { recursive: true, force: true });
  await rm(join(root, 'mac-queue', `${id}.json`), { force: true });
  await rm(join(root, 'mac-errors', `${id}.json`), { force: true });
  await rm(join(root, '.routing', `batch-${id}.zip`), { force: true });
  await rm(join(root, '.routing', `batch-${id}.json`), { force: true });
  if ((await readFile(join(root, 'latest'), 'utf8').catch(() => '')).trim() === `sessions/${id}`) {
    await rm(join(root, 'latest'), { force: true });
  }
  // A receiver crash can leave a staging copy; it carries the same batch prefix.
  for (const entry of await readdir(join(root, '.incoming')).catch(() => [])) {
    if (entry.startsWith(`${id}-`)) await rm(join(root, '.incoming', entry), { recursive: true, force: true });
  }
}

export async function prepareOwnedBatch({ root, session, directory, client, state, statePath }, {
  fetcher = fetch,
  archive = (source, target) => execFileSync('/usr/bin/ditto', ['-c', '-k', '--norsrc', source, target], { stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 })
} = {}) {
  const archivePath = join(root, '.routing', `batch-${session.id}.zip`);
  await rejectLinks(directory);
  await mkdir(dirname(archivePath), { recursive: true, mode: 0o700 });
  if (!(await stat(archivePath).catch(() => null))) archive(directory, archivePath);
  const previews = session.screens?.map(screen => screen.annotatedImage).filter(path => /^screens\/[A-Za-z0-9@_.-]+\.png$/.test(path ?? '')).slice(0, 7) ?? [];
  const files = [{ path: archivePath, name: `AnnotateKit-${session.id}.zip`, type: 'file', mimeType: 'application/zip' },
    ...previews.map((path, index) => ({ path: join(directory, path), name: `Screen-${index + 1}.png`, type: 'image', mimeType: 'image/png' }))];
  state.attachments ??= [];
  for (let index = 0; index < files.length; index++) {
    if (state.attachments[index]) continue;
    const file = files[index];
    const bytes = await readFile(file.path);
    const limit = file.type === 'image' ? 10485760 : 52428800;
    if (!bytes.length || bytes.length > limit) throw Error('Feedback exceeds T3 attachment size limit');
    const prepared = await client.call('attachments.createUploadUrl', { type: file.type, name: file.name, mimeType: file.mimeType, sizeBytes: bytes.length });
    const url = new URL(prepared.relativeUrl, client.credential.origin);
    if (url.origin !== client.credential.origin) throw Error('Attachment upload changed origin');
    const uploaded = await fetcher(url, { method: 'POST', headers: { 'Content-Type': file.mimeType }, body: bytes, redirect: 'error', signal: AbortSignal.timeout(60000) });
    if (!uploaded.ok) throw Error('T3 attachment upload failed');
    await uploaded.arrayBuffer();
    state.attachments[index] = { id: prepared.attachmentId, type: file.type, name: file.name, mimeType: file.mimeType, sizeBytes: bytes.length };
    await privateJSON(statePath, state);
  }
  const prompt = await readFile(join(directory, 'prompt.md'), 'utf8');
  const message = `AnnotateKit feedback batch ${session.id}\n\nThe attached ZIP contains session.json, prompt.md, all original screenshots, crops, and chosen references. ` +
    `Extract it and open the annotated screens first. Artifact paths in prompt.md are relative to the extracted bundle. ` +
    `Make app changes in this thread's assigned checkout. app.installFile and recorded source locations identify where the app was built; ` +
    `if they point to another checkout, locate the corresponding app files in this thread's checkout. ` +
    `AnnotateKit deletes its phone/Mac content after T3 accepts this message, so use the T3 attachments for all feedback. ` +
    `Respond in this T3 thread; device status/reply files are no longer available.\n\n${prompt}`;
  return { message, attachments: state.attachments };
}

// The caller must have a durable queued-message or initial-message launch acknowledgement.
export async function acknowledgeOwnedBatch({ root, session, threadID, thread }) {
  const receipt = { version: 1, sessionID: session.id, threadID, title: thread.title ?? 'App feedback', link: thread.link ?? '', contentStoredInT3: true };
  await privateJSON(join(root, 'deliveries', `${session.id}.json`), receipt);
  await clearOwnedBatch(root, session.id);
  return receipt;
}

export async function deliverOwnedBatch(input, dependencies) {
  const { root, session, threadID, thread, client } = input;
  const { message, attachments } = await prepareOwnedBatch(input, dependencies);
  const hash = createHash('sha256').update(`${session.t3Route.projectID}:${session.t3Route.conversationID}:${session.id}`).digest('hex');
  const result = await client.call('orchestration.dispatchCommand', {
    type: 'message.dispatch', createdBy: 'user', creationSource: 'mobile',
    commandId: `annotatekit:${hash}`, messageId: `annotatekit-message:${hash}`, threadId: threadID,
    text: message, attachments, dispatchMode: { type: 'queue_after_active' }
  });
  if (!Number.isSafeInteger(result.sequence) || result.sequence < 0) throw Error('T3 did not acknowledge the feedback');
  return acknowledgeOwnedBatch({ root, session, threadID, thread });
}
