import {createHash, createHmac} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {checksum, detectSupportedFile, processTransportCycle, TELEGRAM_MAX_FILE_BYTES} from './worker-core.mjs';

const api = (process.env.FP_API_URL || 'http://127.0.0.1:54321/rest/v1').replace(/\/$/, '');
const gateway = (process.env.FP_GATEWAY_URL || 'http://127.0.0.1:3300').replace(/\/$/, '');
const botAPI = (process.env.TELEGRAM_API_BASE_URL || 'https://api.telegram.org').replace(/\/$/, '');
const botIdentity = process.env.TELEGRAM_BOT_IDENTITY || '';
const token = process.env.TELEGRAM_BOT_TOKEN || '';
const jwtIssuer = process.env.JWT_EXPECTED_ISSUER || 'familydocuments';

function b64url(value) { return Buffer.from(value).toString('base64url'); }
function signedJwt(secret, role = 'service_role', subject, familyID) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({alg: 'HS256', typ: 'JWT'}));
  const claims = {role, aud: 'authenticated', iss: jwtIssuer, iat: now, nbf: now - 5, exp: now + 300};
  if (subject) claims.sub = subject;
  if (familyID) claims.family_id = familyID;
  const payload = b64url(JSON.stringify(claims));
  const unsigned = `${header}.${payload}`;
  return `${unsigned}.${createHmac('sha256', secret).update(unsigned).digest('base64url')}`;
}
async function secret() {
  if (process.env.GOTRUE_JWT_SECRET) return process.env.GOTRUE_JWT_SECRET;
  const contents = await readFile(new URL('../.env.local', import.meta.url), 'utf8');
  const line = contents.split(/\r?\n/).find(value => value.startsWith('GOTRUE_JWT_SECRET='));
  if (!line) throw new Error('GOTRUE_JWT_SECRET is required');
  return line.slice(line.indexOf('=') + 1).trim();
}
async function post(url, body, bearer, timeout = 15000) {
  const response = await fetch(url, {method: 'POST', headers: {authorization: `Bearer ${bearer}`, 'content-type': 'application/json'}, body: JSON.stringify(body), signal: AbortSignal.timeout(timeout)});
  const parsed = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error('service request failed');
  return parsed;
}
async function rpc(name, body, bearer) { return post(`${api}/rpc/${name}`, body, bearer); }
async function gatewayPost(path, body, bearer, timeout) { return post(`${gateway}${path}`, body, bearer, timeout); }

function messageParts(update) {
  const envelope = update.envelope || {};
  const message = envelope.message;
  const callback = envelope.callback_query;
  if (message) return {message, user: String(message.from?.id || ''), chat: String(message.chat?.id || ''), text: String(message.text || message.caption || '').trim()};
  return {callback, user: String(callback?.from?.id || ''), chat: String(callback?.message?.chat?.id || ''), text: ''};
}

async function downloadAttachment(message) {
  const document = message.document;
  const photo = Array.isArray(message.photo) ? message.photo.at(-1) : null;
  const selected = document || photo;
  if (!selected?.file_id) return null;
  if (Number(selected.file_size || 0) > TELEGRAM_MAX_FILE_BYTES) throw new Error('file too large');
  const metadata = await post(`${botAPI}/bot${token}/getFile`, {file_id: selected.file_id}, '', 10000);
  const filePath = String(metadata.result?.file_path || '');
  if (!filePath || filePath.includes('..')) throw new Error('invalid file path');
  const response = await fetch(`${botAPI}/file/bot${token}/${filePath}`, {signal: AbortSignal.timeout(20000)});
  if (!response.ok) throw new Error('download failed');
  const declaredLength = Number(response.headers.get('content-length') || 0);
  if (declaredLength > TELEGRAM_MAX_FILE_BYTES) throw new Error('file too large');
  const bytes = Buffer.from(await response.arrayBuffer());
  const mime = detectSupportedFile(bytes);
  if (!mime) throw new Error('unsupported or mismatched attachment');
  if (document?.mime_type && document.mime_type !== mime) throw new Error('mime mismatch');
  return {bytes, mime, name: String(document?.file_name || `telegram-${message.message_id}.${mime === 'application/pdf' ? 'pdf' : mime === 'image/png' ? 'png' : 'jpg'}`).slice(0, 255), sha256: checksum(bytes)};
}

function response(updateID, text, buttons) {
  const presentation = {text: String(text).slice(0, 2000)};
  if (buttons?.length) presentation.buttons = buttons.slice(0, 6);
  return {request_key: `telegram:${updateID}:reply`, ...presentation};
}

async function ensureConversation(context, updateID, userToken, serviceToken, user, chat) {
  if (context.conversation_id) return context.conversation_id;
  const created = await rpc('start_conversation', {request_id: `telegram-new-${updateID}`}, userToken);
  await rpc('bind_telegram_conversation', {bot_identity: botIdentity, telegram_user: user, telegram_chat: chat, conversation: created.id}, serviceToken);
  return created.id;
}

async function createAdapter() {
  if (!botIdentity || !token) throw new Error('Telegram worker configuration is incomplete');
  const jwtSecret = await secret();
  const serviceToken = signedJwt(jwtSecret);
  return {
    claimUpdates: size => rpc('claim_telegram_updates', {bot_identity: botIdentity, batch_size: size}, serviceToken),
    completeUpdate: (id, lease, outcome, responses) => rpc('complete_telegram_update', {update_record: id, worker_lease: lease, outcome, responses}, serviceToken),
    failUpdate: (id, lease, retryable, outcome) => rpc('fail_telegram_update', {update_record: id, worker_lease: lease, retryable, outcome}, serviceToken),
    claimOutbox: size => rpc('claim_telegram_outbox', {bot_identity: botIdentity, batch_size: size}, serviceToken),
    completeOutbox: (id, lease, providerMessage) => rpc('complete_telegram_outbox', {outbox_record: id, worker_lease: lease, provider_message: providerMessage}, serviceToken),
    failOutbox: (id, lease, retryable) => rpc('fail_telegram_outbox', {outbox_record: id, worker_lease: lease, retryable}, serviceToken),
    async send(item) {
      const result = await post(`${botAPI}/bot${token}/sendMessage`, {chat_id: item.chat_id, text: item.presentation?.text || 'FamilyDocuments updated.', reply_markup: item.presentation?.buttons ? {inline_keyboard: item.presentation.buttons.map(button => [{text: button.label, callback_data: button.nonce}])} : undefined}, '', 10000);
      return result.result?.message_id || 'sent';
    },
    async handleUpdate(update) {
      const parts = messageParts(update);
      if (parts.callback) {
        const bound = await rpc('consume_telegram_callback', {bot_identity: botIdentity, telegram_user: parts.user, telegram_chat: parts.chat, nonce: String(parts.callback.data || '')}, serviceToken);
        const userToken = signedJwt(jwtSecret, 'authenticated', bound.user_id, bound.family_id);
        if (bound.type === 'confirmation') {
          const outcome = await gatewayPost('/conversation/decision', {confirmation_id: bound.reference_id, decision: bound.value || 'confirm'}, userToken);
          return {outcome: 'handled', responses: [response(update.update_id, outcome.message || (outcome.state === 'succeeded' ? 'Done.' : 'Your request was updated.'))]};
        }
        return {outcome: 'handled', responses: [response(update.update_id, 'That choice is no longer available.')]};
      }
      if (/^\/start\s+/.test(parts.text)) {
        const raw = parts.text.replace(/^\/start\s+/, '').trim();
        if (!/^[A-Za-z0-9_-]{40,60}$/.test(raw)) return {outcome: 'unlinked', responses: [response(update.update_id, 'That connection link is invalid or expired. Create a new one in FamilyDocuments Settings.')]};
        const digest = createHash('sha256').update(raw).digest('hex');
        await rpc('consume_telegram_link_token', {bot_identity: botIdentity, link_hash: digest, telegram_user: parts.user, telegram_chat: parts.chat, metadata: {display_name: [parts.message.from?.first_name, parts.message.from?.last_name].filter(Boolean).join(' ').slice(0, 120), username: String(parts.message.from?.username || '').slice(0, 80)}}, serviceToken);
        return {outcome: 'handled', responses: [response(update.update_id, 'Telegram is connected to FamilyDocuments. Send /help to see what I can do.')]};
      }
      const context = await rpc('telegram_transport_context', {bot_identity: botIdentity, telegram_user: parts.user, telegram_chat: parts.chat}, serviceToken);
      if (!context.linked) return {outcome: 'unlinked', responses: [response(update.update_id, 'Sign in to FamilyDocuments and connect Telegram from Settings first.')]};
      if (parts.text === '/help' || parts.text === '/start') return {outcome: 'handled', responses: [response(update.update_id, 'I can find saved information, save links and documents, read a document when asked, and help with reminders.')]};
      if (parts.text === '/status') return {outcome: 'handled', responses: [response(update.update_id, `Active Family: ${context.family_name}.`)]};
      const userToken = signedJwt(jwtSecret, 'authenticated', context.user_id, context.family_id);
      const conversationID = await ensureConversation(context, update.update_id, userToken, serviceToken, parts.user, parts.chat);
      if (parts.text === '/new') {
        const created = await rpc('start_conversation', {request_id: `telegram-new-${update.update_id}`}, userToken);
        await rpc('bind_telegram_conversation', {bot_identity: botIdentity, telegram_user: parts.user, telegram_chat: parts.chat, conversation: created.id}, serviceToken);
        return {outcome: 'handled', responses: [response(update.update_id, 'Started a new FamilyDocuments conversation.')]};
      }
      const attachment = await downloadAttachment(parts.message);
      let attachmentID;
      if (attachment) {
        const staged = await gatewayPost('/conversation/attachment', {conversation_id: conversationID, file_name: attachment.name, mime_type: attachment.mime, content_base64: attachment.bytes.toString('base64')}, userToken, 30000);
        attachmentID = staged.id || staged.attachment_id;
      }
      const messageText = parts.text || (attachment ? 'Save this document' : '');
      if (!messageText) return {outcome: 'unsupported', responses: [response(update.update_id, 'I can help organise and find information in your FamilyDocuments account.')]};
      await rpc('append_conversation_message', {conversation: conversationID, client_message_id: `telegram-user-${update.update_id}`, message_role: 'user', message_kind: attachment ? 'attachment' : 'text', message_content: messageText, message_data: attachmentID ? {references: [], attachment_id: attachmentID, file_name: attachment.name} : {}}, userToken);
      const interpreted = await gatewayPost('/conversation/interpret', {message: messageText, context: {has_attachment: Boolean(attachmentID), attachment_id: attachmentID || '', references: []}}, userToken);
      const outcome = await gatewayPost('/conversation/action', {conversation_id: conversationID, request_key: `telegram-action-${update.update_id}`, action: interpreted.action, proposal_token: interpreted.proposal_token}, userToken);
      if (outcome.state === 'awaiting_confirmation' && outcome.confirmation_id) {
        const yes = await rpc('create_telegram_callback', {identity_link: context.identity_link_id, conversation: conversationID, callback_kind: 'confirmation', reference: outcome.confirmation_id, value: 'confirm'}, serviceToken);
        const no = await rpc('create_telegram_callback', {identity_link: context.identity_link_id, conversation: conversationID, callback_kind: 'confirmation', reference: outcome.confirmation_id, value: 'cancel'}, serviceToken);
        return {outcome: 'handled', responses: [response(update.update_id, outcome.message || 'Please confirm this change.', [{label: 'Confirm', nonce: yes.nonce}, {label: 'Cancel', nonce: no.nonce}])]};
      }
      return {outcome: 'handled', responses: [response(update.update_id, outcome.message || (outcome.state === 'succeeded' ? 'Done.' : 'I need a little more information.'))]};
    },
  };
}

export async function runCycle() { return processTransportCycle(await createAdapter()); }

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.includes('--watch')) {
    console.log(JSON.stringify({status: 'watching', transport: 'telegram', poll_seconds: 4}));
    while (true) {
      try { const result = await runCycle(); if (result.updates || result.outbound) console.log(JSON.stringify(result)); }
      catch { console.error(JSON.stringify({status: 'cycle_failed', transport: 'telegram'})); }
      await new Promise(resolve => setTimeout(resolve, 4000));
    }
  } else console.log(JSON.stringify(await runCycle()));
}
