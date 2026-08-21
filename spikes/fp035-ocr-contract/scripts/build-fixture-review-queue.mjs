import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { extractCandidates } from "../src/candidates.mjs";
import { PaddleMobileAdapter } from "../src/paddle-adapter.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const workspace = path.resolve(here, "../../../..");
const smokeRoot = path.join(workspace, "software-factory/runs/family-passport-ocr-2026-08-18/paddle-smoke");
const batch = JSON.parse(fs.readFileSync(path.join(smokeRoot, "mobile-batch.json"), "utf8"));
const clean = batch.documents.filter((item) => item.fixture.startsWith("clean--"));
const adapter = new PaddleMobileAdapter();

const queue = clean.map((document, index) => {
  const fixtureName = document.fixture.replace(/^clean--/, "");
  const fixturePath = path.join(smokeRoot, "fixtures", fixtureName);
  const bytes = fs.readFileSync(fixturePath);
  const sourceHash = crypto.createHash("sha256").update(bytes).digest("hex");
  const request = {
    contractVersion: "fp.ocr.request.v1",
    jobId: `job_fixture_${String(index).padStart(4, "0")}`,
    sourceId: `source_fixture_${String(index).padStart(4, "0")}`,
    sourceVersion: `version_fixture_${String(index).padStart(4, "0")}`,
    sourceSha256: sourceHash,
    mimeType: "image/png",
    byteLength: bytes.length,
    pageCount: 1,
    engine: "paddle-mobile-v1",
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
  };
  const result = adapter.normalize(request, document.prediction);
  return {
    jobId: request.jobId,
    sourceId: request.sourceId,
    sourceVersion: request.sourceVersion,
    state: "review_required",
    authoritativeFactsCreated: 0,
    candidates: extractCandidates(result),
  };
});

const output = process.argv[2];
if (!output) throw new Error("output path required");
fs.writeFileSync(output, JSON.stringify({ contractVersion: "fp.review.queue.fixture.v1", items: queue }, null, 2));
console.log(JSON.stringify({ items: queue.length, candidates: queue.reduce((count, item) => count + item.candidates.length, 0), authoritativeFactsCreated: 0 }));

