import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {isolatedContext, syntheticAccount} from './isolated-context.mjs';
import {runCycle} from '../document-analysis/worker.mjs';

const {api, gateway} = isolatedContext();
const owner = await syntheticAccount('phase1b-owner');
const outsider = await syntheticAccount('phase1b-outsider');

async function rpc(user, name, payload = {}) {
  const response = await fetch(`${api}/rpc/${name}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${user.token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
  return {status: response.status, body: await response.json()};
}

async function gatewayRequest(user, path, payload) {
  const response = await fetch(`${gateway}${path}`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${user.token}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
  return {status: response.status, body: await response.json()};
}

const family = await rpc(owner, 'bootstrap_household', {
  household_name: 'Phase 1B synthetic Family',
  display_name: 'Synthetic owner',
});
assert.equal(family.status, 200, JSON.stringify(family.body));
assert.equal(
  (await rpc(outsider, 'bootstrap_household', {
    household_name: 'Other synthetic Family',
    display_name: 'Synthetic outsider',
  })).status,
  200,
);
const rentals = await rpc(owner, 'create_category', {category_name: 'Rentals'});
assert.equal(rentals.status, 200, JSON.stringify(rentals.body));

const requestId = `phase1b-reminder-${crypto.randomUUID()}`;
const reminderPayload = {
  reminder_title: 'My doctor appointment',
  due_date: '2026-09-09',
  due_time_value: '14:00:00',
  due_timezone: 'Pacific/Auckland',
  related_document: null,
  request_id: requestId,
};
const reminder = await rpc(owner, 'create_reminder', reminderPayload);
const reminderRetry = await rpc(owner, 'create_reminder', reminderPayload);
assert.equal(reminder.status, 200, JSON.stringify(reminder.body));
assert.equal(reminder.body.document_id, null);
assert.equal(reminder.body.due_time, '14:00:00');
assert.equal(reminder.body.due_time_zone, 'Pacific/Auckland');
assert.equal(reminderRetry.body.id, reminder.body.id);
assert.equal(reminderRetry.body.duplicate, true);
assert.equal(
  (await rpc(outsider, 'act_on_reminder', {
    reminder: reminder.body.id,
    action: 'complete',
  })).status,
  403,
);

const stream =
    'BT /F1 18 Tf 30 720 Td (SYNTHETIC ELECTRICITY BILL) Tj 0 -36 Td (Invoice TEST-12345) Tj 0 -36 Td (Due 30 September 2026) Tj ET';
const objects = [
  '<</Type /Catalog /Pages 2 0 R>>',
  '<</Type /Pages /Kids [3 0 R] /Count 1>>',
  '<</Type /Page /Parent 2 0 R /MediaBox [0 0 650 800] /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>',
  `<</Length ${stream.length}>>\nstream\n${stream}\nendstream`,
  '<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>',
];
let pdf = '%PDF-1.4\n';
const offsets = [0];
objects.forEach((object, index) => {
  offsets.push(Buffer.byteLength(pdf));
  pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
});
const xref = Buffer.byteLength(pdf);
pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`;
const bytes = Buffer.from(pdf);
const upload = {
  file_name: 'synthetic-electricity-bill.pdf',
  mime_type: 'application/pdf',
  sha256: createHash('sha256').update(bytes).digest('hex'),
  content_base64: bytes.toString('base64'),
};

const saved = await gatewayRequest(owner, '/documents/save', {
  ...upload,
  category: 'this as rental document',
});
assert.equal(saved.status, 200, JSON.stringify(saved.body));
assert.equal(saved.body.category, 'Rentals');
assert.equal(
  (await gatewayRequest(outsider, '/documents/save', {
    ...upload,
    category: 'Rentals',
  })).status,
  422,
);
assert.equal(
  (await gatewayRequest(owner, '/documents/save', {
    ...upload,
    category: 'Taxes',
  })).status,
  422,
);
assert.deepEqual((await rpc(owner, 'pending_document_analysis_jobs')).body, []);
const linked = await rpc(owner, 'create_reminder', {
  ...reminderPayload,
  reminder_title: 'Check saved rental bill',
  due_date: '2026-09-10',
  due_time_value: null,
  related_document: saved.body.document_id,
  request_id: `phase1b-linked-${crypto.randomUUID()}`,
});
assert.equal(linked.status, 200, JSON.stringify(linked.body));
assert.equal(linked.body.document_id, saved.body.document_id);

const jobPayload = {
  ...upload,
  mode: 'invoice',
  idempotency_key: `phase1b-analysis-${crypto.randomUUID()}`,
};
const [accepted, duplicate] = await Promise.all([
  gatewayRequest(owner, '/document-analysis/jobs', jobPayload),
  gatewayRequest(owner, '/document-analysis/jobs', jobPayload),
]);
assert.equal(accepted.status, 202, JSON.stringify(accepted.body));
assert.equal(duplicate.status, 202, JSON.stringify(duplicate.body));
assert.equal(accepted.body.job_id, duplicate.body.job_id);
assert.ok(accepted.body.duplicate !== duplicate.body.duplicate);
assert.equal(
  (await fetch(`${gateway}/document-analysis/jobs/${accepted.body.job_id}`, {
    headers: {authorization: `Bearer ${outsider.token}`},
  })).status,
  404,
);

const directOcr = await fetch(`${process.env.FP_OCR_URL}/ocr`, {
  method: 'POST',
  headers: {
    origin: 'http://127.0.0.1:3300',
    authorization: `Bearer ${owner.token}`,
    'content-type': 'application/json',
  },
  body: JSON.stringify(upload),
  signal: AbortSignal.timeout(180000),
});
assert.equal(directOcr.status, 200, `isolated OCR returned ${directOcr.status}`);

const cycle = await runCycle();
assert.equal(cycle.claimed, 1);
assert.equal(cycle.succeeded, 1, JSON.stringify(cycle));
const completedResponse = await fetch(
  `${gateway}/document-analysis/jobs/${accepted.body.job_id}`,
  {headers: {authorization: `Bearer ${owner.token}`}},
);
const completed = await completedResponse.json();
assert.equal(completedResponse.status, 200, JSON.stringify(completed));
assert.equal(completed.status, 'succeeded');
assert.ok(completed.result?.title);
assert.ok(Array.isArray(completed.result?.tags));
const restored = await rpc(owner, 'pending_document_analysis_jobs');
assert.equal(restored.status, 200);
assert.ok(restored.body.some(item => item.job_id === accepted.body.job_id));
const source = await rpc(owner, 'document_source', {
  document: accepted.body.document_id,
});
assert.equal(source.status, 200, JSON.stringify(source.body));
assert.deepEqual(Buffer.from(source.body.content_base64, 'base64'), bytes);

console.log(JSON.stringify({
  standalone_reminder: 'PASS',
  reminder_idempotency: 'PASS',
  cross_family_reminder_denial: 'PASS',
  document_linked_reminder: 'PASS',
  clear_destination_without_ocr: 'PASS',
  natural_category_alias: 'PASS',
  missing_category_rejected: 'PASS',
  cross_family_category_denial: 'PASS',
  asynchronous_acceptance: 'PASS',
  real_paddleocr_and_ollama: 'PASS',
  job_restore_and_idempotency: 'PASS',
  cross_family_job_denial: 'PASS',
  original_preserved: 'PASS',
}));
