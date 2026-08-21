# Open-source landscape — Family Passport / Family OS

LAST REVIEWED: 2026-08-17
RESEARCH OWNER: Software Factory open-source-assessor
SOURCES: Official repositories, licence files, documentation and release histories listed below
COUNTRIES CHECKED: Global/open-source; no country-specific restriction assumed
VERIFICATION STATUS: VERIFIED FACTS and evidence-backed analysis; dependency/legal diligence remains NEEDS RESEARCH

## Executive finding

**VERIFIED FACT:** The open-source ecosystem contains strong document-management, OCR, receipt, household-inventory and self-hosted-storage products, but none of the ten serious candidates assessed supplies the proposed combination of:

- files remaining across Google Drive/OneDrive/Dropbox;
- a family/entity relationship graph;
- confidence-gated structured extraction and reminders;
- dependent/private/emergency family access semantics; and
- permission-safe, source-cited AI retrieval.

**PROPOSAL:** Do not fork a complete DMS. If commercial discovery validates the customer problem, build an independently authored metadata/orchestration core and integrate mature commodity document-processing components. OCRmyPDF/Tesseract is the clearest immediate reuse candidate. Papermerge and Mayan warrant bounded component-level spikes because Apache-2.0 is commercially favourable. Paperless-ngx, Receipt Wrangler, Homebox, Teedy, Docspell and Grocy are valuable workflow/architecture references; their code should not be copied into a proprietary core without licence review.

## Top ten

| Project | Classification | Licence | Strongest relevance | Primary weakness for Family Passport | Decision |
|---|---|---|---|---|---|
| Paperless-ngx | ACTIVE | GPL-3.0 | Best personal DMS: OCR, ingestion, email, search, metadata, API | Own managed repository; no family graph/BYOS | Use as reference; possible isolated benchmarking |
| Docspell | MAINTAINED BUT SLOW | AGPL-3.0+ | Assisted filing from scanners/email; NLP metadata | AGPL plus Scala/Elm; no family model/BYOS | Architectural reference |
| Papermerge | ACTIVE | Apache-2.0 | OCR DMS, custom fields, OpenAPI, multi-user | Current maturity needs spike; repository-centric | Evaluate components |
| Mayan EDMS | ACTIVE | Apache-2.0 | Mature metadata, workflow, ACL, audit and REST | Enterprise-heavy, consumer/domain mismatch | Integrate patterns/services selectively |
| Teedy | MAINTAINED BUT SLOW | GPL-2.0 | Compact OCR DMS with email, API, Android and permissions | Slow stable cadence; legacy stack; no graph/BYOS | Reference only |
| Homebox | ACTIVE | AGPL-3.0 | Best household inventory, warranty and maintenance model | No OCR/intelligence; permission depth unclear | Asset-workflow reference |
| Receipt Wrangler | ACTIVE | AGPL-3.0 | OCR/AI receipt extraction, email, mobile, groups/RBAC | Receipt-only; managed images; copyleft | Capture/confirmation reference |
| Grocy | ACTIVE | MIT | Recurring household routines, assets, barcodes, API/PWA | Not document management; coarse privacy | Permissive pattern/component reference |
| Nextcloud Server | ACTIVE | AGPL-3.0+ | User-controlled storage, share/version APIs, WebDAV | Is a storage platform, not a provider-neutral intelligence layer | Future connector/reference |
| OCRmyPDF | ACTIVE | MPL-2.0 core | Production-grade searchable-PDF OCR pipeline | No classification, users or UI; transitive licences | Integrate as isolated worker |

Popularity signals checked 2026-08-17 included Paperless-ngx 41.6k stars, OCRmyPDF 33.7k, Nextcloud 35.5k, Grocy 9.1k, Homebox 6.2k, Papermerge 2.9k, Teedy 2.6k, Docspell 2.2k, Mayan’s GitLab 678, and Receipt Wrangler 258. **These values did not determine the ranking.** Release cadence, licence, maintainership, fit, permissions, extensibility and adaptation burden were weighted more heavily.

## Capability conclusion

| Product hypothesis | Open-source evidence | Conclusion |
|---|---|---|
| Automatic OCR/organisation is differentiating | Paperless-ngx, Docspell and Receipt Wrangler already automate parts of this. | **TABLE STAKES to IMPORTANT**, not unique alone. Accuracy, confirmation UX and family entity matching could differentiate. |
| Family relationship model is differentiating | No assessed project implements people/property/vehicle/pet relationships with family privacy semantics. | **POTENTIAL INNOVATION**, subject to user validation. |
| BYOS is differentiating | DMSs ingest originals; Nextcloud is itself storage. None is a neutral Drive/OneDrive/Dropbox metadata overlay. | **POTENTIAL DIFFERENTIATOR**, but technically complex and not proven commercially. |
| Asset inventory belongs in MVP | Homebox proves a mature niche; it is a different acquisition/engagement workflow. | **PROPOSAL:** later module unless interviews show insurance inventory is the wedge. |
| Bills/receipts can retain users | Receipt Wrangler and Grocy show recurring transaction/routine workflows. | **PROPOSAL:** test as Phase 2 engagement, not assume it belongs in the first trust-sensitive MVP. |
| Forking accelerates the core | Every complete system assumes a managed repository and lacks the family graph. | **REJECT FORK:** adaptation would replace the differentiating layers while inheriting licence/architecture debt. |

## Licence decision

- **LOWER FRICTION:** Apache-2.0 (Papermerge, Mayan), MIT (Grocy), MPL-2.0 core (OCRmyPDF, with file-level obligations and dependency review).
- **HIGHER FRICTION FOR PROPRIETARY SAAS/FORKS:** AGPL (Docspell, Homebox, Receipt Wrangler, Nextcloud) and GPL-distributed derivatives (Paperless-ngx, Teedy).
- **NEEDS RESEARCH:** exact-version SBOM, transitive dependencies, trademarks, model/data licences and whether any component boundary forms a derivative work. Specialist legal advice is required before adoption.

## Build versus reuse recommendation

**CONTINUE WITH GREENFIELD DOMAIN CORE + INTEGRATE OPEN-SOURCE COMPONENTS.**

Build only the product-specific layers: provider-neutral file references, family/entities/relationships, policy enforcement, confidence/confirmation state, reminder logic and permission-safe retrieval. Integrate commodity OCR/PDF/image/search components behind replaceable, sandboxed interfaces. Do not expose OCRmyPDF’s demonstration server; its documentation explicitly says it lacks security measures.

## Risks and unresolved questions

- **VERIFIED FACT:** Paperless-ngx warns that sensitive information is stored in clear text and recommends trusted self-hosting. A fork would not automatically satisfy Family Passport’s security requirements.
- **NEEDS RESEARCH:** field-level OCR/extraction precision on real NZ/AU insurance, rates, WOF, warranty and identity documents.
- **NEEDS RESEARCH:** Papermerge’s current production maturity and exact stable release/contributor breadth.
- **NEEDS RESEARCH:** security advisories, SBOMs and operational cost benchmarks for exact candidate versions.
- **ASSUMPTION:** hosted SaaS is the likely business model. On-prem/desktop distribution materially changes copyleft analysis.
- **PROPOSAL:** health and emergency access should not be used to justify a foundation choice before a dedicated security/privacy design.

## Sources checked 2026-08-17

- Paperless-ngx: https://github.com/paperless-ngx/paperless-ngx ; https://github.com/paperless-ngx/paperless-ngx/releases ; https://docs.paperless-ngx.com/api/
- Docspell: https://github.com/eikek/docspell ; https://github.com/docspell
- Papermerge: https://github.com/ciur/papermerge ; https://github.com/papermerge/papermerge-core ; https://docs.papermerge.io/
- Mayan EDMS: https://gitlab.com/mayan-edms/mayan-edms ; https://gitlab.com/mayan-edms/mayan-edms/blob/master/HISTORY.rst ; https://docs.mayan-edms.com/
- Teedy: https://github.com/sismics/docs
- Homebox: https://github.com/sysadminsmedia/homebox ; archived predecessor https://github.com/hay-kot/homebox
- Receipt Wrangler: https://github.com/Receipt-Wrangler ; https://github.com/Receipt-Wrangler/receipt-wrangler ; https://receiptwrangler.io/
- Grocy: https://github.com/grocy/grocy ; https://github.com/grocy/grocy/blob/master/LICENSE.md
- Nextcloud: https://github.com/nextcloud/server ; https://github.com/nextcloud/documentation/blob/master/user_manual/files/access_webdav.rst
- OCRmyPDF: https://github.com/ocrmypdf/OCRmyPDF ; https://github.com/ocrmypdf/OCRmyPDF/releases ; https://github.com/ocrmypdf/OCRmyPDF/blob/main/docs/introduction.md

Detailed scoring, feature statuses and legal risks are preserved in `software-factory/runs/family-passport-2026-08-17/open-source-assessment/`.

