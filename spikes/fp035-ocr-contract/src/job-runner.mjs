import { LIMITS, validateOcrRequest } from "./contracts.mjs";

export async function runBoundedOcrJob({ request: requestInput, acquire, execute, cleanup, timeoutMs = LIMITS.maxRuntimeMs }) {
  const request = validateOcrRequest(requestInput);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(new Error("OCR_TIMEOUT")), timeoutMs);
  let acquired = null;
  try {
    acquired = await acquire(request, controller.signal);
    return await execute(request, acquired, controller.signal);
  } catch (error) {
    if (controller.signal.aborted) throw new JobError("OCR_TIMEOUT");
    throw error;
  } finally {
    clearTimeout(timeout);
    await cleanup({ jobId: request.jobId, acquired });
  }
}

export class JobError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

