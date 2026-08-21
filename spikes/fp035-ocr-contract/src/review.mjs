export class CandidateReviewStore {
  #records = new Map();

  add(candidate) {
    if (this.#records.has(candidate.candidateId)) throw new ReviewError("DUPLICATE_CANDIDATE");
    this.#records.set(candidate.candidateId, { ...structuredClone(candidate), revision: 1, history: [] });
  }

  review({ candidateId, expectedRevision, action, correctedValue, actor }) {
    const record = this.#records.get(candidateId);
    if (!record) throw new ReviewError("CANDIDATE_NOT_FOUND");
    if (!actor?.authorized || !["owner", "admin", "adult"].includes(actor.role)) throw new ReviewError("NOT_AUTHORIZED");
    if (record.revision !== expectedRevision) throw new ReviewError("STALE_REVIEW");
    if (record.status !== "suggested") throw new ReviewError("ALREADY_REVIEWED");
    if (!new Set(["confirm", "correct", "reject"]).has(action)) throw new ReviewError("INVALID_ACTION");
    if (action === "correct" && (typeof correctedValue !== "string" || correctedValue.trim().length === 0)) {
      throw new ReviewError("CORRECTION_REQUIRED");
    }
    record.history.push({
      revision: record.revision,
      status: record.status,
      at: new Date().toISOString(),
      actorId: actor.id,
    });
    record.status = action === "confirm" ? "confirmed" : action === "correct" ? "corrected" : "rejected";
    record.authoritativeValue = action === "reject" ? null : action === "correct" ? correctedValue.trim() : record.proposedValue;
    record.revision += 1;
    return structuredClone(record);
  }

  get(candidateId) {
    const value = this.#records.get(candidateId);
    return value ? structuredClone(value) : null;
  }
}

export class ReviewError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

