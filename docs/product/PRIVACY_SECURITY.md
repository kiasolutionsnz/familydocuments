# Privacy and Security Discovery Review

LAST REVIEWED: 2026-08-17  
RESEARCH OWNER: Software Factory security-reviewer  
SOURCES: Official regulator, platform and security-standard sources listed below  
COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore  
VERIFICATION STATUS: DISCOVERY REVIEW COMPLETE; legal applicability and production design remain to be independently reviewed

## Executive security verdict

**VERIFIED FACT:** The proposed service would process personal information even when original documents remain in user-owned storage. File identifiers, OCR text, extracted dates and identifiers, embeddings, entity relationships, previews, audit records and OAuth tokens are held or controlled by the service and can disclose substantially the same facts as the source document.

**PROPOSAL:** Classify the product as **HIGH inherent risk**, with **CRITICAL-impact data classes** (identity documents, authentication/recovery material, financial/legal records, child records, health information, emergency packages and OAuth refresh tokens). Proceed only as a narrow validation product with selected-file ingestion, adult users, explicit confirmation of critical extraction, and no emergency release or health module.

**PROPOSAL:** BYOS is a custody and portability advantage, not a claim of end-to-end privacy. Positioning may say “your originals stay in storage you choose” only when that is technically true and accompanied by a precise disclosure of what Family Passport copies, derives, retains and sends to processors.

## Evidence legend

- **VERIFIED FACT:** supported by a cited authoritative source or directly observable platform documentation.
- **ESTIMATE:** a quantitative or operational judgement requiring validation.
- **ASSUMPTION:** an unresolved premise used to bound discovery.
- **PROPOSAL:** a recommended product or security decision.
- **NEEDS RESEARCH:** requires legal, technical or user validation before commitment.

## Data classification and processing boundary

| Class | Examples | Inherent impact | MVP treatment |
|---|---|---:|---|
| Critical secrets/capabilities | OAuth refresh tokens, recovery factors, signing/encryption keys, emergency-release shares | Critical | Token vault/KMS-backed envelope encryption; never searchable; never in logs/analytics; tightly scoped service identity |
| Critical identity/special sensitivity | Passport and licence images/numbers, birth certificates, health records, biometric identifiers, wills, enduring powers, child records | Critical | Identity documents only as user-selected files with explicit warning; health and biometric processing excluded; redact logs/previews |
| High financial/legal | Bank, mortgage, tax, insurance policy, legal and estate metadata | High–critical | Opt-in categories; field-level protection; item-level access; no cloud-AI processing by default for defined sensitive classes |
| High relationship/location | Family graph, addresses, travel itinerary, vehicle/property ownership, emergency contacts | High | Treat graph edges and reminder titles as sensitive; minimize notifications and indexes |
| Moderate operational | Provider, warranty, appliance and maintenance metadata | Moderate–high when combined | Suitable first use cases; still family-isolated and encrypted |
| Derived data | OCR text, summaries, embeddings, classifications, confidence, thumbnails | Same as source | Apply source classification, permissions, retention and deletion; embeddings are not anonymised |

**VERIFIED FACT:** Under New Zealand’s Privacy Act 2020 principles, collection, purpose, retention, security, use, disclosure, access/correction and overseas disclosure remain relevant to personal information. Principle 12 requires comparable safeguards or appropriately informed authorisation for covered overseas disclosures; using an overseas processor as an agent that does not use the information for its own purposes may be treated differently, but still requires contractual and security diligence.

**PROPOSAL:** Maintain a processing inventory/data map before beta. Every derived object must carry `family_id`, source document ID, data classification, owner/data-subject references, provenance, confidence, retention state and permission policy version. No global cross-family corpus, search index or analytics payload may contain family content.

## Threat model and risk register

| Threat | Likelihood | Impact | Inherent rating | Minimum mitigation / decision |
|---|---:|---:|---:|---|
| Cross-family authorization failure / IDOR | Possible | Catastrophic | Critical | Deny-by-default server-side policy enforcement; family and item predicates on every request/query; negative authorization tests; independent review |
| Compromised adult/admin account | Likely over lifetime | Catastrophic | Critical | Strong/leaked-password controls, mandatory TOTP AAL2 for Owner/Admin/sensitive actions, session/device management, action-bound step-up, anomaly alerts, rapid online revocation; no admin omniscience by default |
| OAuth refresh-token theft | Possible | Catastrophic | Critical | Envelope encryption with separate key authority, scoped workload identity, no plaintext logs/backups, rotation/revocation, token-use monitoring |
| Incorrect sharing or family-role escalation | Possible | Major–catastrophic | Critical | Explicit invitation/acceptance; least privilege; item/category policies; preview before grant; re-auth; immutable security audit trail |
| Emergency-access abuse or coercion | Possible | Catastrophic | Critical | Not MVP; later multi-party approval, waiting period, out-of-band alerts, revocation, restricted package, step-up and tamper-evident audit |
| OCR/LLM extracts wrong expiry, person or policy | Likely | Major | High | Confidence per field, visible source region, user confirmation for consequential fields, reversible edits, never silently commit critical values |
| Cloud AI/provider retention or training | Possible | Major–catastrophic | High | Contracted enterprise/API terms, no training, bounded retention, region/transfer review, provider allow-list, redaction and sensitive-class opt-out |
| Malicious PDF/image or prompt injection | Possible | Major | High | Quarantine, file-type/size checks, malware scanning, sandboxed rendering/parsing, strip active content, treat document text as untrusted data, tool-less extraction |
| Search/embedding side channel | Possible | Major | High | Family- and principal-scoped retrieval before model invocation; permission-filter every candidate and citation; separate indexes or enforced tenant filters; leakage tests |
| Deleted/revoked provider file remains in cache/index | Likely | Major | High | Change/revocation reconciliation, tombstones, expiry of caches, visible stale state, derived-data deletion policy and user controls |
| Account recovery bypasses strong authentication | Possible | Catastrophic | Critical | Frozen D-025 v2 parameters; verified external SMTP/provider acceptance to a pre-existing destination before exactly 72-hour cooling-off; all-notices-fail terminal/non-completable; no-access replacement staging; all-or-nothing credential/session/code/epoch rotation; deterministic races/fault injection; no support/email/SMS override |
| Sensitive content in logs, notifications or analytics | Likely without design | Major | High | Structured allow-listed telemetry; content-free push/email; log scrubbing; short retention; production access controls |
| Provider outage/moved file breaks access | Likely | Moderate | Medium | Explicit availability model, retry/reconcile, cached metadata status; do not imply possession/backup of originals |
| Insider/vendor access | Possible | Major–catastrophic | High | Just-in-time audited access, dual control for exceptional access, no routine content visibility, contractual processor controls |
| Family separation, abuse or coercive control | Possible | Catastrophic | Critical | Private-by-default person records, safe exit/revocation, no silent admin access, avoid exposing location/travel; specialist safeguarding research |

**PROPOSAL:** A Critical finding blocks release; High requires documented mitigation and independent acceptance; Medium requires an owner and due date; Low may be accepted by the designated risk owner. Authentication, authorization, emergency access, child records and data export/deletion are human-approval-gated under Software Factory policy.

## Family authorization model

**PROPOSAL:** Use relationship-aware authorization implemented as centrally enforced policy (RBAC for coarse role plus ABAC/ReBAC for family, person, category, item, ownership, confidentiality and time-bound grants). Storage-provider ACLs do not replace Family Passport authorization, and Family Passport access must never grant more source-file capability than the connector principal has.

Recommended semantics:

- **Owner:** household administration, billing and membership; does not automatically see another adult’s private records.
- **Family admin:** membership and shared-category administration; cannot override private or sealed items.
- **Adult member:** manages own private records and explicitly shared household items.
- **Contributor:** adds to named entities/categories but receives no implicit read access to unrelated records.
- **Viewer:** read-only to an explicit set; cannot export/share unless separately granted.
- **Dependent:** **not an autonomous MVP login**. A guardian may manage a dependent profile; later access requires age, consent and country-specific design.
- **Emergency contact:** no standing vault access; later receives only a predeclared package after the release protocol.

Required policy invariants:

1. Membership is not content entitlement.
2. New members receive zero content until explicit grants/default shared-household policies are applied.
3. Person-private items stay private to that adult unless explicitly shared.
4. Category grants cannot override item-level deny/sealed status.
5. Search, suggestions, counts, filenames, thumbnails, reminders, audit views and AI citations enforce the same policy as document retrieval.
6. Removing a member revokes sessions, grants, shared links and cached/offline access; the audit trail remains according to policy without retaining content unnecessarily.
7. Export, bulk download, emergency-package change, role elevation, connector addition and recovery require recent authentication and out-of-band notification.

**NEEDS RESEARCH:** Legal authority and consent for one adult to upload another adult’s, elderly parent’s or child’s information varies with circumstance. Product terms cannot manufacture authority. Validate guardianship, agency, joint ownership, family separation and deceased-person scenarios per launch market.

## Authentication, sessions and recovery

**VERIFIED FACT:** NIST SP 800-63B-4 recognises cryptographic authentication such as WebAuthn as phishing-resistant; manually entered OTPs are not phishing-resistant.

**D-025 + D-042 DECISION:** For MVP, verified email/password or verified Google OIDC may establish AAL1. Google identities bind issuer+subject; email collision never auto-links, explicit linking requires recent password+TOTP step-up, and the last primary cannot be unlinked. Google login is separate from Google Drive consent. Application-owned SHA-256 TOTP remains mandatory for Owner/Admin and every sensitive action; a Google-only account cannot exercise those privileges until a local password and product TOTP are securely enrolled. Magic links remain invite/verify/reset initiation only and never satisfy AAL2. Existing session, recovery, rate and notification controls remain required; passkeys are Phase 2.

Do not use security questions, family members’ knowledge, support-agent discretionary resets, email-only recovery for a vault owner, or SMS as the sole high-assurance method. Recovery should preserve availability without creating a master bypass. **NEEDS RESEARCH:** Define recovery assurance and customer-support process through abuse-case testing before beta.

## OAuth and BYOS connector controls

**VERIFIED FACT:** Google requires the least-privileged scopes. Its current Drive guidance recommends the non-sensitive `drive.file` scope with Google Picker for files the user selects; broad `drive.readonly` and metadata scopes are restricted. Storing or transmitting restricted-scope data server-side can trigger restricted-scope verification and an annual approved security assessment. Google’s OAuth policy also requires production verification for sensitive/restricted scopes.

**VERIFIED FACT:** Microsoft Graph’s delegated `Files.Read` allows reading the signed-in user’s files (including shared files for personal accounts); `Files.Read.All` is broader. `Files.Read.Selected` is preview-only, for work/school accounts and not for direct Graph API use. `Mail.Read` includes mailbox content, while `Mail.ReadBasic` excludes bodies and attachments.

**PROPOSAL — MVP:** Google Drive first, user-selected files/folders only where supported by the narrowest production scope; request scopes just in time. Avoid write permission unless an explicit feature requires it. Store provider/account, file ID, version/hash, classification and derived data; expose disconnected, deleted, moved, changed and stale states. Provide connector-level pause, rescan and delete-derived-data controls.

**PROPOSAL:** Separate OAuth clients and token stores by environment/platform; validate redirect URIs/state/PKCE; encrypt refresh tokens under per-environment keys; prevent tokens entering client telemetry; revoke locally and at the provider on disconnect where supported. A household member’s connector is personal—other members consume only explicitly shared derived/items, never inherit the connector token.

## Email ingestion

**PROPOSAL:** Do **not** request mailbox-wide Gmail or Outlook access in MVP. Google restricted-scope verification/security-assessment overhead and the blast radius of `Mail.Read` are disproportionate to validation needs.

Safest progression:

1. Dedicated forwarding address with per-family unguessable routing alias, sender verification, malware quarantine, rate/size limits and explicit retention.
2. User-selected attachment upload/share sheet.
3. Later, explicit label/folder or sender-rule ingestion only if provider APIs permit genuinely narrow access and user research demonstrates value.
4. Mailbox-wide search only after separate privacy impact assessment, OAuth verification plan, threat model and willingness-to-pay evidence.

Attachment-only processing is not harmless: message headers, sender, subject and attachment can reveal health, finance, travel or legal matters. Never send extracted email content to advertising or general analytics systems.

## OCR, document AI and assistant safety

**PROPOSAL:** Use a staged pipeline: file validation/quarantine → local/native text extraction where possible → OCR → bounded schema extraction → confidence/provenance → user review → commit. The model must have no autonomous external actions. Documents and emails are untrusted input and can contain prompt injection.

Critical-field rules:

- Record per-field confidence, extractor/model/version and exact source page/region/text span.
- Low-confidence results remain suggestions. Policy numbers, identity numbers, amounts, due/expiry dates, people/entity matching and reminders with material consequences require confirmation at launch.
- Never let an LLM decide authorization. Apply permission filtering before retrieval and again before rendering answers/citations.
- Answer from structured data plus permitted source passages; label uncertainty and show citations. “No result” must not reveal the existence of a restricted item.
- Do not use family content for model training, evaluation or prompt logging without separate, granular, revocable opt-in; synthetic/redacted datasets should be default.
- Maintain deletion propagation through OCR text, thumbnails, embeddings, caches, evaluation sets and provider stores.

**PROPOSAL:** Default cloud-AI deny list for health, biometric identifiers, authentication secrets, full identity-document images, child-sensitive records and sealed legal/financial items until a separately approved processor, legal basis, regional transfer and user-consent design exists. Local/device OCR can reduce disclosure but does not remove application-layer security and accuracy obligations.

## Encryption and E2EE verdict

**VERIFIED FACT:** TLS and encryption at rest protect transport and storage media, but server-side services that decrypt for OCR/search/AI can still access plaintext. Therefore this is not end-to-end encryption in the ordinary user-understood sense.

**PROPOSAL:** Baseline architecture should use TLS, managed KMS/HSM-backed envelope encryption, separate keys by environment, key rotation, field-level encryption for tokens and critical identifiers, encrypted backups, and platform secure storage for mobile caches. Search indexes, embeddings and backups inherit the source’s sensitivity.

**E2EE feasibility assessment:**

| Model | Benefit | Functional cost | Verdict |
|---|---|---|---|
| Full client-side E2EE, server blind | Strongest provider-blind confidentiality | Cross-device key recovery, server OCR/classification, email automation, web previews, global search, notifications and server AI become unavailable or require client execution/complex cryptography | Technically possible but incompatible with the proposed automation-first MVP |
| Server-side envelope encryption | Practical OCR/search/sharing and operational recovery | Service compromise/insider with runtime access can expose plaintext | Recommended MVP baseline; do not market as E2EE |
| Hybrid sealed categories/client-side encryption | Allows highly sensitive items to remain provider-blind while normal items are automated | Two modes, confusing recovery/search limitations, more client complexity | **NEEDS RESEARCH** after validating demand; promising for “sealed vault” later |

**PROPOSAL:** Do not claim “zero knowledge” or E2EE unless keys and every relevant plaintext transformation remain exclusively at authorised endpoints. Publish a plain-language data-flow table explaining originals, temporary processing copies, OCR text, metadata, embeddings, backups and subprocessors.

## Emergency and legacy access

**PROPOSAL:** Exclude from MVP. A later design should release a user-curated, minimal package—not the whole family vault—and require:

- trusted contact acceptance and verified contact channels;
- configurable waiting period with repeated out-of-band notice to the owner;
- owner revocation at any point before release;
- step-up authentication for requester and approver;
- optional two-of-n approvals for highest-risk packages;
- immutable/tamper-evident event audit and post-release notice;
- package expiry, download controls and re-confirmation at annual review;
- clear incapacity/death limits and no claim that the mechanism proves legal authority.

Threat-test coercion, SIM/email takeover, compromised trusted contacts, family disputes, owner lockout, malicious support requests and notification suppression. **NEEDS RESEARCH:** independent cryptographic/security design and market-specific legal review before recommendation.

## Health and child-data recommendation

**VERIFIED FACT:** UK regulator guidance treats health data and inferred health information as special-category data requiring an Article 6 lawful basis plus an Article 9 condition, minimisation and potentially stronger safeguards. New Zealand has a Health Information Privacy Code; whether it applies depends on the service’s role and facts and requires legal review. US COPPA applies to child-directed services and services with actual knowledge of collection from children under 13, including parental-consent requirements.

**PROPOSAL:** No health-record category, health inference, prescription extraction, clinical assistant, dependent login or direct collection from children in MVP. Permit only user-controlled generic file storage linkage if sensitive classes can be marked “do not process,” with thumbnails/OCR/AI off. Do not infer health from filenames, provider names or embeddings.

## Privacy lifecycle and regulatory posture

**PROPOSAL:** Before private beta:

- appoint a privacy owner; complete a privacy impact assessment and records of processing;
- establish data-controller/processor roles and subprocessor contracts; review NZ IPP 12 and each launch market’s transfer rules;
- issue layered notices at collection, connector consent, family sharing, AI processing and forwarding;
- support access, correction, export, account/family deletion, connector revocation and retention controls;
- define short retention for temporary originals and failed uploads; document backup deletion windows;
- implement incident response, breach assessment/notification playbooks and processor notification SLAs;
- prohibit content-based advertising, sale of data, AI training and sensitive-category analytics;
- conduct threat modelling, secure-design review, dependency/SBOM scanning, penetration testing and an OWASP ASVS-aligned verification before public launch.

**VERIFIED FACT:** Australia’s APPs address transparency, collection, use/disclosure, quality, security, access/correction and cross-border disclosure. Canada’s PIPEDA principles include accountability, consent, limiting collection/use/retention, accuracy, safeguards and access. Singapore’s PDPA includes purpose, accuracy, protection, retention, transfer, access/correction and breach-notification obligations. These converge on minimisation, transparency, security, retention and accountable vendors, but jurisdiction-specific counsel remains necessary.

**NEEDS RESEARCH:** US privacy obligations are state- and data-specific beyond COPPA; evaluate launch states, biometric/health/consumer-health laws and breach requirements before US launch. For Australia, confirm whether current small-business exemptions apply at launch and whether handling health information changes coverage. Confirm UK representative/DPO/DPIA obligations, Canadian provincial laws and Quebec requirements, and Singapore DPO/transfer arrangements.

## Secure MVP boundary

Include no more than:

1. Adult-only family accounts with email/password or verified Google OIDC AAL1 plus application-owned password + SHA-256 TOTP AAL2 for privileged actions, device/session controls, fail-closed recovery and safe invitations; passkeys deferred.
2. Google Drive Picker / `drive.file` selected-file access; manual mobile upload/photo.
3. Sandboxed OCR and bounded extraction for low-to-high (not excluded critical) document classes.
4. People/property/vehicle entities with private/shared item policies.
5. Confirm-before-commit expiry/reminder extraction.
6. Permission-filtered structured search and sourced retrieval; delay generative answers if controls are not proven.
7. Audit, revocation, export and deletion controls available from first beta.

**NOT IN MVP:** Gmail/Outlook mailbox API access; full-drive indexing; health records/inference; dependent accounts; emergency/legacy release; bank/government portal connections; full identity-document extraction; automated consequential actions; content-based advertising; third-party model training; cross-family learning from private content; broad OneDrive/Dropbox/NAS connectors; “zero knowledge” claims.

## Security go/no-go conditions

**PROPOSAL — VALIDATE:** Security does not support a broad Family OS build. It supports a narrow validation only if the following preconditions are funded and owned:

- demonstrate deny-by-default family/item authorization with cross-tenant negative tests;
- prove OAuth least privilege and token revocation/deletion lifecycle;
- measure extraction accuracy with field confidence and human-confirmation UX;
- publish and user-test an honest BYOS/data-processing explanation;
- validate that families will pay without health, emergency access or mailbox-wide ingestion;
- commission independent privacy/legal review and security test before public availability.

Stop the project or redesign if commercial viability depends on ads against sensitive context, broad mailbox/file scopes without strong willingness-to-pay, silent automated filing of critical data, routine cloud-AI processing of excluded categories, owner/admin omniscience, support-based account bypass, or misleading E2EE/BYOS privacy claims.

## Sources

All sources checked 2026-08-17.

1. New Zealand Office of the Privacy Commissioner, Privacy Act 2020 principles: https://www.privacy.org.nz/privacy-principles/
2. NZ OPC, Principle 12 — Disclosure outside New Zealand: https://www.privacy.org.nz/privacy-principles/12/
3. NZ OPC, Principle 12 decision tree (processor/agent distinction and safeguards): https://www.privacy.org.nz/responsibilities/disclosing-personal-information-outside-new-zealand/decision-tree-page/
4. NZ OPC, Health Information Privacy Code 2020: https://www.privacy.org.nz/privacy-principles/codes-of-practice/hipc2020/
5. Google, OAuth 2.0 policies: https://developers.google.com/identity/protocols/oauth2/policies
6. Google, Restricted-scope verification: https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
7. Google, Workspace API User Data and Developer Policy: https://developers.google.com/workspace/workspace-api-user-data-developer-policy
8. Google, Choose Drive API scopes: https://developers.google.com/workspace/drive/api/guides/api-specific-auth
9. Microsoft, Graph permissions reference: https://learn.microsoft.com/en-us/graph/permissions-reference
10. NIST SP 800-63B-4, Authentication and Authenticator Management: https://pages.nist.gov/800-63-4/sp800-63b.html
11. OWASP, Application Security Verification Standard: https://owasp.org/www-project-application-security-verification-standard/
12. Australian OAIC, Australian Privacy Principles guidelines: https://www.oaic.gov.au/privacy/australian-privacy-principles/australian-privacy-principles-guidelines
13. UK ICO, special-category data rules: https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/lawful-basis/special-category-data/what-are-the-rules-on-special-category-data/
14. UK ICO, what is health/special-category data: https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/lawful-basis/special-category-data/what-is-special-category-data/
15. Canada OPC, PIPEDA: https://www.priv.gc.ca/en/privacy-topics/privacy-laws-in-canada/the-personal-information-protection-and-electronic-documents-act-pipeda/
16. Singapore PDPC, data-protection obligations: https://www.pdpc.gov.sg/overview-of-pdpa/the-legislation/personal-data-protection-act/data-protection-obligations
17. US FTC, COPPA Rule: https://www.ftc.gov/legal-library/browse/rules/childrens-online-privacy-protection-rule-coppa

## Disclaimer

This is product-discovery and security guidance, not legal advice. Applicable law depends on entity, processing role, users, location, contracts and product behaviour and must be reviewed by qualified counsel before launch.
