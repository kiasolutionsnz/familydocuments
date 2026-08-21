# Family Passport / Family OS — Technical Feasibility

LAST REVIEWED: 2026-08-17

RESEARCH OWNER: Software Factory Solution Architect

SOURCES: Primary/official technical documentation listed in the source register below

COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore (technical architecture is global; provider/data-residency availability needs country-specific procurement review)

VERIFICATION STATUS: DISCOVERY COMPLETE FOR DECISION; provider production approval, representative-document benchmarks, OAuth verification eligibility, data residency, and vendor contracts remain unverified

## Evidence legend

- **VERIFIED FACT** — supported by a current primary source checked on 2026-08-17.
- **ESTIMATE** — indicative calculation with stated assumptions; not a quote.
- **ASSUMPTION** — a premise requiring validation.
- **PROPOSAL** — discovery-stage recommendation, not an approved design.
- **NEEDS RESEARCH** — material evidence is not yet available.

## Executive technical verdict

**PROPOSAL — HYBRID, Google-Drive-first.** Keep user-selected original files in the provider, but store a service-side, encrypted family index: provider/file identifiers, version marker, extracted metadata, OCR text where consented, relationships, reminders, permissions, provenance, and search vectors. Offer first-party hosted originals only for direct capture, forwarded mail, recovery snapshots explicitly chosen by the user, and providers that cannot support a durable link.

**VERIFIED FACT:** Google Drive, Microsoft OneDrive and Dropbox expose change-tracking mechanisms suitable for incremental indexing. Google Drive has change logs and `changes.watch`; Microsoft exposes drive delta and webhooks; Dropbox exposes recursive `list_folder` cursors and continuation/long-poll patterns. These notifications/cursors are signals, not a substitute for reconciliation. [Google changes](https://developers.google.com/workspace/drive/api/guides/manage-changes), [Microsoft drive delta](https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-v1.0), [OneDrive webhooks](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/using-webhooks?view=odsp-graph-online), [Dropbox list-folder SDK reference](https://dropbox.github.io/dropbox-sdk-js/Dropbox.html).

**PROPOSAL:** BYOS is technically feasible but is a trust and portability feature, not a storage-cost breakthrough. OCR text, metadata, thumbnails and embeddings are sensitive derived copies; the product cannot truthfully say “we do not store your documents” if it stores enough extracted content to reconstruct them. Positioning should be: “Originals stay where you choose; we securely store the minimum index needed to organise them,” with a per-category processing disclosure.

**PROPOSAL:** Do not begin with graph-database infrastructure, broad mailbox ingestion, multi-provider parity, health records, autonomous filing, cross-family model training, or end-to-end encryption claims. A relational core with explicit typed edges and hybrid retrieval is sufficient to test differentiation.

## Feasibility by capability

| Capability | Finding | Feasibility | Critical condition |
|---|---|---:|---|
| Google Drive selected-file indexing | **VERIFIED FACT:** `drive.file` is non-sensitive and works with files a user opens/shares through the app; Google recommends it with Picker. | High | User must deliberately select files/folders; validate folder-descendant behaviour and re-selection UX in a prototype. |
| Whole-Drive indexing | **VERIFIED FACT:** `drive.readonly` is restricted; transmitting/storing restricted-scope data server-side requires verification/security assessment. | Medium | Avoid in MVP; large trust and compliance burden. |
| OneDrive indexing | **VERIFIED FACT:** delegated `Files.Read` supports personal accounts for drive delta; webhooks notify only where the app has access. | High | Handle subscription expiry, remote/shared items and 429 backoff. |
| Dropbox indexing | **VERIFIED FACT:** App Folder is narrow but cannot discover existing records elsewhere; Full Dropbox is account-wide. | Medium | A folder-specific consent UX does not necessarily reduce OAuth content access; disclose clearly. |
| Mobile scan/photo | **VERIFIED FACT:** Apple Vision performs text recognition on device and returns confidence; Android ML Kit provides device image text recognition and quality materially affects accuracy. | High | Capture quality gate and server fallback for poor/multipage documents. |
| OCR/classification/extraction | Cloud OCR and structured extraction are mature and low-cost at modest volume. | High | Benchmarks must use target-country bills, policies, passports and poor photos; critical fields require confirmation. |
| Email forwarding | Standard inbound email/attachment parsing avoids mailbox OAuth. | High | Treat sender identity as untrusted; malware scan, size/type limits, family-specific addresses, retention rules. |
| Gmail/Outlook background discovery | Technically available through history/delta and change notifications. | Medium | Broad read permission, verification, consent friction and security-assessment burden make it Phase 2. |
| Family information graph | Typed entities/relationships add semantic value over folders. | High | Model provenance, time/version, confidence and permissions as first-class data. |
| AI retrieval with citations | Hybrid structured + lexical + vector retrieval is feasible. | High | Authorization before retrieval, evidence snippets after authorization, abstention, citations to source/version. |
| End-to-end encryption with cloud AI/search | Possible only with major feature compromises or client-side processing. | Low for MVP | Server-side OCR, cross-device indexing, reminders and RAG require server-visible plaintext at some point unless moved to trusted clients/enclaves. |

## BYOS versus hosted originals

| Criterion | Hosted-first | BYOS-first | Hybrid |
|---|---|---|---|
| Onboarding | Simplest direct upload | Connector and selection friction | Moderate |
| Source durability | Service controls object lifecycle | User may move/delete/revoke; provider outage | Best-effort links plus explicit hosted capture |
| Permission semantics | One product ACL | Provider ACL and product ACL can diverge | Product ACL controls index; provider remains authority for original |
| Search/OCR | Straightforward | Requires temporary retrieval and derived-data policy | Straightforward once consented index exists |
| Privacy narrative | Originals copied into proprietary vault | Originals remain user-chosen, but derived copies remain | Most honest balance |
| Lock-in/export | Higher | Lower for originals | Lower if metadata export and deletion are built in |
| Engineering | Lowest | Highest | Medium-high |
| Storage cost | Product bears originals/previews | User bears originals; product still bears index | Usually modest saving, not decisive |

**PROPOSAL:** Choose hybrid. In the MVP, support one Google account per family and only Picker-selected material. Store stable provider IDs, provider-native version/checksum where available, MIME type, original location, observed owner/access, last successful fetch, and a tombstone/stale state. Never interpret a missing provider object as permission to delete the family’s extracted metadata automatically; mark it unavailable and ask the owner whether to retain or delete the derived record.

**Failure-state contract (PROPOSAL):**

1. Webhook/change signal enters an idempotent queue.
2. Worker reads the authoritative change cursor and compares version/checksum.
3. Moved file: update location while retaining logical document identity.
4. Deleted/inaccessible file: mark `SOURCE_UNAVAILABLE`, suppress source-dependent AI answers, retain provenance until user retention policy resolves it.
5. Revoked/expired token: disable sync, notify family owner without exposing filenames to unauthorised members, and require reconnection.
6. Rate limit/outage: exponential backoff, cursor-safe replay, visible “last synced” state.
7. Replaced content under same logical location: create a document version, re-run extraction, preserve prior confirmed facts and flag conflicts.

## Email ingestion verdict

**VERIFIED FACT:** Gmail supports label-filtered `watch` notifications and `history.list`, but notifications can be delayed or dropped and watches expire; Google recommends periodic history reconciliation. A watched label narrows notifications, not the underlying `gmail.readonly` permission needed to read bodies/attachments. `gmail.readonly`, `gmail.metadata`, and `gmail.modify` are restricted scopes; server-side storage/transmission invokes an annual security assessment. [Gmail push](https://developers.google.com/workspace/gmail/api/guides/push), [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Google security assessment](https://support.google.com/cloud/answer/13465431).

**VERIFIED FACT:** Microsoft delegated `Mail.Read` reads the signed-in user’s mailbox, while `Mail.ReadBasic` excludes bodies and attachments. Outlook supports webhook change notifications and mail delta. [Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference), [Outlook change notifications](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview), [mail delta](https://learn.microsoft.com/en-us/graph/api/mailboxitem-delta?view=graph-rest-v1.0).

**PROPOSAL — MVP:** use explicit forwarding to a unique family ingest address and manual share/upload from the mail client. Add optional sender allowlists and signed forwarding instructions. Do not promise sender authenticity. Quarantine all attachments; reject executables and encrypted archives unless deliberately supported.

**PROPOSAL — Phase 2 experiment:** Gmail label-only discovery with user-created `Family Passport` label, attachment-only processing, no mailbox-wide backfill, and a review queue. Proceed only after a privacy comprehension test and confirmation that the intended use passes Google verification. Outlook follows after Gmail signal, not simultaneously.

## OCR and document-intelligence pipeline

**PROPOSAL:**

`source event → malware/type validation → native text extraction → image quality assessment → OCR if required → document classification → schema-specific extraction → entity candidates → validation/conflict rules → user review → confirmed facts/reminders → indexed evidence`

- Prefer embedded PDF text first; OCR only image regions/pages that need it.
- Use device OCR for live capture guidance and low-risk drafts. Apple states Vision processing occurs on-device and returns confidence. Android ML Kit supports on-device image inputs; Google explicitly notes focus/resolution affect results.
- Use cloud OCR as an optional quality fallback for multipage, tables, rotation and poor scans.
- Use deterministic parsers for dates, currency, identifiers and checksums, then a schema-constrained LLM for classification/extraction. Store model/prompt/schema version and source spans.
- Separate `observed text`, `suggested fact`, and `confirmed fact`. Confidence is field-specific, not one document-wide score.
- Never create a critical expiry, payment amount, identity number, ownership relationship or access grant silently. Require confirmation unless an exact deterministic rule previously approved by the user applies; even then retain provenance and undo/audit.

**VERIFIED FACT:** Google Document AI lists Enterprise OCR at USD 1.50/1,000 pages after its first 1,000-page monthly free tier, custom classification at USD 5/1,000 pages, and custom/form extraction at USD 30/1,000 pages. Pretrained invoice/expense parsers are USD 0.10 per document count (up to 10 pages). Prices and availability vary by processor/region. [Google Document AI pricing](https://cloud.google.com/products/document-ai/pricing).

**ESTIMATE:** raw OCR is not the dominant variable cost at household volume; specialised parsing, repeated reprocessing, previews, support and always-on infrastructure can dominate. At 40 new two-page documents/family/month, Google list pricing implies about USD 0.12/family/month for OCR + custom classification + custom extraction (`80 × ($1.50+$5+$30)/1000`), before free tier, LLM, storage and network. Using a USD 0.10 specialised parser on every document would instead be about USD 4/family/month, so routing only eligible documents matters.

### Accuracy benchmark required before build expansion

**NEEDS RESEARCH:** No provider’s generic benchmark establishes accuracy for NZ/AU policies, council notices, WOF documents, phone photos, faded receipts or mixed layouts. Run a consented, de-identified 500-document benchmark spanning at least 10 priority classes and adverse image conditions. Measure:

- classification precision/recall and “unknown” rate;
- exact-match and normalized accuracy for provider, policy/account number, date, amount, address, registration and serial number;
- confidence calibration (accuracy by confidence band);
- document/page failure and human correction time;
- false reminder rate; and
- provider, device, language and document-class slices.

**PROPOSAL threshold:** no autonomous commit for critical facts; ≥95% precision for high-confidence review suggestions in priority classes, ≥90% correct entity association, and median human confirmation under 20 seconds. Failure should produce “needs review,” never invented data.

## Information model

**PROPOSAL:** begin with PostgreSQL-style relational storage, JSON only for provider-specific raw metadata, a vector extension/service behind an interface, and a typed-edge table. This provides transactions, constraints, row-level tenant controls and ordinary reporting while preserving graph-like traversal. A native graph database is not justified until measured multi-hop query/performance needs exceed this model.

Core concepts:

- `family`, `member`, `membership`, `role`, `policy`, `grant`;
- `entity` with typed subtypes: person, property, vehicle, pet, provider, account, asset;
- `document`, `document_version`, `source_locator`, `source_access_state`;
- `relationship(subject, predicate, object, valid_from, valid_to, provenance)`;
- `extraction_run`, `fact_candidate`, `confirmed_fact`, `source_span`, `confidence`;
- `event`, `reminder`, `acknowledgement`;
- `content_chunk`, `search_vector_reference`, `embedding_model_version`;
- immutable security/audit events kept separately from mutable activity history.

**PROPOSAL:** permissions attach to resources and containers with explicit inheritance, deny/exception semantics designed with the Security/Privacy workstream. Every edge and derived fact inherits the maximum sensitivity of its sources unless explicitly downgraded by an authorised owner. Search indexes must carry family, principal, resource and sensitivity filters; a vector database is never the authorization authority.

## Search and AI retrieval

**PROPOSAL:** use a permission-filtered query planner:

1. authenticate principal and resolve current family membership/grants;
2. execute structured queries first for dates, amounts and linked entities;
3. hybrid lexical/vector retrieval only over authorised chunks;
4. re-check authorization on each source/document version;
5. generate a bounded answer from retrieved evidence;
6. return field/document citations, source status and uncertainty;
7. abstain when evidence is missing, stale, conflicting or inaccessible.

Embeddings are sensitive derived personal data. Encrypt tenant identifiers and content at rest, use per-family logical partitioning plus database isolation controls, never mix family corpora in prompts, and delete/rebuild vectors when the source or consent is deleted. Exact financial/identity identifiers should use normalized encrypted/tokenized lookup rather than embeddings.

**VERIFIED FACT:** OpenAI states API data is not used for model training unless the customer opts in, but default abuse-monitoring logs can retain customer content for up to 30 days; zero-data-retention controls require eligibility/configuration and endpoint review. This is not equivalent to end-to-end encryption. [OpenAI data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint).

**PROPOSAL:** sensitive categories (identity, legal, financial; health if ever added) should default to deterministic/local extraction or an explicitly contracted zero-retention processing path, with clear per-category consent. “Local AI” is a future deployment option, not an MVP promise: it adds device/server model distribution, quality variance and support cost.

## Onboarding feasibility (10–15 minute target)

**ASSUMPTION:** A target user has at least 10 relevant documents already grouped or easily selected in Drive.

**PROPOSAL first-value flow:** create family → create one property/person/vehicle or accept suggestions → connect Google → Picker-select one prepared folder or 10–30 files → process in background → show 3–5 high-confidence suggestions and one expiry timeline → user confirms → demonstrate sourced search.

The target is realistic only for a curated subset, not a whole-drive scan. Give an immediate progress state and allow exit/re-entry. Do not ask users to build the family graph before extraction; infer candidates, then confirm. Success metric: 80% of completed connector users see at least three correct suggestions within 15 minutes, with fewer than two minutes of manual input.

## Indicative variable-cost model

All figures below are **ESTIMATES in USD/month**, excluding tax, customer acquisition, staff, security assessment, support, payment fees and vendor minimums. They are not vendor quotes.

Assumptions per monthly active family: 40 new documents × 2 pages = 80 pages; 50% native text/on-device so 40 cloud-OCR pages; all 80 pages classified/extracted using Google list-price proxies; 20 AI questions; 10,000 input + 1,000 output tokens across extraction/questions on a small model; 25 MB derived encrypted data; event-driven connector traffic. Google pricing proxy: OCR $1.50/1k pages, classifier $5/1k, extractor $30/1k. LLM proxy uses GPT-5 mini published price of $0.25/M input and $2/M output, but a production workload requires measurement. [GPT-5 pricing](https://openai.com/index/introducing-gpt-5-for-developers/).

| Active families | Pages/month | OCR/classify/extract | LLM/embeddings | DB/index/queue/notifications | Total variable + shared infra range | Per family |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 80,000 | ~$2,980 | ~$10–$80 | ~$400–$1,500 | ~$3,400–$4,600 | ~$3.40–$4.60 |
| 10,000 | 800,000 | ~$29,800 | ~$100–$800 | ~$2,000–$8,000 | ~$31,900–$38,600 | ~$3.19–$3.86 |
| 100,000 | 8,000,000 | ~$292,800 | ~$1,000–$8,000 | ~$12,000–$50,000 | ~$306,000–$351,000 | ~$3.06–$3.51 |

The OCR/extraction subtotal is `40×1.50/1000 + 80×5/1000 + 80×30/1000 = $2.86/family`; table totals include modest retry/processing contingency and volume-tier OCR only at the largest tier. This deliberately conservative model sends every page to a USD 0.03/page custom extractor. **PROPOSAL:** native text + deterministic parsing + LLM routing should target under USD 0.50/family/month for document intelligence after onboarding. If production benchmarks cannot reduce steady-state intelligence cost below USD 1.00/family/month at the proposed usage, re-price or narrow the feature.

**ESTIMATE:** Initial backfill is bursty: 500 two-page documents with the conservative pipeline costs about USD 35.75 per family before retries; it cannot be subsidised without a cap, deferred queue, cheaper routing or paid onboarding allowance. BYOS removes original-object storage but does not remove retrieval, OCR, index or support costs.

## Architecture options and recommendation

### Option 1 — Hosted-first

Technically simplest and most reliable. Reject as the lead hypothesis because it weakens user ownership differentiation and creates an immediate high-sensitivity vault. Keep as an explicit fallback for capture/forwarding.

### Option 2 — Pure BYOS, client-side index

Strongest privacy story, weakest cross-device reliability and automation. Background email processing, family sharing, reminders and server RAG become difficult. Reject for MVP.

### Option 3 — Hybrid BYOS originals + service index (**recommended for validation**)

The smallest architecture that can test the core promise. It retains provider dependency and a sensitive metadata service, so security controls and transparent data maps are mandatory. Google Drive first; add providers only after connector retention and support burden are measured.

## Key technical risks and stop conditions

| Risk | Classification | Mitigation / validation |
|---|---|---|
| Permission leak through search, snippets or relationships | Critical | Deny-by-default retrieval; authorization tests across every derived artefact; independent security review. |
| OAuth token compromise | Critical | KMS/HSM-backed envelope encryption, token isolation, rotation/revocation, no client/log exposure. |
| Extraction creates a false expiry/payment/identity fact | High | Field confidence, source spans, conflict rules, mandatory confirmation, audit/undo. |
| BYOS source disappears or ACL changes | High | Stale/source-unavailable state, cursor reconciliation, no unsupported answer. |
| Gmail verification rejected or too costly | High commercial | Forwarding MVP; verify policy eligibility before committing Phase 2. |
| Backfill cost/support overwhelms ARPU | High commercial | Limits, routing, paid processing allowance, benchmark before pricing. |
| Provider semantics diverge | Medium-high | Connector contract and conformance suite; do not promise parity. |
| E2EE marketing conflicts with server intelligence | High trust | Do not claim E2EE; publish an accurate data-flow/retention disclosure. |

**Stop/reshape criteria (PROPOSAL):** stop broad BYOS development if Google selected-file access cannot deliver a comprehensible repeat-use workflow; if ≥5% of indexed sources become silently stale monthly without reliable recovery; if benchmark precision misses the stated thresholds after two extraction iterations; if fewer than 60% of target users consent to storing derived OCR text; or if privacy testing shows users materially misunderstand where derived data lives.

## Decisions requested at the discovery gate

1. Approve **hybrid Google-Drive-first validation**, not production architecture.
2. Keep mailbox OAuth out of MVP; validate forwarding and manual share first.
3. Approve a representative-document benchmark before substantial coding.
4. Require confirmation for critical extracted facts and citations for every AI answer.
5. Treat derived OCR text/embeddings as sensitive stored family data and reject absolute “files never leave your storage” messaging.
6. Cap MVP to selected Drive content, mobile capture/manual upload, people/property/vehicle relationships, expiry reminders, and permission-filtered sourced retrieval.

## Source register — all checked 2026-08-17

| Source | Supports |
|---|---|
| [Google Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth) | `drive.file`, restricted scopes, verification and token guidance |
| [Google Drive changes](https://developers.google.com/workspace/drive/api/guides/manage-changes) | change feed and watch pattern |
| [Google Drive sharing](https://developers.google.com/workspace/drive/api/guides/manage-sharing) | provider ACL/permission behaviour |
| [Google Workspace user-data policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy) | approved/prohibited Drive and Gmail API uses |
| [Gmail push](https://developers.google.com/workspace/gmail/api/guides/push) | label filters, history reconciliation, reliability and expiry |
| [Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes) | restricted scope classification |
| [Google security assessment](https://support.google.com/cloud/answer/13465431) | annual restricted-scope assessment |
| [Microsoft Graph permissions](https://learn.microsoft.com/en-us/graph/permissions-reference) | Files/Mail delegated permission semantics |
| [Microsoft drive delta](https://learn.microsoft.com/en-us/graph/api/driveitem-delta?view=graph-rest-v1.0) | incremental OneDrive changes |
| [OneDrive webhooks](https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/using-webhooks?view=odsp-graph-online) | change notification scope/limitations |
| [Outlook notifications](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview) | mail notification capability |
| [Microsoft throttling](https://learn.microsoft.com/en-us/graph/throttling) | 429/backoff and event-driven guidance |
| [Dropbox OAuth](https://developers.dropbox.com/oauth-guide) | App Folder/Full Dropbox, scopes and refresh tokens |
| [Dropbox file access](https://developers.dropbox.com/dbx-file-access-guide) | IDs, namespaces, traversal and metadata |
| [Dropbox SDK list-folder](https://dropbox.github.io/dropbox-sdk-js/Dropbox.html) | cursors, continuation, long-poll and revision capability |
| [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images) | on-device OCR and confidence |
| [Android ML Kit text recognition](https://developers.google.com/ml-kit/vision/text-recognition/v2/android) | device OCR and image-quality dependency |
| [Google Document AI pricing](https://cloud.google.com/products/document-ai/pricing) | OCR, classifier and extraction price proxies |
| [AWS Textract AnalyzeExpense](https://docs.aws.amazon.com/textract/latest/APIReference/API_AnalyzeExpense.html) | alternative invoice/receipt structured extraction |
| [OpenAI data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint) | training, default retention and ZDR conditions |
| [OpenAI GPT-5 pricing](https://openai.com/index/introducing-gpt-5-for-developers/) | LLM unit-cost proxy |

