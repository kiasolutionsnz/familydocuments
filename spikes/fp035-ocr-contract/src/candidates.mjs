import crypto from "node:crypto";

const MONTH = "(?:January|February|March|April|May|June|July|August|September|October|November|December)";
const RULES = [
  ["renewal_date", new RegExp(`renewal date\\s*[: ]\\s*(\\d{1,2} ${MONTH} \\d{4})`, "i")],
  ["expiry_date", new RegExp(`(?:expiry date|wof expiry|warranty expires)\\s*[: ]\\s*(\\d{1,2} ${MONTH} \\d{4})`, "i")],
  ["due_date", new RegExp(`due date\\s*[: ]\\s*(\\d{1,2} ${MONTH} \\d{4})`, "i")],
  ["purchase_date", new RegExp(`purchase date\\s*[: ]\\s*(\\d{1,2} ${MONTH} \\d{4})`, "i")],
  ["amount", /(?:amount due|amount|annual premium|price paid)\s*[: ]\s*(NZD\s*[\d,]+\.\d{2})/i],
  ["policy_number", /policy number\s*[: ]\s*([A-Z0-9-]+)/i],
  ["account_number", /account\s*[: ]\s*([A-Z0-9-]+)/i],
  ["registration", /registration\s*[: ]\s*([A-Z0-9-]+)/i],
  ["valuation_number", /valuation number\s*[: ]\s*([A-Z0-9-]+)/i],
  ["serial_number", /serial number\s*[: ]\s*([A-Z0-9-]+)/i],
  ["passport_number", /passport number\s*[: ]\s*([A-Z0-9-]+)/i],
];

export function extractCandidates(ocrResult) {
  const candidates = [];
  for (const page of ocrResult.pages) {
    for (const span of page.spans) {
      for (const [type, rule] of RULES) {
        const match = span.text.match(rule);
        if (!match) continue;
        const value = match[1].trim();
        candidates.push(Object.freeze({
          candidateId: crypto.createHash("sha256").update(`${ocrResult.jobId}|${page.pageNumber}|${span.spanId}|${type}|${value}`).digest("hex").slice(0, 24),
          type,
          proposedValue: value,
          confidence: span.confidence,
          critical: true,
          status: "suggested",
          source: {
            id: ocrResult.source.id,
            version: ocrResult.source.version,
            sha256: ocrResult.source.sha256,
            pageNumber: page.pageNumber,
            spanId: span.spanId,
            exactText: span.text,
            polygon: span.polygon,
          },
        }));
      }
    }
  }
  return candidates;
}

