import {createHash} from 'node:crypto';

export const TELEGRAM_MAX_FILE_BYTES = 5 * 1024 * 1024;

export function detectSupportedFile(bytes) {
  if (!Buffer.isBuffer(bytes) || !bytes.length || bytes.length > TELEGRAM_MAX_FILE_BYTES) return null;
  if (bytes.subarray(0, 5).toString('ascii') === '%PDF-') return 'application/pdf';
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[bytes.length - 2] === 0xff && bytes[bytes.length - 1] === 0xd9) return 'image/jpeg';
  if (bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  return null;
}

export function safeTelegramFailure(error) {
  const value = String(error?.code || error?.message || '').toLowerCase();
  if (/unsupported|mismatch|too large/.test(value)) return {outcome: 'invalid_attachment', retryable: false};
  if (/not authorised|permission|revoked/.test(value)) return {outcome: 'permission_denied', retryable: false};
  return {outcome: 'service_unavailable', retryable: true};
}

export function checksum(bytes) { return createHash('sha256').update(bytes).digest('hex'); }

export async function processTransportCycle(adapter, {batchSize = 4} = {}) {
  const totals = {updates: 0, completed: 0, retrying: 0, failed: 0, outbound: 0, sent: 0};
  if (adapter.beforeCycle) await adapter.beforeCycle();
  const updates = await adapter.claimUpdates(batchSize);
  totals.updates = updates.length;
  for (const update of updates) {
    try {
      const result = await adapter.handleUpdate(update);
      await adapter.completeUpdate(update.id, update.lease_token, result.outcome, result.responses || []);
      totals.completed++;
    } catch (error) {
      const failure = safeTelegramFailure(error);
      await adapter.failUpdate(update.id, update.lease_token, failure.retryable, failure.outcome, error, update);
      failure.retryable ? totals.retrying++ : totals.failed++;
    }
  }
  const outbound = await adapter.claimOutbox(batchSize);
  totals.outbound = outbound.length;
  for (const item of outbound) {
    try {
      const messageID = await adapter.send(item);
      await adapter.completeOutbox(item.id, item.lease_token, String(messageID));
      totals.sent++;
    } catch (error) {
      await adapter.failOutbox(item.id, item.lease_token, !/invalid chat|blocked/i.test(String(error?.message || '')));
    }
  }
  return totals;
}
