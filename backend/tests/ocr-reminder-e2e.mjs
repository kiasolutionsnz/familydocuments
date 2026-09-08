import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {isolatedContext, syntheticAccount} from './isolated-context.mjs';

const {api, ocr: ocrUrl} = isolatedContext();
const owner = await syntheticAccount('ocr-owner'), outsider = await syntheticAccount('ocr-outsider');
async function rpc(user, name, payload = {}) {
  const response = await fetch(`${api}/rpc/${name}`, {method: 'POST', headers: {authorization: `Bearer ${user.token}`, 'content-type': 'application/json'}, body: JSON.stringify(payload)});
  return {status: response.status, body: await response.json()};
}
const household = await rpc(owner, 'bootstrap_household', {household_name: 'Test Household', display_name: 'OCR tester'});
assert.equal(household.status, 200, JSON.stringify(household.body));
assert.equal((await rpc(outsider, 'bootstrap_household', {household_name: 'Other Test Household', display_name: 'Different tester'})).status, 200);
const category = household.body.categories.find(item => item.name === 'Insurance');
assert.ok(category);

// Build a tiny valid, repository-owned synthetic PDF in memory. No external or family files.
const stream = 'BT /F1 22 Tf 40 720 Td (TEST CAR INSURANCE POLICY) Tj 0 -44 Td (Provider: Example Insurance) Tj 0 -44 Td (Policy renewal date: 30 September 2027) Tj ET';
const objects = ['<</Type /Catalog /Pages 2 0 R>>', '<</Type /Pages /Kids [3 0 R] /Count 1>>', '<</Type /Page /Parent 2 0 R /MediaBox [0 0 650 800] /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>', `<</Length ${stream.length}>>\nstream\n${stream}\nendstream`, '<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>'];
let pdf = '%PDF-1.4\n'; const offsets = [0];
objects.forEach((object, index) => {offsets.push(Buffer.byteLength(pdf)); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;});
const xref = Buffer.byteLength(pdf);
pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`;
const bytes = Buffer.from(pdf), checksum = createHash('sha256').update(bytes).digest('hex');
const draft = await rpc(owner, 'create_ocr_intake_draft', {file_name: 'synthetic-insurance.pdf', source_mime_type: 'application/pdf', content_base64: bytes.toString('base64'), category: category.id});
assert.equal(draft.status, 200, JSON.stringify(draft.body));
const draftId = draft.body.draft_id;
assert.ok(draftId);
const before = await rpc(owner, 'household_snapshot');
assert.equal(before.body.documents.length, 0, 'Uploading must not confirm a record');
assert.equal(before.body.reminders.length, 0);
const response = await fetch(`${ocrUrl}/ocr`, {method: 'POST', headers: {origin: 'http://127.0.0.1:3300', authorization: `Bearer ${owner.token}`, 'content-type': 'application/json'}, body: JSON.stringify({mime_type: 'application/pdf', sha256: checksum, content_base64: bytes.toString('base64')}), signal: AbortSignal.timeout(120000)});
const ocr = await response.json();
assert.equal(response.status, 200, JSON.stringify(ocr));
assert.match(ocr.text, /INSURANCE/i); assert.ok(ocr.mean_confidence > 0);
const extraction = await rpc(owner, 'record_ocr_intake_result', {draft: draftId, confirmed_text: ocr.text, mean_confidence: ocr.mean_confidence});
assert.equal(extraction.status, 200, JSON.stringify(extraction.body));
const confirmation = {draft: draftId, document_title: 'Test Car Insurance Policy', category: category.id, confirmed_text: ocr.text, confirmed_document_type: 'Insurance policy', confirmed_provider: 'Example Insurance', confirmed_critical_date: '2027-09-30', mean_confidence: ocr.mean_confidence};
const deniedDraft = await rpc(outsider, 'confirm_ocr_intake', confirmation); assert.equal(deniedDraft.status, 403, JSON.stringify(deniedDraft.body));
// Concurrent repeated taps are serialized by the draft lock and produce one record/reminder.
const [saved, duplicate] = await Promise.all([rpc(owner, 'confirm_ocr_intake', confirmation), rpc(owner, 'confirm_ocr_intake', confirmation)]);
assert.equal(saved.status, 200, JSON.stringify(saved.body)); assert.equal(duplicate.status, 200, JSON.stringify(duplicate.body));
assert.equal(saved.body.document_id, duplicate.body.document_id);
const snapshot = await rpc(owner, 'household_snapshot');
assert.equal(snapshot.body.documents.length, 1); assert.equal(snapshot.body.reminders.length, 1); assert.equal(snapshot.body.reminders[0].due_at, '2027-09-30');
const source = await rpc(owner, 'document_source', {document: saved.body.document_id});
assert.equal(source.status, 200, JSON.stringify(source.body));
assert.deepEqual(Buffer.from(source.body.content_base64, 'base64'), bytes, 'Permanent original must survive the OCR temporary file cleanup');
assert.equal((await rpc(outsider, 'document_source', {document: saved.body.document_id})).status, 404);
const deniedSearch = await rpc(outsider, 'search_household_records', {search_query: 'Test Car Insurance Policy', result_limit: 20});
assert.deepEqual(deniedSearch.body, []);
console.log(JSON.stringify({real_paddleocr: 'PASS', original_saved_before_processing: 'PASS', unconfirmed_draft: 'PASS', explicit_atomic_confirmation: 'PASS', concurrent_idempotency: 'PASS', original_byte_for_byte_open: 'PASS', cross_household_draft_source_search_denial: 'PASS'}));
