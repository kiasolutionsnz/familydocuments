import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ContractError, LIMITS, validateOcrRequest, validateOcrResult } from "../src/contracts.mjs";
import { extractCandidates } from "../src/candidates.mjs";
import { runBoundedOcrJob, JobError } from "../src/job-runner.mjs";
import { PaddleMobileAdapter } from "../src/paddle-adapter.mjs";
import { CandidateReviewStore, ReviewError } from "../src/review.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const workspace = path.resolve(here, "../../../..");
const mobileBatch = JSON.parse(
  fs.readFileSync(
    path.join(workspace, "software-factory/runs/family-passport-ocr-2026-08-18/paddle-smoke/mobile-batch.json"),
    "utf8",
  ),
);
const cleanMobileDocuments = mobileBatch.documents.filter((item) => item.fixture.startsWith("clean--"));
const raw = cleanMobileDocuments.find((item) => item.fixture === "clean--council-rates.png").prediction;

function request(overrides = {}) {
  return {
    contractVersion: "fp.ocr.request.v1",
    jobId: "job_test_0001",
    sourceId: "source_test_0001",
    sourceVersion: "version_test_0001",
    sourceSha256: "a".repeat(64),
    mimeType: "image/png",
    byteLength: 123_456,
    pageCount: 1,
    engine: "paddle-mobile-v1",
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    ...overrides,
  };
}

test("request contract is closed, bounded and engine allow-listed", () => {
  assert.equal(validateOcrRequest(request()).engine, "paddle-mobile-v1");
  assert.throws(() => validateOcrRequest(request({ surprise: true })), (error) => error instanceof ContractError && error.code === "REQUEST_EXTRA_FIELD");
  assert.throws(() => validateOcrRequest(request({ byteLength: LIMITS.maxBytes + 1 })), /SOURCE_SIZE_LIMIT/);
  assert.throws(() => validateOcrRequest(request({ pageCount: LIMITS.maxPages + 1 })), /PAGE_LIMIT/);
  assert.throws(() => validateOcrRequest(request({ engine: "cloud-unapproved" })), /ENGINE_NOT_ALLOWED/);
  assert.throws(() => validateOcrRequest(request({ expiresAt: new Date(0).toISOString() })), /REQUEST_EXPIRED/);
});

test("Paddle adapter creates exact source/page/span evidence and warnings", () => {
  const normalized = new PaddleMobileAdapter().normalize(request(), raw);
  assert.equal(normalized.pages.length, 1);
  assert.equal(normalized.pages[0].spans.length, 7);
  assert.equal(normalized.pages[0].spans[0].spanId, "p1s1");
  assert.equal(normalized.source.sha256, "a".repeat(64));
  assert.deepEqual(normalized.warnings, ["NON_AUTHORITATIVE", "CRITICAL_FIELDS_REQUIRE_CONFIRMATION"]);
  assert.equal(normalized.engine.detector, "PP-OCRv5_mobile_det");
});

test("adapter rejects malformed output and result provenance swaps", () => {
  const adapter = new PaddleMobileAdapter();
  assert.throws(() => adapter.normalize(request(), []), /RAW_PAGE_MISMATCH/);
  const normalized = structuredClone(adapter.normalize(request(), raw));
  normalized.source.sha256 = "b".repeat(64);
  assert.throws(() => validateOcrResult(normalized, request()), /SOURCE_PROVENANCE_MISMATCH/);
});

test("candidate extraction retains exact cited text and never auto-confirms", () => {
  const normalized = new PaddleMobileAdapter().normalize(request(), raw);
  const candidates = extractCandidates(normalized);
  assert.deepEqual(candidates.map((item) => item.type).sort(), ["amount", "due_date", "valuation_number"]);
  for (const candidate of candidates) {
    assert.equal(candidate.critical, true);
    assert.equal(candidate.status, "suggested");
    assert.equal(candidate.source.sha256, "a".repeat(64));
    assert.match(candidate.source.exactText, /Amount|Due date|Valuation number/);
  }
});

test("all six clean mobile-detector documents normalize into review-only candidates", () => {
  let totalCandidates = 0;
  for (const [index, document] of cleanMobileDocuments.entries()) {
    const sourceRequest = request({
      jobId: `job_clean_${String(index).padStart(4, "0")}`,
      sourceId: `source_clean_${String(index).padStart(4, "0")}`,
      sourceVersion: `version_clean_${String(index).padStart(4, "0")}`,
      sourceSha256: String(index + 1).repeat(64).slice(0, 64),
    });
    const normalized = new PaddleMobileAdapter().normalize(sourceRequest, document.prediction);
    const candidates = extractCandidates(normalized);
    assert.ok(candidates.length >= 2, `${document.fixture} should yield review candidates`);
    assert.ok(candidates.every((candidate) => candidate.status === "suggested" && candidate.critical));
    totalCandidates += candidates.length;
  }
  assert.ok(totalCandidates >= 16);
});

test("critical candidate requires authorized explicit confirm/correct/reject", () => {
  const candidate = extractCandidates(new PaddleMobileAdapter().normalize(request(), raw))[0];
  const store = new CandidateReviewStore();
  store.add(candidate);
  assert.equal(store.get(candidate.candidateId).status, "suggested");
  assert.throws(
    () => store.review({ candidateId: candidate.candidateId, expectedRevision: 1, action: "confirm", actor: { id: "viewer1", role: "viewer", authorized: true } }),
    (error) => error instanceof ReviewError && error.code === "NOT_AUTHORIZED",
  );
  const confirmed = store.review({
    candidateId: candidate.candidateId,
    expectedRevision: 1,
    action: "confirm",
    actor: { id: "adult_test", role: "adult", authorized: true },
  });
  assert.equal(confirmed.status, "confirmed");
  assert.equal(confirmed.authoritativeValue, candidate.proposedValue);
  assert.throws(
    () => store.review({ candidateId: candidate.candidateId, expectedRevision: 1, action: "reject", actor: { id: "adult_test", role: "adult", authorized: true } }),
    /STALE_REVIEW|ALREADY_REVIEWED/,
  );
});

test("bounded job cleans acquired material after success and failure", async () => {
  for (const mode of ["success", "failure"]) {
    const events = [];
    const operation = runBoundedOcrJob({
      request: request({ jobId: `job_${mode}_0001` }),
      acquire: async () => { events.push("acquire"); return { opaqueObject: "fixture" }; },
      execute: async () => {
        events.push("execute");
        if (mode === "failure") throw new Error("PARSER_FAILED");
        return { ok: true };
      },
      cleanup: async ({ acquired }) => { events.push(`cleanup:${acquired.opaqueObject}`); },
      timeoutMs: 500,
    });
    if (mode === "failure") await assert.rejects(operation, /PARSER_FAILED/);
    else assert.deepEqual(await operation, { ok: true });
    assert.deepEqual(events, ["acquire", "execute", "cleanup:fixture"]);
  }
});

test("timeout aborts and still cleans once", async () => {
  const events = [];
  await assert.rejects(
    runBoundedOcrJob({
      request: request({ jobId: "job_timeout_0001" }),
      acquire: async () => ({ opaqueObject: "fixture" }),
      execute: async (_request, _object, signal) => new Promise((resolve, reject) => {
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      }),
      cleanup: async () => { events.push("cleanup"); },
      timeoutMs: 10,
    }),
    (error) => error instanceof JobError && error.code === "OCR_TIMEOUT",
  );
  assert.deepEqual(events, ["cleanup"]);
});
