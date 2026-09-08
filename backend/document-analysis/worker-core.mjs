import {createHash} from 'node:crypto';

export const MAX_ATTEMPTS = 5;

export function safeFailure(error) {
  const value = String(error?.code || error?.message || '').toLowerCase();
  if (value.includes('invalid') || value.includes('unsupported') || value.includes('no readable')) {
    return {code: 'document_unreadable', retryable: false};
  }
  if (value.includes('source') || value.includes('integrity')) {
    return {code: 'source_unavailable', retryable: false};
  }
  return {code: 'processing_unavailable', retryable: true};
}

export async function processJobs({claim, ocr, classify, complete, fail, batchSize = 3}) {
  const jobs = await claim(batchSize);
  const result = {claimed: jobs.length, succeeded: 0, retrying: 0, failed: 0};
  for (const job of jobs) {
    try {
      const bytes = Buffer.from(String(job.content_base64 || ''), 'base64');
      const digest = createHash('sha256').update(bytes).digest('hex');
      if (!bytes.length || digest !== job.sha256) throw Object.assign(new Error('source integrity'), {code: 'source_integrity'});
      const extracted = await ocr(job);
      if (!String(extracted.text || '').trim()) throw Object.assign(new Error('no readable text'), {code: 'no_readable_text'});
      const proposal = await classify(job, extracted);
      await complete(job.job_id, {...proposal, text: extracted.text, mean_confidence: extracted.mean_confidence || 0});
      result.succeeded++;
    } catch (error) {
      const failure = safeFailure(error);
      await fail(job.job_id, failure.code, failure.retryable);
      if (failure.retryable && Number(job.attempt || 0) < MAX_ATTEMPTS) result.retrying++;
      else result.failed++;
    }
  }
  return result;
}
