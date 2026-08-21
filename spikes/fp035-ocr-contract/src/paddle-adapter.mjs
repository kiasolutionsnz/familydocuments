import { ContractError, validateOcrRequest, validateOcrResult } from "./contracts.mjs";

export class PaddleMobileAdapter {
  id = "paddle-mobile-v1";

  normalize(requestInput, rawPrediction) {
    const request = validateOcrRequest(requestInput);
    if (!Array.isArray(rawPrediction) || rawPrediction.length !== request.pageCount) {
      throw new ContractError("RAW_PAGE_MISMATCH");
    }
    const pages = rawPrediction.map((entry, index) => {
      const raw = entry?.res;
      if (!raw || !Array.isArray(raw.rec_texts) || !Array.isArray(raw.rec_scores) || !Array.isArray(raw.rec_polys)) {
        throw new ContractError("MALFORMED_ENGINE_OUTPUT");
      }
      if (raw.rec_texts.length !== raw.rec_scores.length || raw.rec_texts.length !== raw.rec_polys.length) {
        throw new ContractError("ENGINE_OUTPUT_LENGTH_MISMATCH");
      }
      return {
        pageNumber: index + 1,
        orientationDegrees: raw.doc_preprocessor_res?.angle ?? null,
        spans: raw.rec_texts.map((text, spanIndex) => ({
          spanId: `p${index + 1}s${spanIndex + 1}`,
          text,
          confidence: raw.rec_scores[spanIndex],
          polygon: raw.rec_polys[spanIndex],
        })),
      };
    });
    const result = {
      contractVersion: "fp.ocr.result.v1",
      jobId: request.jobId,
      source: { id: request.sourceId, version: request.sourceVersion, sha256: request.sourceSha256 },
      engine: {
        id: this.id,
        package: "paddleocr@3.4.0",
        detector: "PP-OCRv5_mobile_det",
        recognizer: "en_PP-OCRv5_mobile_rec",
        orientation: "PP-LCNet_x1_0_doc_ori",
      },
      pages,
      warnings: ["NON_AUTHORITATIVE", "CRITICAL_FIELDS_REQUIRE_CONFIRMATION"],
      completedAt: new Date().toISOString(),
    };
    return validateOcrResult(result, request);
  }
}

