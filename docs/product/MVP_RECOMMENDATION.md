# MVP recommendation — Family Passport

LAST REVIEWED: 2026-08-17

RESEARCH OWNER: Software Factory market-researcher

SOURCES: Market, competitor, open-source, technical and security discovery artifacts

COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore

VERIFICATION STATUS: PROPOSAL FOR VALIDATION; no build approval

## Verdict

**VALIDATE FIRST.** Do not build a broad Family OS. Run problem, trust, prototype and pricing tests, then consider a narrow NZ Google-Drive-first beta.

## Maximum seven MVP capabilities

1. Adult-only household with verified email/password or verified Google OIDC AAL1 sign-in, application-owned SHA-256 TOTP AAL2 for Owner/Admin and sensitive actions, safe sessions/recovery, and private/shared item policy. Email matching never auto-links identities; Google login and Drive consent remain separate. Passkeys are Phase 2.
2. Google Picker-selected Drive folder/files plus manual mobile photo/PDF capture.
3. OCR and classification for a bounded set: home/contents insurance, vehicle/WoF/rego, passports (dates only), purchase receipts/warranties.
4. People, one property and vehicles as relational entities; no native graph database required.
5. Confidence display and explicit confirmation before critical dates/numbers become authoritative.
6. Reminders and a monthly “records/actions due” digest.
7. Permission-filtered structured/hybrid search that opens or cites the exact source; generative answers only after ACL tests pass.

## Not in MVP

Gmail/Outlook OAuth; indiscriminate mailbox/full-drive indexing; OneDrive/Dropbox/NAS; bills/spend anomaly analytics; health/prescriptions; dependent accounts; bank/government portals; emergency/legacy release; wills/financial account extraction; household inventory beyond a small receipt/warranty test; cloud AI for full IDs or sealed records; autonomous filing/actions; ads; E2EE/zero-knowledge claims; native graph infrastructure.

## Validation sequence and thresholds

1. 25–40 target interviews: ≥60% describe a recent costly/stressful retrieval or missed-date incident; ≥40% already maintain an improvised system.
2. Trust concept test against hosted-vault and BYOS explanations: ≥50% willing to connect selected Drive files after seeing exact derived-data disclosures; investigate refusals.
3. Concierge/prototype with 15 households: ≥70% of all participating households achieve useful output within 15 minutes; among households that complete connector selection, target ≥80% seeing at least three correct suggestions. Require ≥85% critical-field accuracy after user correction/confirmation and zero silent critical commits.
4. Four-week workflow: ≥50% add/forward another document and ≥40% act on/find something without prompting.
5. Pricing: ≥20% choose NZ$120/year in a credible choice test or ≥10% place a refundable deposit.
6. 90-day pilot: ≥40% household retention and ≥30% monthly meaningful use; no cross-household permission finding.

Stop or pivot if Drive connection acceptance is <30%, 15-minute activation <50%, critical extraction precision <80%, paid intent <10%, 90-day retention <25%, support exceeds 20 minutes per activated family, or users consistently prefer Drive search/manual reminders. Stop outright if viability requires ads, broad mailbox access, misleading privacy claims or unsafe emergency/health access.

## Pre-build technical and safety gates

The customer-workflow threshold above is not the release-quality benchmark. Before a product build expands beyond a manually assisted prototype:

- run a consented, de-identified 500-document benchmark across priority classes and adverse image conditions;
- require ≥95% precision among high-confidence review suggestions, ≥90% correct entity association and median confirmation below 20 seconds;
- retain mandatory confirmation for every critical value regardless of benchmark performance;
- measure both conservative specialised-extraction cost and routed production cost, targeting steady-state document intelligence below US$0.50/family/month and reshaping or re-pricing above US$1.00; and
- complete the privacy impact assessment, legal review, authorization threat model and exact-version SBOM/licence/security review before public beta or dependency commitment.

These thresholds reconcile the market, commercial, architecture and security workstreams without treating estimates as observed product performance.

## What I would do with my own capital

Spend first on 30 interviews, a clickable prototype, a manually assisted 15-family concierge test, and a representative 500-document extraction/security benchmark. Build only enough after those gates to connect user-selected Drive files, confirm extracted renewal dates and retrieve the cited source. Expand only when families repeatedly add new records and pay. I would stop if BYOS is not a purchase/trust advantage, recurring capture does not happen, or the focused product cannot outperform “Drive folder + calendar reminder” strongly enough to earn NZ$120/year.

Sources checked 2026-08-17: `MARKET_RESEARCH.md`, `COMPETITORS.md`, `MONETISATION.md`, `OPEN_SOURCE_LANDSCAPE.md`, `TECHNICAL_FEASIBILITY.md`, `PRIVACY_SECURITY.md` and their cited primary sources.
