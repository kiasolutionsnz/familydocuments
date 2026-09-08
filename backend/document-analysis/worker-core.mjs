import {createHash} from 'node:crypto';

export const MAX_ATTEMPTS = 5;

export function safeFailure(error) {
  const value = String(error?.code || error?.message || '').toLowerCase();
  if (value.includes('ocr_authentication')) {
    return {code: 'ocr_authentication_failed', retryable: true};
  }
  if (value.includes('ocr_origin')) {
    return {code: 'ocr_origin_denied', retryable: false};
  }
  if (value.includes('invalid') || value.includes('unsupported') || value.includes('no readable')) {
    return {code: 'document_unreadable', retryable: false};
  }
  if (value.includes('source') || value.includes('integrity')) {
    return {code: 'source_unavailable', retryable: false};
  }
  return {code: 'processing_unavailable', retryable: true};
}

export async function processJobs({claim, renew, ocr, classify, complete, fail, batchSize = 3, leaseHeartbeatMs = 60000}) {
  const jobs = await claim(batchSize);
  const result = {claimed: jobs.length, succeeded: 0, retrying: 0, failed: 0, reportFailures: 0, failureStages: {}, failureCodes: {}};
  for (const job of jobs) {
    let stage = 'source_validation';
    let renewalFailure;
    const heartbeat = renew && job.lease_token ? setInterval(() => {
      renew(job.job_id, job.lease_token).then(value => {
        if (value !== true) renewalFailure ||= new Error('lease unavailable');
      }).catch(error => { renewalFailure ||= error; });
    }, leaseHeartbeatMs) : null;
    try {
      const bytes = Buffer.from(String(job.content_base64 || ''), 'base64');
      const digest = createHash('sha256').update(bytes).digest('hex');
      if (!bytes.length || digest !== job.sha256) throw Object.assign(new Error('source integrity'), {code: 'source_integrity'});
      stage = 'ocr';
      const extracted = await ocr(job);
      if (!String(extracted.text || '').trim()) throw Object.assign(new Error('no readable text'), {code: 'no_readable_text'});
      stage = 'classification';
      const proposal = await classify(job, extracted);
      if (renewalFailure) throw renewalFailure;
      stage = 'completion';
      await complete(job.job_id, job.lease_token, {...proposal, text: extracted.text, mean_confidence: extracted.mean_confidence || 0});
      result.succeeded++;
    } catch (error) {
      const failure = safeFailure(error);
      result.failureStages[stage] = (result.failureStages[stage] || 0) + 1;
      result.failureCodes[failure.code] = (result.failureCodes[failure.code] || 0) + 1;
      try {
        await fail(job.job_id, job.lease_token, failure.code, failure.retryable);
        if (failure.retryable && Number(job.attempt || 0) < MAX_ATTEMPTS) result.retrying++;
        else result.failed++;
      } catch {
        result.reportFailures++;
      }
    } finally {
      if (heartbeat) clearInterval(heartbeat);
    }
  }
  return result;
}
