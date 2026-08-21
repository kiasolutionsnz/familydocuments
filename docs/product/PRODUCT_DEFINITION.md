# Product definition — Household Records Assistant

LAST REVIEWED: 2026-08-19 (Pacific/Auckland)  
PRODUCT OWNER: Software Factory product-owner  
SOURCES: Complete Family Passport discovery pack, independent commercial gate, OCR selection/readiness review, and product-definition artifacts  
COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore; Ireland screened  
VERIFICATION STATUS: D-025 AUTHENTICATION BASELINE REVISION; INDEPENDENT AUTH REVIEW REQUIRED; NO IMPLEMENTATION AUTHORIZED

## Decision requested

Choose one:

- **VALIDATE (recommended):** authorize only the canonical Phase 0 evidence programme and return measured results to a later human gate.
- **GO:** not recommended from current evidence.
- **NO-GO:** stop the product direction.

This decision does not authorize application implementation, architecture commitment, external recruitment, deposits, purchases, vendor accounts/terms, licence commitments, personal-document uploads or production changes.

## Product thesis

For an NZ adult who administers a home and vehicles and already uses Google Drive, the Household Records Assistant helps find household proof/policies and avoid missed renewals. Users explicitly select 10–30 files; originals remain in Drive; the service proposes facts with confidence and provenance; users confirm critical facts; reminders and permission-safe retrieval cite exact sources.

**VERIFIED FACT:** Trustworthy already occupies the broad “Family Operating System” proposition and overlaps most proposed automation. **NEEDS RESEARCH:** whether selected-file BYOS improves trust, activation, payment and retention. The overall market is crowded; the exact BYOS + confirmed renewal + citation intersection is underserved but unvalidated.

## Seven-capability boundary

1. Adult-only household, strong authentication, private/shared item policy.
2. Google Picker-selected files plus manual photo/PDF capture.
3. Basic bounded OCR/classification for home/contents insurance or rates, vehicle/WoF/rego, passport expiry metadata, and receipts/warranties.
4. People, one property and vehicles in a relational typed-edge model.
5. Field confidence, provenance and explicit confirmation before critical facts become authoritative.
6. Reminders and monthly action digest.
7. Permission-filtered structured/hybrid retrieval with exact source citations.

OCR is replaceable and engine-neutral. Initial OCR is capped, basic and limited: native text first, bounded classes, advisory output and manual confirmation. Production engine selection requires the approved benchmark. Advanced layout, VLM, high-volume backfill, broad structured extraction and premium OCR allowances are deferred.

The authoritative OCR quality/cost/safety rules are the frozen artifacts under `software-factory/runs/family-passport-ocr-2026-08-18/benchmark-design/`, especially `benchmark-protocol.md` and its candidate manifest/readiness handoff. This definition does not restate a competing OCR threshold.

## Authentication, sessions and recovery — D-025 normative MVP baseline

**D-025 supersedes every earlier MVP passkey/WebAuthn clause.** Passkeys are Phase 2 only and require a separately approved stable provider/runtime contract.

**D-042 adds verified Google OIDC as a second AAL1 primary sign-in alongside verified email address + password.** Google uses exact HTTPS redirects, authorization code + PKCE, state, nonce and verified issuer/audience/time/email/subject claims. Its canonical identity key is provider issuer + subject; matching email alone never creates or links an account. Linking requires an already authenticated account, recent application-owned password+TOTP step-up and explicit confirmation; unlinking the last primary identity is prohibited. Google login and Google Drive authorization are separate clients, scopes and consent transactions. Passwords retain the frozen strong/leaked-password, hashing, response and rate controls. Magic links remain limited to invite/email verification and fail-closed password-reset initiation and never authorize sensitive access.

TOTP authenticator-app MFA is mandatory before Owner or Family Admin privileges can be exercised and available to every adult. Sensitive actions require fresh application-owned password reauthentication plus SHA-256 TOTP bound to session, action, target, epoch and a single-use five-minute challenge. A new Google-only identity is provisional with no household or role. It may atomically enrol a local password, application-owned TOTP and shown-once recovery codes within 900 seconds of its fresh first-session Google authentication; after expiry, elevation requires externally accepted notice and a cancellable 72-hour delay. Until commit it cannot create/join a household or perform privileged/sensitive actions. Email/SMS and provider-reported TOTP alone are not accepted as product AAL2.

Users can inspect and revoke sessions/devices. Recovery uses the D-025 controls preserved in complete standalone D-025/D-042 manifest v3 and the atomic state machine. Internal queue acceptance is insufficient: at least one pre-existing destination must have a verified external SMTP/provider acceptance receipt within five minutes before `notified_at` exists and exactly 72 hours (259,200 seconds) of cancellable cooling-off starts. If all notices hard-bounce, time out or remain ambiguous, recovery is terminal/non-completable and exposes only the generic public response. Replacement password+TOTP is staged without access; one serializable completion rotates all old credentials/sessions/codes and security epoch. Security questions, email/SMS-only privileged recovery, shortened waiting and support bypass are prohibited. No authentication vendor/runtime/tier is selected.

## Adult permission model

| Resource/action | Resource owner | Household Owner/Admin | Other adult |
|---|---|---|---|
| Adult-private item and derivatives | Full control | Denied unless explicitly granted | Denied unless explicitly granted |
| Shared household item | Per grant | Only explicit shared-policy access | Only explicit grant |
| Personal connector/token | Owner only | Never shared or exercisable | Never shared or exercisable |
| Search/citation/filename/count/thumbnail/reminder | Inherits source | No existence signal without source access | Same |
| Export/delete | Own and authorized shared scope | No private bypass | Own/granted scope |
| Audit | Own activity plus minimum authorized household security metadata | No private content | Same |

Membership/administration never grants another adult’s private content. Invitations require acceptance and give no private access by default. Authorization runs before retrieval/model access and again before answer/citation. Removal revokes grants, sessions, cached/offline results and derived access.

## Original custody and lifecycle

Drive-selected originals remain in Drive. Manual photo/PDF capture is an encrypted, non-backed-up transient copy destined for the user’s app-created/selected Drive location; indexing begins only after verified Drive write. Transient and failed-job originals delete within 24 hours after verified write or terminal failure, with visible pending/cancel/deadline state.

Derived OCR text, crops/thumbnails, facts, relationships, reminders and indexes are service-held. Export, derived-data deletion propagation and connector revocation are prerequisites before any private beta with real documents. Disconnect never deletes Drive originals. Drive deletion marks the source unavailable and does not itself delete derivatives. App-record deletion covers derivatives/caches/failed jobs and reports pending, complete or exception with processor/backup windows; only minimum content-free security audit may remain under approved policy.

## Passport-expiry safety boundary

Passport processing is optional, explicitly selected and expiry-only. Default route is native/device/local with a minimized source crop and user confirmation. Passport number, MRZ content, biometric data/image, nationality and other excluded fields are neither targeted nor retained in records, indexes, logs, analytics or notifications. Cloud/VLM is denied by default pending separate processor, Australian region, legal basis, consent, retention and deletion approval. If negative tests cannot prove this boundary, passports are removed from Phase 1.

## Explicit exclusions

Mailbox OAuth; whole-drive indexing; OneDrive/Dropbox/NAS; broad bills/spend analytics; full household inventory; health; dependents; emergency/legacy release; legal/financial/government extraction; autonomous critical actions; native graph infrastructure; ads; family-content model training; E2EE/zero-knowledge claims; advanced OCR as a default entitlement.

## Mandatory user journeys and surfaces

| Journey | Required surfaces | Outcome |
|---|---|---|
| Trust and start | Trust/consent, Help | User understands original versus derived custody and selected scope. |
| Secure household | Sign-in/recovery, household setup | Adult household exists with private/shared defaults. |
| Select/capture | Drive Picker, manual capture, progress | Only chosen material is processed; scope and failures are visible. |
| Confirm | Review queue, source viewer | User confirms/corrects/skips/rejects with source evidence. |
| Act | Dashboard, entity record, reminders | Confirmed upcoming actions relate to person/property/vehicle. |
| Retrieve | Search/results/answer/source | Authorized result cites exact source and abstains when uncertain. |
| Control data/access | Sharing, sync, privacy/export/delete | User understands and controls grants, stale links and derived data. |

All screens require applicable first-use, loading, empty, success, error, restricted, stale/source-unavailable, deletion pending/exception and offline/retry states. Mobile prioritizes capture/review/retrieval; desktop supports batch review/context. The later experience baseline must cover 320px/200% reflow, keyboard, visible focus, semantic labels, error summaries, non-colour status cues and WCAG 2.2 AA contrast.

## Phase 0 contract

- 25–40 interviews: ≥60% recent pain; ≥40% improvised system.
- ≥50% selected-Drive willingness after truthful derived-data disclosure; <30% stops BYOS.
- ≥20% credible NZ$120/year choice or ≥10% separately authorized refundable deposit; <10% stops/repositions.
- Fifteen-household assisted workflow: ≥70% enrolled achieve useful output in 15 minutes; ≥80% connector completers see three correct suggestions.
- OCR benchmark passes every applicable hard gate and selection rule in its authoritative frozen protocol; zero silent commits.
- ≥40% meaningful 90-day retention and ≥30% monthly meaningful use; <25% stops.
- Zero cross-household permission findings; support <20 minutes per activated family.

## Commercial model

Test a limited free demonstration followed by NZ$120–150/year Family subscription. No ads. Do not promise Plus or premium OCR until processing distribution, quality, privacy and margin are measured. B2B2C partnerships may be researched later without exclusivity or private-data rights.

## Build/reuse decision

Do not adopt/fork a complete DMS. If Phase 0 and the CEO gate later pass, independently author the provider-neutral metadata, relationship, permission, confidence/provenance and reminder core. Integrate replaceable commodity OCR/PDF/search components only after benchmark, SBOM, security, licence and legal review. No vendor or licence is selected here.

## Phases

- Phase 0: evidence programme only.
- Phase 1: conditional seven-capability minimum workflow, including beta-prerequisite session/recovery, explicit authorization, export/deletion/revocation and lifecycle controls within C1/C2/C7.
- Phase 2: forwarding/manual share, richer export/deletion administration, reconciliation hardening and limited asset/warranty test.
- Phase 3: AU localisation, paid-demand second provider, selective deeper property/vehicle/advanced OCR differentiation.
- Phase 4: routing/cost/support optimization and optional premium processing.

Every phase has a new gate; roadmap presence is not authorization.

## Measurement definitions

Meaningful use means confirming/correcting a new record, acting on a due reminder, or retrieving/opening a cited source; login/passive view does not count. Credible paid choice is a consequential priced choice against a realistic DIY/free alternative; stated intent is separate and deposits need approval. A correct suggestion has correct value, document, entity and provenance. Useful output means at least three correct relevant suggestions plus successful exact-source opening within 15 minutes. A security finding is any reproducible unauthorized disclosure/action, bypass, weak session/recovery behavior, sensitive logging or deletion failure. Phase 0 zero findings is only a rejection screen, not proof of production isolation. Deletion completes only when live derivatives are absent, processor deletion is evidenced, backup expiry is scheduled and only approved content-free audit remains. Full denominators/evidence rules are normative in `acceptance-criteria.md` and must be frozen before measurement.

## Security boundary

Risk is HIGH with CRITICAL-impact authorization, token, recovery and derived-data failure modes. Authorization precedes retrieval/model calls and is rechecked at answer/citation. Critical values never commit silently. Derived text, thumbnails, embeddings and metadata are sensitive service-held copies and follow access/deletion. Server processing is not E2EE. Health, dependents and emergency release need separate future gates.

## Stop logic

Stop or reposition if users prefer Drive + calendar; BYOS does not improve trust/purchase; Drive acceptance <30%; activation <50%; paid intent <10%; retention <25%; extraction <80%; support >20 minutes; permissions cannot be proven safe; or fully loaded economics fail. Stop outright if viability requires ads, broad scopes, misleading privacy or excluded sensitive functionality.

## Traceability

Factory definition artifacts: `research-brief.md`, `product-brief.md`, `build-vs-adopt.md`, `open-source-sufficiency-decision.md`, `feature-evidence-matrix.md`, `requirement-priority-research.md`, `phased-roadmap.md`, `acceptance-criteria.md`, and `approval-report.html` under `software-factory/runs/family-passport-2026-08-17/product-definition/`.
