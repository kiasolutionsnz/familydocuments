import crypto from "node:crypto";

export const LIMITS = Object.freeze({
  maxBytes: 15 * 1024 * 1024,
  maxPages: 20,
  maxPageTextChars: 100_000,
  maxSpansPerPage: 5_000,
  maxRuntimeMs: 120_000,
  allowedMimeTypes: new Set(["image/png", "image/jpeg", "application/pdf"]),
});

const SHA256 = /^[a-f0-9]{64}$/;
const ID = /^[a-zA-Z0-9][a-zA-Z0-9_-]{7,127}$/;

export function validateOcrRequest(request) {
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new ContractError("INVALID_REQUEST");
  }
  const allowed = new Set([
    "contractVersion", "jobId", "sourceId", "sourceVersion", "sourceSha256",
    "mimeType", "byteLength", "pageCount", "engine", "expiresAt",
  ]);
  rejectExtraKeys(request, allowed, "REQUEST_EXTRA_FIELD");
  if (request.contractVersion !== "fp.ocr.request.v1") throw new ContractError("UNSUPPORTED_CONTRACT");
  for (const key of ["jobId", "sourceId", "sourceVersion"]) {
    if (typeof request[key] !== "string" || !ID.test(request[key])) throw new ContractError(`INVALID_${key.toUpperCase()}`);
  }
  if (!SHA256.test(request.sourceSha256 ?? "")) throw new ContractError("INVALID_SOURCE_HASH");
  if (!LIMITS.allowedMimeTypes.has(request.mimeType)) throw new ContractError("UNSUPPORTED_MIME_TYPE");
  if (!Number.isSafeInteger(request.byteLength) || request.byteLength < 1 || request.byteLength > LIMITS.maxBytes) {
    throw new ContractError("SOURCE_SIZE_LIMIT");
  }
  if (!Number.isSafeInteger(request.pageCount) || request.pageCount < 1 || request.pageCount > LIMITS.maxPages) {
    throw new ContractError("PAGE_LIMIT");
  }
  if (request.engine !== "paddle-mobile-v1") throw new ContractError("ENGINE_NOT_ALLOWED");
  const expiry = Date.parse(request.expiresAt);
  if (!Number.isFinite(expiry) || expiry <= Date.now()) throw new ContractError("REQUEST_EXPIRED");
  return Object.freeze(structuredClone(request));
}

export function validateOcrResult(result, request) {
  if (!result || result.contractVersion !== "fp.ocr.result.v1") throw new ContractError("INVALID_RESULT");
  const allowed = new Set([
    "contractVersion", "jobId", "source", "engine", "pages", "warnings", "completedAt",
  ]);
  rejectExtraKeys(result, allowed, "RESULT_EXTRA_FIELD");
  if (result.jobId !== request.jobId) throw new ContractError("JOB_MISMATCH");
  if (result.source?.id !== request.sourceId || result.source?.version !== request.sourceVersion || result.source?.sha256 !== request.sourceSha256) {
    throw new ContractError("SOURCE_PROVENANCE_MISMATCH");
  }
  if (result.engine?.id !== request.engine) throw new ContractError("ENGINE_MISMATCH");
  if (!Array.isArray(result.pages) || result.pages.length !== request.pageCount) throw new ContractError("RESULT_PAGE_MISMATCH");
  for (const [index, page] of result.pages.entries()) {
    if (page.pageNumber !== index + 1 || !Array.isArray(page.spans) || page.spans.length > LIMITS.maxSpansPerPage) {
      throw new ContractError("INVALID_PAGE");
    }
    let chars = 0;
    for (const span of page.spans) {
      if (typeof span.text !== "string" || span.text.length === 0) throw new ContractError("INVALID_SPAN_TEXT");
      chars += span.text.length;
      if (!Number.isFinite(span.confidence) || span.confidence < 0 || span.confidence > 1) throw new ContractError("INVALID_CONFIDENCE");
      if (!Array.isArray(span.polygon) || span.polygon.length !== 4) throw new ContractError("INVALID_POLYGON");
    }
    if (chars > LIMITS.maxPageTextChars) throw new ContractError("PAGE_TEXT_LIMIT");
  }
  return Object.freeze(structuredClone(result));
}

export function hashText(value) {
  return crypto.createHash("sha256").update(value, "utf8").digest("hex");
}

export class ContractError extends Error {
  constructor(code) {
    super(code);
    this.name = "ContractError";
    this.code = code;
  }
}

function rejectExtraKeys(value, allowed, code) {
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new ContractError(code);
}

