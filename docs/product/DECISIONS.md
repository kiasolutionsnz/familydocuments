# Family Passport — Decision Log

LAST REVIEWED: 2026-08-17 (Pacific/Auckland)  
RESEARCH OWNER: Factory Orchestrator / CEO gate owner  
SOURCES: Five completed factory handoffs, their artifacts, and all documents in this product directory  
COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore; Ireland screened  
VERIFICATION STATUS: DISCOVERY SYNTHESIZED; INDEPENDENT COMMERCIAL GATE = VALIDATE; USER/CEO DIRECTION PENDING

## D-001 — Discovery before implementation

- Status: DECIDED
- Classification: VERIFIED FACT (user instruction and factory governance)
- Decision: Do not create an implementation project or modify production code. Complete and persist commercial discovery first.

## D-002 — Commercial-discovery gate

- Status: INDEPENDENT GATE COMPLETE — VALIDATE; USER/CEO DIRECTION PENDING
- Classification: VERIFIED FACT (five completed handoffs and independent gate review)
- Evidence: Open-source, market, independent commercial, technical and privacy/security artifacts are persisted in the factory run and product workspace.
- Independent gate outcome: VALIDATE only. Substantial implementation remains blocked; only the bounded Phase 0 evidence programme is allowable, subject to approvals for external actions.

## D-003 — Product direction

- Status: PENDING CEO DECISION
- Classification: PROPOSAL supported by completed discovery
- Decision proposed: Authorize only Phase 0 customer, trust, price, extraction-cost and security validation. If thresholds pass, consider a greenfield provider-neutral metadata/permission core integrated with commodity open-source components. Reject a broad Family OS build and complete-DMS fork. Do not proceed if thresholds fail.

## D-004 — Lead problem and customer

- Status: PENDING CEO DECISION
- Classification: PROPOSAL / ASSUMPTION
- Decision proposed: Lead with finding household proof/policies and preventing expensive missed renewals without migrating originals. Test with NZ adult household administrators who own/manage a property and vehicle and already use Google Drive.

## D-005 — Positioning

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT / PROPOSAL
- Evidence: Trustworthy already uses “The Family Operating System.” “Family Passport” can imply identity/travel scope.
- Decision proposed: Test “Household Records Assistant” as the descriptive category; do not use “Family OS” and do not lead with “Family Passport.” Final name remains a validation question.

## D-006 — MVP boundary

- Status: PENDING CEO DECISION
- Classification: PROPOSAL
- Decision proposed: Maximum seven capabilities: adult household/security; selected Google Drive/manual capture; four bounded record classes; people/property/vehicle relationships; confidence/provenance and critical-field confirmation; reminders/monthly digest; permission-filtered source-cited retrieval.
- Explicit exclusions: Mailbox OAuth, full-drive indexing, multiple providers, bills analytics, full inventory, health, dependents, emergency access, sensitive financial/legal automation, autonomous critical actions, ads and E2EE/zero-knowledge claims.

## D-007 — BYOS architecture hypothesis

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT / NEEDS RESEARCH / PROPOSAL
- Evidence: Selected-file Google Drive access and incremental provider reconciliation are technically feasible. No leading reviewed vault evidenced provider-neutral originals. Derived OCR text, metadata, embeddings and tokens remain sensitive service-held data.
- Decision proposed: Validate a hybrid Google-Drive-first design: originals remain in selected Drive locations; the service stores minimum encrypted derived data. Do not claim E2EE or that data never leaves storage.

## D-008 — Modules

- Status: PENDING CEO DECISION
- Classification: PROPOSAL
- Decision proposed: Property is the anchor; vehicles and limited warranty/receipt capture support it. Email forwarding/manual share may enter Phase 2; mailbox OAuth only after separate demand and policy validation. Bills are optional Phase 2, full assets later, health excluded.

## D-009 — Monetisation

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT / ESTIMATE / PROPOSAL
- Evidence: Competitor subscriptions verify a paid niche; target conversion is unobserved. Advertising inventory is estimated to be immaterial and conflicts with trust.
- Decision proposed: Test an annual Family subscription at NZ$120–150 with a limited free value demonstration. No ads, no sale/content targeting, and no Plus tier until measured usage and costs support it.

## D-010 — Launch sequence

- Status: PENDING CEO DECISION
- Classification: PROPOSAL
- Decision proposed: New Zealand is the validation market, Australia the first commercial follow-on, then selected English-language markets. NZ localisation must remain modular and is not treated as a moat.

## D-011 — Validation and stop criteria

- Status: PENDING CEO DECISION
- Classification: PROPOSAL
- Continue thresholds: ≥60% recent incident signal; ≥50% selected-Drive willingness; ≥70% useful activation within 15 minutes; ≥20% credible NZ$120/year choice or ≥10% refundable deposit; ≥40% 90-day retention; ≥30% monthly meaningful use; zero cross-household permission findings.
- Technical benchmark: ≥95% precision among high-confidence suggestions, ≥90% correct entity association, median confirmation <20 seconds and zero autonomous critical commits on a representative 500-document corpus.
- Stop/pivot thresholds: Drive acceptance <30%; activation <50%; critical precision <80%; paid intent <10%; retention <25%; support >20 minutes/activated family; BYOS does not improve trust/purchase; or users prefer Drive + calendar.
- Stop outright if viability depends on ads, broad mailbox/file scope, misleading privacy claims or unsafe health/emergency/dependent functionality.

## D-012 — Open-source decision

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT / PROPOSAL
- Decision proposed: Do not fork a complete DMS. If validation passes, integrate replaceable commodity components such as OCRmyPDF/Tesseract after exact-version SBOM, security, licence and legal review. Independently author the differentiated provider, permission, confidence and family-relationship core.

## D-013 — Security boundary

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT / PROPOSAL
- Decision proposed: Treat the product as HIGH inherent risk with CRITICAL-impact failure modes. Require adult-only scope, least privilege, passkeys/MFA, high-assurance recovery, encrypted OAuth tokens, deny-by-default authorization across every derived artifact, source deletion propagation, auditability and an independent privacy/security/legal gate before public beta.

## D-014 — CEO gate ownership

- Status: PENDING CEO DECISION
- Classification: VERIFIED FACT (factory governance)
- Decision: The product-owner recommends VALIDATE but does not approve it. No architecture, implementation, outreach, commercial account, licence, purchase or production action is authorized by this log.

## D-015 — OCR selection workstream

- Status: INDEPENDENT RECHECK PASSED FOR GATED PREFLIGHT; CANDIDATE EXECUTION BLOCKED
- Classification: VERIFIED FACT / PROPOSAL / NEEDS RESEARCH
- Decision: Do not select a universal OCR engine from vendor claims. Benchmark an engine-neutral routed pipeline: native PDF text; device capture guidance; OCRmyPDF/Tesseract baseline; PaddleOCR and RapidOCR challengers; Docling selective layout; Google Document AI Sydney lead cloud fallback with Azure Australia East and AWS Sydney challengers; mandatory critical-field provenance and confirmation.
- Gate: Production selection requires the privacy-safe 500-document/1,000-page benchmark and independent review. The protocol is ready only for approved synthetic-corpus and artifact/hash/SBOM preflight. Before any candidate execution, the normative manifest must bind to frozen detailed IDs; roles, approvals, package/model hashes, SBOM/licences, corpus/annotation quality, power simulation, routing/device/reviewer freeze and regional cloud controls must pass. No real personal documents, cloud upload, vendor commitment or application implementation is authorised.

## D-016 — Product-definition readiness

- Status: INDEPENDENT REVIEW PASS; CEO PRODUCT-DIRECTION DECISION REQUIRED
- Classification: VERIFIED FACT / PROPOSAL
- Evidence: The product-definition pack contains exactly seven MVP capabilities and resolved the independent review findings for authentication/recovery, role-action-resource permissions, manual-upload custody/export/deletion, passport expiry-only processing, and authoritative validation metrics.
- Decision requested: VALIDATE (recommended), GO, or NO-GO. A VALIDATE decision authorises only bounded Phase 0 preparation and separately approved execution. It does not authorise technical planning or application implementation.

## D-017 — CEO product-direction outcome

- Status: GO RECORDED 2026-08-19
- Classification: VERIFIED FACT (explicit user/CEO instruction)
- Decision: Proceed with development of the focused seven-capability Household Records Assistant despite the earlier validation-first recommendation. UI must be calm, easy, visually impressive, low-density and use an accessible, coherent colour scheme.
- Boundary: GO authorises the dependent design and planning stages. Production application implementation begins only after the visible experience baseline and MVP architecture/delivery pack pass their required human gates. Deferred and excluded scope remains unchanged.

## D-018 — Experience baseline readiness

- Status: INDEPENDENT UX REVIEW PASS; HUMAN APPROVAL REQUIRED
- Classification: VERIFIED FACT / PROPOSAL
- Evidence: Competitive UX research and the revised experience baseline define J1–J7, S01–S17, desktop and 320px layouts, full screen-specific states, recovery/leakage behavior, custody/sharing/revocation/deletion/recovery consequences, semantic navigation, accessible colour tokens and responsive behavior.
- Visual direction: warm neutral surfaces, restrained teal primary actions, dark readable typography, coral/amber only for attention and warning, spacious action-first layouts and limited navigation.
- Decision requested: Approve the experience baseline, request revisions, or reject it. Technical planning and implementation remain blocked until human approval.

## D-019 — Human experience-baseline outcome

- Status: APPROVED 2026-08-19
- Classification: VERIFIED FACT (explicit user instruction to move to the next stage)
- Decision: The independently reviewed experience baseline is the implementation contract for technical planning. Material substitutions require a versioned baseline decision and human approval.

## D-020 — MVP-and-architecture readiness

- Status: INDEPENDENT SECURITY/PLANNING PASS; HUMAN APPROVAL REQUIRED
- Classification: VERIFIED FACT / PROPOSAL
- Architecture: Modular Supabase/PostgreSQL core, selected-file Google Drive adapter, separate credentialed acquisition broker, uncredentialed controller and ephemeral network-none parser sandbox, replaceable confirmation-gated OCR, source-cited structured retrieval, private workers and no public database/admin surface.
- Delivery: 42 dependency-ordered planning cards expanded where required for the isolated document pipeline; all J1–J7/S01–S17 experience rows remain NOT STARTED / NOT VERIFIED.
- Gate order: FP-002 independent review PASS → FP-001 human approval → FP-003 authentication feasibility and FP-004 Supabase isolation preflight → implementation foundation only if both pass.
- Decision requested: Approve, request changes, or reject the MVP-and-architecture pack. Approval does not waive the fail-closed FP-003/FP-004 feasibility gates or authorize production deployment.

## D-021 — Human MVP-and-architecture outcome

- Status: APPROVED 2026-08-19
- Classification: VERIFIED FACT (explicit user approval)
- Decision: Begin bounded FP-003 authentication assurance and FP-004 disposable Supabase isolation/containment feasibility work.
- Boundary: No production database, platform deployment, public ingress, secrets, real personal data or general application implementation is authorised until both feasibility gates pass independent verification.

## D-022 — Feasibility-gate outcome

- Status: NEEDS REVISION 2026-08-19
- Classification: VERIFIED FACT (executable spike evidence and independent security review)
- FP-003: FAIL. The provider-neutral contract tests passed, but no assessed authentication candidate proved every mandatory control end-to-end. The reference harness also left step-up replay and complete recovery credential rotation unresolved.
- FP-004: FAIL for shared-platform approval. Synthetic PostgreSQL role, FORCE-RLS, signed transaction context and family-isolation checks passed. Live reciprocal Bodycorp isolation, exact-host acquisition-broker egress, controller isolation and hostile-parser containment were not proven; referenced containment/cleanup evidence files were also missing.
- Decision: FP-005 and general application development remain blocked. The recommended bounded next path is (1) an authorised live synthetic authentication-provider spike with app-side online session authority and (2) a revised dedicated Family Passport API/database and isolated document-processing topology, followed by fresh independent review.

## D-023 — Human approval for bounded feasibility revision

- Status: APPROVED 2026-08-19
- Classification: VERIFIED FACT (explicit user approval)
- Decision: Proceed with the dedicated Family Passport API/database and isolated broker-controller-parser architecture revision, plus a disposable live synthetic authentication-provider spike.
- Boundary: Synthetic data only. No production deployment, public ingress, real family documents, purchases, embedded secrets or FP-005/general application implementation. Both outputs require fresh independent security review before the build foundation can start.

## D-024 — Revised feasibility outcome

- Status: PARTIAL PASS / BLOCKED 2026-08-19
- Classification: VERIFIED FACT (executable tests, read-only platform preflights and independent security reviews)
- Architecture: FP-002R passed independent planning review. The dedicated Family Passport API/database and isolated gateway/controller/launcher/parser design is approved for disposable runtime proof only.
- Authentication: The corrected local assurance harness passes its current tests, but no eligible stable GoTrue/Auth and PostgreSQL pair proves the required passkey-to-AAL2 behavior. Provider execution and FP-003 remain blocked. Continuing requires either a different authentication provider/assurance strategy or a later compatible stable release.
- Runtime isolation: FP-004R remained fail-closed and made no platform mutation. Runtime candidates are not selected/promoted. The preflight now performs real cryptographic checks, but the independent review found remaining trust-anchor/schema/aggregate-binding consistency defects; a reviewer-owned trust registry and exact promoted candidates are still required.
- Decision: FP-005 and general application implementation remain blocked. No production system, public ingress, secret, real family data or application feature was changed.

## D-025 — Human approval of revised MVP authentication

- Status: APPROVED 2026-08-19
- Classification: VERIFIED FACT (explicit user approval)
- Decision: Replace the MVP passkey requirement with a stable email/password or magic-link sign-in plus TOTP MFA at AAL2. Passkeys move to Phase 2 and require a separately verified provider/runtime contract before release.
- Security boundary: Owner and Family Admin sensitive actions still require recent AAL2 step-up; recovery, revocation, session rotation, anti-enumeration, rate limiting, CSRF/PKCE/redirect controls and audit requirements remain fail-closed. Magic links alone are not sufficient for sensitive access.
- Delivery boundary: This approval authorises documentation and executable feasibility revision plus independent security review. FP-005 remains blocked until the revised authentication gate and the dedicated-runtime FP-004R gate pass.

## D-026 — Revised FP-003 feasibility result

- Status: BLOCKED / PULL-ONLY APPROVAL REQUIRED 2026-08-19
- Classification: VERIFIED FACT (19/19 synthetic tests and independent security review)
- Result: The revised email/password plus TOTP contract and recovery state-machine harness pass all 19 synthetic tests. Provider-native behavior, browser flow, distributed rate limiting, Argon2id runtime behavior and external notification acceptance remain unproven without an exact provider/database runtime.
- Candidate inspection request: Pull only the official candidate tags `supabase/gotrue:v2.189.0` and `supabase/postgres:17.6.1.136`, resolve immutable digests and run provenance/licence/vulnerability/CISA checks. Do not start containers. Any policy failure rejects the candidate.
- Boundary: D-025 did not authorize image pulls. FP-005 and all general implementation remain blocked pending explicit approval, candidate-policy PASS, runtime FP-003V PASS and FP-004V PASS.

## D-027 — Supabase Auth/PostgreSQL candidate image rejection

- Status: REJECTED 2026-08-19
- Classification: VERIFIED FACT (immutable digest inspection and Docker Scout reports)
- Authorization: The user explicitly approved pull-only inspection. The inspection did not start or create any new container, network, volume, secret, account, SMTP service or production resource. Independent review found pre-existing shared-platform `supabase-auth` and `supabase-db` containers already using these tags; they predate this inspection and were not changed.
- Auth candidate: `supabase/gotrue:v2.189.0` resolved to `sha256:385184459f57569c54c25209f51f3b2be99ddd7c4ce9e3555b5d3eea8447b7cf`; 11 Critical / 32 High, of which 11 Critical / 31 High are fixable; zero CISA KEV matches.
- Database candidate: `supabase/postgres:17.6.1.136` resolved to `sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00`; 5 Critical / 28 High, of which 2 Critical / 25 High are fixable; zero CISA KEV matches.
- Decision: Both images fail the platform image policy and must not be started or promoted. FP-003V and FP-005 remain blocked.

## D-028 — Next authentication candidate for inspection

- Status: APPROVAL REQUIRED 2026-08-19
- Classification: PROPOSAL / NEEDS RESEARCH
- Finding: The current official Supabase Compose set still pins the rejected Auth/PostgreSQL pair. Mixing a newer standalone Auth image into that set is not supported by upstream compatibility evidence.
- Proposed pull-only candidate: `ghcr.io/zitadel/zitadel:v4.16.2`, `ghcr.io/zitadel/zitadel-login:v4.16.2`, and `postgres:17.10-alpine`.
- Caveats: Exact three-image compatibility is inferred and requires inspection/runtime proof; ZITADEL core is AGPL-3.0-only and needs legal/commercial-use review; the upstream root/Docker-socket topology must not be adopted; D-025-specific SHA-256 TOTP, recovery and revocation requirements remain unproven.
- Boundary: New explicit approval must name all three pulls. Pulling would permit digest/provenance/licence/vulnerability inspection only, not starting containers, accepting terms, production use or FP-005.

## D-029 — Existing local image review

- Status: NO ELIGIBLE LOCAL SUPABASE PAIR 2026-08-19
- Classification: VERIFIED FACT (read-only Docker inventory and current Docker Scout reports)
- Finding: The locally cached newer Supabase pair (`gotrue:v2.194.0`, `postgres:17.6.1.156`) reports 8 Critical/11 High and 4 Critical/18 High findings and remains rejected.
- Historical clean image: `kia-postgres:15.18-gosu1.19-go1.26.4` was previously recorded as zero Critical/High for Ente. Current advisory data reports 3 Critical/25 High. It is generic PostgreSQL 15 without the Supabase extension/role/bootstrap contract and is not a drop-in Supabase database.
- Decision: No existing local Supabase Auth/database pair passes policy. No runtime or platform state was changed during this review.

## D-030 — ZITADEL candidate image rejection

- Status: REJECTED 2026-08-19
- Classification: VERIFIED FACT (immutable digest inspection and Docker Scout reports)
- Authorization: The user approved pull-only inspection of the proposed ZITADEL set. No container was started and no network, volume, secret, account, SMTP configuration or production resource was created or changed.
- Results: ZITADEL core reported 2 Critical/13 High; ZITADEL Login 1 Critical/12 High; PostgreSQL 2 Critical/20 High. Every reported Critical/High finding in these filtered reports was fixable. All three reported zero CISA KEV matches.
- Decision: Reject all three images under platform policy. Downloading did not accept ZITADEL's AGPL-3.0-only legal/commercial implications. FP-003V and FP-005 remain blocked.

## D-031 — Park infrastructure blockers and build isolated UI prototype

- Status: APPROVED 2026-08-19
- Classification: VERIFIED FACT (explicit user instruction)
- Decision: Defer authentication-provider and FP-004R runtime blockers for tonight. Build an isolated frontend-only prototype against the approved experience baseline using synthetic data and replaceable mock interfaces.
- Included: calm responsive shell; approved colour/type/spacing tokens; Home, Records, Add, Review and Search experiences; representative loading, empty, error, restricted and offline states; desktop and 320px layouts; keyboard/accessibility scaffolding.
- Excluded: real authentication, database, RLS, storage provider, OAuth, OCR/document processing, real household data, production deployment and any claim that FP-005 or the MVP is complete.
- Boundary: Prototype code must not become a backdoor around FP-003V/FP-004V. Production foundation remains blocked until those gates are resolved.

## D-032 — Isolated UI prototype outcome

- Status: COMPLETE FOR PROTOTYPE REVIEW 2026-08-19
- Classification: VERIFIED FACT (producer tests plus independent code and UX reviews)
- Delivered: Static HTML/CSS/JavaScript prototype with Home, Records, Add, Review, Search and Help; synthetic NZ household data; route-specific exceptional states; responsive/accessibility scaffolding; adapter-backed cited search, abstention and conflict handling; exact source focus restoration.
- Verification: Syntax and expanded model/state/action/safety regression tests pass. Independent code review reports no remaining P0/P1/P2 findings. Independent UX review passes the D-031 remediation by source/DOM/CSS inspection.
- Residual evidence: Running-browser verification at desktop/compact/320px, 200% zoom, keyboard-only, forced colours and reduced motion remains NOT VERIFIED because the configured browser runtime could not initialize. This is not an MVP, FP-005 completion or release approval.
- Blockers: Authentication-provider and FP-004R runtime issues remain parked for tonight exactly as approved.
- Normative resolution (2026-08-19): MVP primary sign-in is verified email/password. TOTP is the distinct second factor and required for Owner/Admin privileges and every sensitive resource-owner action. Magic links are limited to invitation/email verification and password-reset initiation; they are AAL1 only. Passkeys are Phase 2. This resolution explicitly supersedes the MVP passkey clauses in D-013 and all pre-D-025 product, experience, architecture and delivery artifacts while preserving their historical status as evidence.

## D-033 — Google Drive and OneDrive connector preview

- Status: APPROVED PROTOTYPE SCOPE 2026-08-19
- Classification: VERIFIED FACT for provider capabilities; PROPOSAL for production integration
- Decision: Show Google Drive and Microsoft OneDrive as equal, provider-neutral storage choices in the isolated prototype. The preview may simulate connect/disconnect and file selection but must not open OAuth, store tokens, contact a provider or read real files.
- Google boundary: Use Google Picker with the non-sensitive `drive.file` scope so access is limited to files the user explicitly selects or shares with the app. Do not request broad `drive` or `drive.readonly` scope for the MVP.
- OneDrive boundary: Use Microsoft OneDrive File Picker with delegated user access. Microsoft currently documents that `Files.Read.Selected` has limited support and should not be used for direct Microsoft Graph calls; exact-file persistent access therefore needs a separate feasibility/security decision before live implementation. Do not substitute `Files.Read.All` silently.
- Shared behavior: Show provider owner, exact selected file, version/staleness, last successful check and truthful disconnect consequences. Originals remain in the provider; derived metadata/text remain sensitive Family Passport data.
- Live gate: OAuth registration, callback handling, refresh-token custody, broker/gateway access, provider revocation and real files remain blocked by FP-003V/FP-004V and FP-030 dependencies.
- Sources checked 2026-08-19: https://developers.google.com/workspace/drive/api/guides/api-specific-auth ; https://developers.google.com/workspace/drive/api/guides/picker ; https://learn.microsoft.com/en-us/onedrive/developer/controls/file-pickers/ ; https://learn.microsoft.com/en-us/onedrive/developer/rest-api/concepts/permissions_reference

## D-034 — Isolated FP-030 connector contract spike

- Status: COMPLETE FOR SYNTHETIC CONTRACT REVIEW 2026-08-19
- Classification: VERIFIED FACT (6/6 executable synthetic tests); NOT PRODUCTION PROOF
- Delivered: Provider manifests, PKCE S256/state/nonce/session/provider/exact-redirect/expiry/single-use transaction contract, exact-file/version/account selection receipt validation, and local-disable-before-provider-revoke disconnect state machine.
- Safety result: Broad Google `drive`/`drive.readonly` and Microsoft `Files.Read.All`/`Files.ReadWrite.All` scopes are explicitly forbidden. Unknown fields, missing versions, wrong owners, replay, expiry and binding mismatch fail closed. Provider revoke failure cannot re-enable local access and originals are never changed.
- Boundary: No HTTP server, OAuth credential, token, token encryption implementation, provider SDK, network request, database or real file was created or used. OneDrive live scope selection remains blocked pending exact-file feasibility. Passing pure-contract tests does not satisfy FP-003V, FP-004V or FP-030.
- Evidence: `family-passport/spikes/fp030-connectors/README.md`, `connector-contract.mjs`, `connector-contract.test.mjs`.

## D-035 — FP-030 security-review revision

- Status: PRODUCER REVISION COMPLETE; INDEPENDENT RE-REVIEW REQUIRED 2026-08-19
- Classification: VERIFIED FACT (9/9 revised synthetic tests); NOT PRODUCTION PROOF
- Trigger: Independent review returned NEEDS_REVISION because the first spike did not encode its redirect, signed nonce, selection authenticity, connector overwrite and disconnect concurrency claims.
- Corrections: Immutable exact redirect allow-list; callback/code and signed ID-token claim verification separated; issuer/audience/subject/account/nonce binding; opaque short-lived owner/connector/account/file/version-bound selection grants with live-version observation; duplicate connector rejection; optimistic version plus idempotent/concurrent disconnect; inclusive expiry and malformed-input controls.
- OneDrive: Explicitly disabled for live authorization with an empty executable scope set. Separate personal/work, SharePoint/Graph token-audience, postMessage origin/channel and access-lifetime proof remains required.
- Evidence: 9 adversarial test groups pass. Fresh independent review is the only allowed next action; no live OAuth or provider registration is authorized.

## D-036 — FP-030 second security-review revision

- Status: PRODUCER REVISION COMPLETE; FINAL INDEPENDENT RECHECK REQUIRED 2026-08-19
- Classification: VERIFIED FACT (10/10 revised adversarial test groups); NOT PRODUCTION PROOF
- Corrections: Redirect policy itself now rejects HTTP, userinfo and fragments; token identity is returned only through an injected trusted verifier; server-issued picker sessions bind exact origin, message source and random channel nonce; file redemption consumes broker-owned live observation; disconnect authorizes before idempotency lookup and defines safe retry after provider-revoke failure.
- Regression evidence: Configured HTTP redirect, forged verification, invented picker channel/source/origin, live file-version substitution, wrong-owner operation replay and concurrent/retry cases fail closed.
- Boundary: OneDrive remains disabled and live OAuth remains prohibited pending final independent PASS plus the separate FP-003V/FP-004V/token-custody gates.

## D-037 — FP-030 isolated connector contract review PASS

- Status: COMPLETE FOR ISOLATED SYNTHETIC CONTRACT READINESS 2026-08-19
- Classification: VERIFIED FACT (16/16 producer tests plus independent adversarial recheck)
- Result: Independent Security Reviewer PASS. Exact redirect policy, trusted ID-token verification boundary, server-issued picker channel, owner/account/file/version grants, broker live observation, shared connector authority, disconnect generation invalidation, concurrency, retry and reconnect idempotency all pass the isolated contract gate.
- Critical lifecycle property: Disconnect rotates a lifecycle-owned non-reusable authorization generation. Pre-disconnect picker sessions/grants fail before broker access, in-flight redemption fails after recheck, and reconnect cannot reuse an old grant or idempotency receipt.
- OneDrive: Remains disabled for live authorization; no executable file scope is selected.
- Boundary: This PASS closes only the synthetic contract review. It does not authorize OAuth registration, credentials, accounts, network calls, tokens, real files or production integration. FP-003V, FP-004V and token custody remain prerequisites for a separately approved disposable Google-only test.
- Evidence: `software-factory/runs/family-passport-2026-08-17/delivery/fp030-connector-review/generation-final-pass.md` and `generation-final-handoff.json`.

## D-038 — Provisional PaddleOCR selection

- Status: APPROVED PROVISIONAL ENGINE 2026-08-19
- Classification: HUMAN DECISION / PROPOSAL; accuracy and operational fitness remain NEEDS RESEARCH
- Decision: Use PaddleOCR as the first self-hosted OCR implementation lane. Prefer native PDF text extraction before OCR and keep PaddleOCR behind a replaceable engine adapter.
- Frozen candidate: PaddleOCR 3.4.0, exact compatible PaddlePaddle CPU runtime to be resolved and frozen during approved acquisition, `PP-OCRv5_server_det`, English `en_PP-OCRv5_mobile_rec`, and PP-LCNet document orientation. CPU-only primary configuration; no automatic runtime model download.
- Mandatory safety: Confidence is advisory, not truth. Dates, amounts, identifiers, policy/account numbers and entity matches remain suggestions requiring source evidence and explicit user confirmation. Low-confidence, conflicting or unsupported output abstains.
- Validation: A large 500-document benchmark is deferred unless the smaller acceptance run is inconclusive. A representative 50–100 document pre-beta acceptance set remains required to measure critical-field accuracy, correction time, latency and fully loaded cost.
- Acquisition gate: Exact source commit, wheel/runtime/model hashes, licences/notices, SBOM, vulnerability results and OCI digest must be captured before execution. This decision alone does not approve floating dependencies, `latest` tags or unattended model downloads.

## D-039 — Reviewed authentication gateway contracts

- Status: COMPLETE FOR SYNTHETIC CONTRACT READINESS 2026-08-19
- Classification: VERIFIED FACT (17/17 producer tests plus independent security PASS); NOT RUNTIME PROOF
- Delivered: Provider-neutral email/password and Google OIDC contract; opaque sessions; trusted role/AAL invitation gating; verified-identity invite redemption; default-deny family/resource permissions; strict non-listening HTTP boundary with origin, schema, size, cookie, CSRF, limiter and timeout controls.
- Boundary: No listener, provider, database, credential, SMTP, browser execution, account or real identity. Full D-025 FP-003V and FP-005 remain blocked.
- Evidence: `delivery/fp003-auth-gateway-review/final-readiness.md` and `delivery/fp003-auth-http-boundary-review/final-readiness.md`.

## D-040 — Current self-hosted runtime candidates rejected

- Status: REJECTED 2026-08-19
- Classification: VERIFIED FACT (immutable local image metadata and Docker Scout)
- Keycloak: Official 26.7.1 digest `sha256:f1f1f01e...c01c6` reports 1 Critical/22 High.
- Ory Kratos: Official 26.2.0 digest `sha256:2a13bb8d...76643` reports 12 Critical/38 High.
- PostgreSQL: Local Chainguard digest `sha256:13d374b7...f219` reports 1 Critical/6 High and runtime user 0 in metadata.
- Decision: Images were downloaded/inspected only and never started. None may be promoted or deployed.

## D-041 — Managed Supabase bounded-test runtime proposal

- Status: SUPERSEDED BY D-043 2026-08-20
- Classification: PROPOSAL based on current official documentation
- Proposal: Create a new dedicated managed Supabase project for a synthetic AAL1 identity experiment only, behind the provider-neutral gateway and application-owned online session/authorization layer. Never reuse Bodycorp.
- Rationale: Official support exists for email/password, Google login, TOTP and AAL claims; Free currently includes 50,000 MAU and Pro starts at US$25/month. Current self-hosted candidates fail image policy.
- Limits: Refresh-token reuse exceptions and the absence of the exact 72-hour recovery contract mean Supabase alone does not pass D-025. Its TOTP implementation also does not prove frozen SHA-256 AB-06, so Supabase AAL2 is not accepted. Google OAuth registration, custom SMTP, region/privacy terms, revoke timing, database isolation and browser tests remain mandatory.
- Real data: Prohibited until a later explicit gate with deletion, backup, access-control and privacy evidence.

## D-042 — Google as an additional AAL1 primary identity

- Status: APPROVED; PRODUCER PROPAGATION COMPLETE; INDEPENDENT REVIEW REQUIRED 2026-08-19
- Classification: USER-DIRECTED PRODUCT DELTA
- Trigger: After D-025, the product owner explicitly requested sign-up/sign-in by email or Google.
- Proposed resolution: Add verified Google OIDC as an AAL1 primary identity alongside verified email/password. Google login never grants Drive access; Drive remains a separate exact-scope connector transaction.
- Unchanged: Application-owned SHA-256 TOTP AAL2 remains mandatory for Owner/Admin and sensitive actions; magic links remain restricted AAL1 support flows; five-minute step-up and 72-hour recovery remain frozen.
- Gate: Propagate this delta into product, experience, architecture, AB manifest and delivery criteria, then obtain independent security review before live Google execution.

## D-043 — Dedicated local Supabase email/password test runtime

- Status: DEPLOYED AND SYNTHETICALLY VERIFIED 2026-08-20
- Classification: OBSERVED LOCAL TEST STATE / TEMPORARY RISK EXCEPTION
- Decision: Use the same Docker host as Bodycorp but a completely separate minimal Compose project, `family-passport-supabase`. It shares no container, database, schema, network, volume or secret with Bodycorp.
- Runtime: Supabase Auth `v2.195.0`, Supabase PostgreSQL `17.6.1.159` and Mailpit `v1.30.2`. Studio, Meta, Kong, Realtime, Storage, Edge Runtime, Analytics, Vector and Pooler are excluded.
- Exposure: Auth `127.0.0.1:55321`; Mailpit `127.0.0.1:55324`; PostgreSQL has no host binding. `family_passport_db` is internal and disjoint from `supabase_db`.
- Auth controls: verified email required, minimum 14-character password, 300-second access token, refresh-token rotation with zero reuse interval, anonymous signup disabled.
- Verification: Passed signup without session, unverified sign-in denial, local email confirmation, verified password sign-in, weak-password denial and verified-user sign-in after a full three-container restart.
- Risk: Auth reports 8 Critical/10 High findings. This is a product-owner-approved loopback-only synthetic exception, not image promotion. Real family data, LAN/public ingress and production use remain prohibited until a compatible image set passes the production image gate.
- Evidence: `family-passport/local-backend`, `platform/family-passport-supabase/module.yml`, and `platform/decisions/ADR-0006-family-passport-local-supabase.md`.

## D-044 — Local preview connected to verified email/password Auth

- Status: IMPLEMENTED AND SYNTHETICALLY VERIFIED 2026-08-20
- Classification: BOUNDED LOCAL IMPLEMENTATION; NOT FP-003V/FP-005 PRODUCTION PASS
- Decision: Connect the existing preview sign-up/sign-in experience directly to the isolated loopback Auth endpoint for local synthetic testing.
- Controls: 14-character minimum, confirmation-required signup, verified password sign-in, in-memory-only tokens, explicit sign-out, generic failure messages, and disabled Google control.
- Hosted boundary: The published HTTPS preview is not updated to depend on a private loopback HTTP service. The working integrated preview runs locally at `http://127.0.0.1:3300`; port `3000` remains assigned to Ente.
- Verification: Vinext build and 2/2 static/rendered tests passed; Auth CORS preflight passed; backend signup/confirmation/sign-in/negative tests remained green.
- Remaining: application-owned SHA-256 TOTP, online session authority, recovery, persistent household authorization and Google OIDC remain separately gated.
- Evidence: `software-factory/runs/family-passport-2026-08-17/delivery/fp007-local-auth-integration/IMPLEMENTATION_EVIDENCE.md`.

## D-045 — Persistent local household, category and document-access foundation

- Status: IMPLEMENTED AND SYNTHETICALLY VERIFIED 2026-08-20
- Classification: BOUNDED LOCAL IMPLEMENTATION; NOT PRODUCTION APPROVAL
- Decision: Add pinned PostgREST `v14.12` to the isolated Family Passport Compose project and expose only the `fp` schema at loopback `127.0.0.1:55322`.
- Data model: households, active members, seven-day invitations, system/custom categories, document metadata and per-member document permissions.
- Controls: forced RLS on every table, no direct browser-role table grants, authenticated RPC-only writes, owner/admin mutation checks, invitation acceptance bound to the verified JWT email, default-deny document visibility and explicit access removal.
- Verification: Synthetic owner/member/outsider acceptance passed household bootstrap, invitation acceptance, custom category creation, unshared-document denial, explicit view grant, viewer write denial and outsider isolation. UI build and rendered tests passed.
- Limits: Invitation notification email, durable browser session authority, TOTP/step-up, real file ingestion, Google OIDC and production use remain outside this slice. Tokens remain memory-only and a reload requires sign-in again.

## D-046 — Local confirmation-gated PaddleOCR-to-reminder workflow

- Status: IMPLEMENTED AND FICTIONALLY VERIFIED 2026-08-21
- Classification: BOUNDED LOOPBACK SYNTHETIC IMPLEMENTATION; NOT REAL-DATA OR PRODUCTION APPROVAL
- Workflow: authenticated local PDF/photo selection → exact size/SHA-256 validation → ephemeral PaddleOCR processing → visible source text/confidence → required human confirmation → persistent document metadata/OCR text → optional confirmed-date reminder.
- Isolation: The dedicated Family Passport OCR container has no Bodycorp network, database, credential, queue or volume. It runs non-root, read-only, without capabilities, with bounded CPU/RAM/PIDs and ephemeral scratch.
- Verification: The fictional insurance-renewal PNG passed authenticated ingestion, PaddleOCR, explicit record confirmation, reminder creation, API health and unauthenticated denial. The source bytes were removed after processing.
- Image evidence: `kia/family-passport-paddleocr-api:0.1.0` image ID `sha256:a9f0e0d...b04e4`; Docker Scout quickview reported 0 Critical, 1 unfixed High and 0 fixable Critical/High. Missing attestations and copyleft-package distribution implications remain unresolved.
- Drive boundary: Google Drive remains disabled until an explicit Google Cloud OAuth client, Picker API key, exact redirect and independent live-connector approval exist. The app does not substitute broad Drive access.
- Real-data boundary: Real family files remain prohibited pending representative OCR acceptance, hostile-file containment, auth/session/TOTP/recovery, deletion/backups and privacy/security gates.

## D-047 — Household inbox, local-AI organisation and selective OCR

- Status: APPROVED REQUIREMENT; IMPLEMENTATION PENDING 2026-08-21
- Classification: USER-DIRECTED PRODUCT CHANGE
- Household email: Every household receives a separate random, unique, rotatable inbox alias. It is not the member's sign-in email and is never an authentication factor.
- Retention: Save the original RFC822 email and allowed PDF attachments with hashes and source lineage, plus separately stored derived metadata, tags and reminder facts.
- Organisation: Default categories include Bills, Subscriptions, Travel, Vehicles and Home; users can add custom categories. “Main house bills” and “Rental 1 bills” are category-plus-property saved views so permissions and reporting do not depend on hard-coded category names.
- AI: Local AI proposes category, entity, provider/merchant, dates, amount, recurrence and tags. It cannot choose the household, bypass access controls or silently commit uncertain critical values.
- OCR: Prefer email text, attachment metadata and native PDF text. Use bounded first-page/relevant-page OCR only when needed. Full OCR requires explicit user intent and audit evidence.
- Reminders: Confirmed bills and subscriptions create due/renewal reminders with duplicate/revision reconciliation.
- Internet gate: Production aliases require an approved domain/MX, TLS, SPF/DKIM/DMARC handling, spam/abuse controls, malware scanning, parser containment, monitoring, retention/export/deletion and real-data security approval.
- Specification: `docs/product/EMAIL_INGESTION.md`.
