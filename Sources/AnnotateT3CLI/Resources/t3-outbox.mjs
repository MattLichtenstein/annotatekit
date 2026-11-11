// Durable, serial Mac outbox. Only the configured project may receive these local bundles.
import { readFile, readdir, realpath, lstat } from 'node:fs/promises';
import { join, relative, isAbsolute } from 'node:path';
import { callTool, privateJSON } from './t3-bridge.mjs';
import { clearOwnedBatch, deliverOwnedBatch } from './t3-owned-delivery.mjs';
import { newThreadWorkspace } from './t3-workspace.mjs';

async function readJSON(path) {
  try { return JSON.parse(await readFile(path, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

function resultOK(result) {
  if (result.error || result._tag?.includes('Failure')) throw Error('T3 rejected delivery');
  return result;
}

export async function tick(root, projectID, credential, call = (name, args) => callTool(credential, name, args), { deliveryClient, makeDeliveryClient, deliver = deliverOwnedBatch } = {}) {
  const tools = await call('tools/list', {});
  for (const name of ['t3_thread_launch', 't3_thread_send']) {
    if (!tools.tools.find(tool => tool.name === name)?.inputSchema?.properties?.clientRequestId) {
      throw Error('This T3 version cannot safely retry annotation delivery');
    }
  }
  const catalog = resultOK(await call('t3_thread_list', { projectId: projectID, limit: 5 }));
  if (catalog.projectId !== projectID || !Array.isArray(catalog.threads)) throw Error('Unexpected T3 project');
  if (makeDeliveryClient) {
    try { deliveryClient = await makeDeliveryClient(); } catch {}
  }
  const threads = catalog.threads.filter(thread => thread.projectId === projectID).slice(0, 5).map(thread => ({
    id: thread.threadId, title: thread.title, isWorking: ['preparing', 'queued', 'starting', 'running', 'waiting'].includes(thread.status)
  }));
  await privateJSON(join(root, 't3-threads.json'), { version: 1, projectID, updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), isAvailable: true, supportsOwnedDelivery: !!deliveryClient, threads });
  let entries;
  try { entries = await readdir(join(root, 'sessions'), { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  for (const entry of entries.filter(entry => entry.isDirectory() && /^[A-Za-z0-9_-]+$/.test(entry.name)).sort((a, b) => a.name.localeCompare(b.name))) {
    const directory = join(root, 'sessions', entry.name);
    const session = await readJSON(join(directory, 'session.json'));
    if (!session) continue; // session.json commits a complete bundle.
    if (session.id !== entry.name || session.schemaVersion !== 1 || session.t3Route?.projectID !== projectID) continue;
    const route = session.t3Route;
    const delivered = await readJSON(join(root, 'deliveries', `${session.id}.json`));
    if (delivered?.version === 1 && delivered.sessionID === session.id && delivered.contentStoredInT3 === true) {
      await clearOwnedBatch(root, session.id);
      continue;
    }
    if (!/^[0-9a-f-]{36}$/i.test(route.conversationID)) throw Error('Invalid annotation route');
    if (await readJSON(join(directory, 't3-delivery.json'))) continue;
    // Never follow a substituted bundle out of the private inbox.
    const resolved = await realpath(directory);
    const displacement = relative(await realpath(root), resolved);
    if (displacement.startsWith('..') || isAbsolute(displacement)) throw Error('Bundle escaped its inbox');
    for (const file of ['session.json', 'prompt.md']) {
      if (!(await lstat(join(directory, file))).isFile()) throw Error('Invalid annotation bundle file');
    }
    const conversationPath = join(root, '.routing', `conversation-${route.conversationID}.json`);
    const attemptPath = join(root, '.routing', `batch-${session.id}.json`);
    let conversation = await readJSON(conversationPath);
    if (conversation && conversation.projectID !== projectID) throw Error('Conversation project changed');
    let threadID = route.threadID ?? conversation?.threadID;
    const appName = Array.from(session.app?.name?.trim() || 'App').slice(0, 50).join('');
    const defaultTitle = `${appName} feedback`;
    if (!threadID) {
      if (conversation && conversation.grantID !== credential.grantID) throw Error('New sign-in requires reconciling an interrupted thread creation');
      if (!conversation) {
        if (!tools.tools.find(tool => tool.name === 't3_thread_launch')?.inputSchema?.properties?.workspaceStrategy) {
          throw Error('This T3 version cannot bind annotation threads to the configured checkout');
        }
        const workspaceStrategy = await newThreadWorkspace(projectID, call, deliveryClient);
        conversation = { projectID, grantID: credential.grantID, launchArguments: {
          projectId: projectID, title: defaultTitle, workspaceStrategy,
          clientRequestId: `annotatekit-conversation-${route.conversationID}`
        } };
      }
      // Keep the exact old payload: even adding an explicit root could change its retry hash.
      conversation.launchArguments ??= { projectId: projectID, title: defaultTitle,
        clientRequestId: `annotatekit-conversation-${route.conversationID}` };
      if (conversation.launchArguments.projectId !== projectID ||
          conversation.launchArguments.clientRequestId !== `annotatekit-conversation-${route.conversationID}`) {
        throw Error('Saved launch does not match its conversation');
      }
      await privateJSON(conversationPath, conversation);
      const launched = resultOK(await call('t3_thread_launch', conversation.launchArguments));
      if (launched.projectId !== projectID || !launched.threadId) throw Error('Unexpected new thread');
      threadID = launched.threadId;
      await privateJSON(conversationPath, { ...conversation, threadID });
    }
    // Recheck an existing destination rather than trusting a stale device catalog.
    const target = resultOK(await call('t3_thread_read', { threadId: threadID, limit: 1 }));
    const thread = target.thread ?? target;
    if (thread.projectId !== projectID) throw Error('Destination is outside the configured project');
    const attempt = await readJSON(attemptPath);
    if (attempt && (attempt.grantID !== credential.grantID || attempt.threadID !== threadID)) {
      throw Error('New sign-in requires reconciling an interrupted batch');
    }
    const state = attempt ?? { grantID: credential.grantID, threadID };
    await privateJSON(attemptPath, state);
    if (route.delivery === 't3-owned-bundle-v1') {
      if (!deliveryClient) throw Error('T3 attachment delivery is unavailable; feedback retained');
      await deliver({ root, session, directory, threadID, thread, client: deliveryClient, state, statePath: attemptPath });
      continue;
    }
    const prompt = await readFile(join(directory, 'prompt.md'), 'utf8');
    const message = `AnnotateKit feedback batch ${session.id}\n\n` +
      `Complete local bundle: ${resolved}\nRead session.json, prompt.md, and the referenced images from this absolute directory. ` +
      `They are available on this Mac even when this thread uses a different checkout. ` +
      `Follow the completion instructions below. Source locations identify the app checkout. ` +
      `Delivery is queued; it does not authorize changes beyond those instructions.\n\n${prompt}`;
    const sent = resultOK(await call('t3_thread_send', { threadId: threadID, mode: 'queue', message,
      clientRequestId: `annotatekit-batch-${session.id}` }));
    if (sent.threadId !== threadID || !['queued', 'started'].includes(sent.delivery)) throw Error('T3 did not acknowledge queued delivery');
    await privateJSON(join(directory, 't3-delivery.json'), { version: 1, sessionID: session.id, threadID,
      title: thread.title ?? defaultTitle, link: thread.link ?? '' });
  }
}
