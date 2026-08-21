# CEO Brief — Household Records Assistant (working concept)

LAST REVIEWED: 2026-08-17 (Pacific/Auckland)  
RESEARCH OWNER: Factory Orchestrator; independently reviewed by Commercial Analyst  
SOURCES: Full factory run at `software-factory/runs/family-passport-2026-08-17/`; primary URLs are recorded in the source registers and product research documents  
COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore; Ireland screened  
VERIFICATION STATUS: INDEPENDENT GATE = VALIDATE; SUBSTANTIAL IMPLEMENTATION BLOCKED

## Executive recommendation

**VALIDATE — do not build a broad Family OS.** Trustworthy already offers much of the proposed ingestion, AI classification, structured extraction, entity linking, reminders, confirmation and family-sharing workflow. Prisidio also organizes records around relationships. The broad concept is therefore neither greenfield nor strongly differentiated.

Test one narrower promise: **selected household records remain in Google Drive while the service creates confirmed home/vehicle renewal dates and source-cited retrieval without forcing a vault migration.** BYOS is technically feasible and visibly different, but whether it increases trust, activation or willingness to pay is **NEEDS RESEARCH**.

## Decision summary

| Question | Decision |
|---|---|
| Problem worth solving | Find household proof/policies quickly and prevent costly missed renewals without reorganising or migrating every original. |
| Strongest customer | **ASSUMPTION:** NZ adult household administrator, 35–60, property and vehicle responsibilities, existing Google Drive use. |
| Killer use case | Select 10–30 files; within 15 minutes confirm upcoming insurance/WoF/rego/passport/warranty dates and retrieve the exact source. |
| Positioning | Test “Household Records Assistant.” Avoid “Family OS” (occupied) and do not lead with “Family Passport” (over-signals identity/travel). |
| Market | Overall **CROWDED**; exact selected-file BYOS + confirmed renewals + citations intersection **UNDERSERVED**, demand unproved. |
| Strongest commercial rivals | Trustworthy, Everplans, Prisidio; HomeZada and Itemtopia for modules; Google Drive/OneDrive/1Password as DIY substitutes. |
| Strongest open source | Paperless-ngx (reference), OCRmyPDF/Tesseract (component), Mayan/Papermerge (permissive candidates), Receipt Wrangler/Homebox (workflow references). |
| Build/reuse | No full DMS fork. If Phase 0 passes, independently author the metadata/permissions/provenance core and integrate replaceable commodity components after licence/security review. |
| BYOS verdict | **HYBRID GOOGLE-DRIVE-FIRST VALIDATION.** Originals remain selected in Drive; encrypted derived metadata/OCR/index still lives with the service. This is not E2EE or zero knowledge. |
| Launch geography | New Zealand validation; Australia first commercial follow-on; other English-speaking markets later. NZ is a wedge, not a moat. |
| Business model | Limited free value demonstration plus Family subscription. Test NZ$120–150/year. No Plus tier until usage/cost evidence exists. |
| Advertising | **NO ADS.** Low frequency limits inventory; sensitive-context advertising undermines trust. |
| Commercial viability | Market synthesis 2.7/5; independent challenger 2.36/5. Classification: **VALIDATE FIRST**. |

## Recommended MVP only after Phase 0 passes

1. Adult-only household with strong authentication and private/shared item policy.
2. Google Picker-selected Drive files plus manual photo/PDF capture.
3. Bounded OCR/classification for home insurance/rates, vehicle/WoF/rego, passport expiry metadata and receipts/warranties.
4. People, one property and vehicles in a relational typed-edge model.
5. Field confidence, provenance and mandatory confirmation for critical facts.
6. Reminders and monthly action digest.
7. Permission-filtered retrieval with exact document citations.

## What not to build yet

Mailbox OAuth, full-drive indexing, OneDrive/Dropbox/NAS parity, broad bill analytics, complete asset inventory, health, dependent logins, emergency/legacy release, financial/government portals, autonomous critical actions, native graph infrastructure, content advertising, family-data model training, or E2EE/zero-knowledge claims.

## Technical and security verdict

Technically feasible, but not cheap or simple. A relational core with typed relationships is sufficient; a graph database is unnecessary initially. Conservative all-page custom extraction could cost roughly US$3–4.60 per active family/month, while intelligent routing should target below US$0.50 steady state; onboarding backfill needs caps because a 500 two-page document backfill can approach US$35.75 under the conservative model.

Security is **HIGH inherent risk** with **CRITICAL-impact** failure modes: cross-family permission leaks, compromised adult/admin accounts, OAuth token theft, recovery bypass, and sensitive derived-data exposure. Health, emergency access, dependents and mailbox-wide ingestion each require separate later gates. Critical extractions must never be silently committed.

## What creates monthly return

One-step capture of new documents; renewal/WoF/registration/warranty events; a useful monthly action digest; property/vehicle service events; and fast retrieval during real life-admin tasks. If households organize once, add no new records and do not return for a real event, the subscription thesis fails.

## Phase 0 validation contract

- 25–40 target interviews: at least 60% report a recent stressful/costly retrieval or missed-date incident; at least 40% use an improvised system.
- At least 50% will connect selected Drive files after an honest derived-data disclosure; stop the BYOS thesis below 30%.
- At least 20% make a credible NZ$120/year choice or at least 10% place a refundable deposit; stop below 10% paid intent.
- Manually assisted 15-household workflow: at least 70% of all enrolled households reach useful value within 15 minutes; at least 80% of connector completers see three correct suggestions.
- Representative 500-document benchmark: at least 95% precision among high-confidence suggestions, 90% correct entity association, median confirmation under 20 seconds, at least 85% end-to-end confirmed critical-field accuracy, and zero silent critical commits.
- Pilot: at least 40% meaningful 90-day retention, at least 30% monthly meaningful use, zero cross-household permission findings, support under 20 minutes per activated family, measured steady-state intelligence cost below US$0.50 target (reshape/re-price above US$1).

## Biggest reasons to stop

Stop or reposition if users prefer Drive plus calendar reminders; BYOS does not improve trust or purchase intent; selected-Drive acceptance is below 30%; activation below 50%; paid intent below 10%; 90-day retention below 25%; critical-field precision remains below 80%; support or compliance destroys margin; or safe permissions cannot be demonstrated. Stop outright if viability depends on ads, broad mailbox/file scopes, misleading privacy claims, or unsafe health/emergency/dependent functionality.

## Capital-allocation answer

If this were my own capital and engineering capacity, I would buy evidence first: 30 interviews, a clickable prototype, a manually assisted 15-family test, a 500-document benchmark, and privacy/authorization review. I would build only selected Drive ingestion, confirmation-gated renewal extraction, reminders and cited retrieval after those gates pass. I would validate repeated capture and NZ$120/year payment before a second connector or any broad module. I would stop when BYOS fails to improve trust/conversion, users do not return for real events, or safe unit economics and permissions cannot be proven.

## Gate outcome

**VALIDATE.** The next permissible step is a bounded Phase 0 validation programme. This document does not authorize implementation, external recruitment, purchases, account creation, licence commitments or production changes.

