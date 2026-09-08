import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {processJobs} from '../document-analysis/worker-core.mjs';

const content = Buffer.from('synthetic phase 1b document');
const job = {job_id: 'job-1', attempt: 1, content_base64: content.toString('base64'), sha256: createHash('sha256').update(content).digest('hex')};

test('a claimed job is processed once and stores a durable result', async () => {
  const completed = [];
  const result = await processJobs({claim: async () => [job], ocr: async () => ({text: 'Test Travel Insurance', mean_confidence: .9}), classify: async () => ({title: 'Test policy', category: 'Travel', tags: ['insurance']}), complete: async (...values) => completed.push(values), fail: async () => assert.fail('not failed')});
  assert.equal(result.succeeded, 1);
  assert.equal(completed.length, 1);
  assert.equal(completed[0][1].text, 'Test Travel Insurance');
});

test('retryable failures are returned to the durable retry queue', async () => {
  const failures = [];
  const result = await processJobs({claim: async () => [job], ocr: async () => { throw new Error('OCR unavailable'); }, classify: async () => ({}), complete: async () => {}, fail: async (...values) => failures.push(values)});
  assert.equal(result.retrying, 1);
  assert.deepEqual(failures, [['job-1', 'processing_unavailable', true]]);
});

test('invalid sources fail permanently instead of looping', async () => {
  const failures = [];
  const bad = {...job, sha256: '0'.repeat(64)};
  const result = await processJobs({claim: async () => [bad], ocr: async () => assert.fail('OCR not called'), classify: async () => ({}), complete: async () => {}, fail: async (...values) => failures.push(values)});
  assert.equal(result.failed, 1);
  assert.equal(failures[0][2], false);
});
