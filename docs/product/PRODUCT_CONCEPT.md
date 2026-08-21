# Family Passport / Family OS — Product Concept

LAST REVIEWED: 2026-08-17 (Pacific/Auckland)  
RESEARCH OWNER: Product Owner / Factory Orchestrator  
SOURCES: User-provided concept; external validation is recorded in the linked discovery documents  
COUNTRIES CHECKED: New Zealand, Australia, United Kingdom, United States, Canada, Singapore (research in progress)  
VERIFICATION STATUS: PROPOSAL — NOT VALIDATED

## Evidence labels

- **VERIFIED FACT** — supported by a cited current source.
- **ESTIMATE** — calculated or modelled from stated inputs; not observed market data.
- **ASSUMPTION** — currently unverified premise used to frame research.
- **PROPOSAL** — recommended product or design choice, subject to approval.
- **NEEDS RESEARCH** — material uncertainty that must be tested or sourced.

## Concept

**PROPOSAL:** Family Passport is an intelligent family information-management layer that helps a household organise, understand, retrieve, share, and act on important records while, where practical, leaving original files in storage selected by the family.

It is not proposed as a generic cloud-drive replacement. Candidate responsibilities are metadata, OCR and extraction, entity relationships, hybrid search, reminders and workflow, family permissions, and source-cited retrieval. Candidate original-file providers are Google Drive, OneDrive, and Dropbox, with S3-compatible or NAS support deferred until evidence justifies it.

## Core hypotheses to validate

1. **ASSUMPTION:** Fragmented family records create a sufficiently frequent and costly problem for a dedicated product.
2. **ASSUMPTION:** Automatic classification plus date/reminder extraction can deliver useful value in 10–15 minutes without extensive manual setup.
3. **ASSUMPTION:** A relationship model centred on people, homes, vehicles, providers, documents, assets, and events is more useful than folders for the target segment.
4. **ASSUMPTION:** Bring Your Own Storage (BYOS) creates a trust or control advantage that users understand and value.
5. **ASSUMPTION:** The operational complexity and partial privacy benefits of BYOS do not outweigh its commercial value.
6. **ASSUMPTION:** Recurring ingestion and reminders create monthly usefulness sufficient for a family subscription.
7. **ASSUMPTION:** Users will trust a new vendor with extracted metadata and delegated access to extremely sensitive records.

## Candidate target segment

**PROPOSAL:** Start research with digitally active, multi-adult owner-occupier households managing at least two of property, vehicles, dependants, insurance, travel, or elderly-parent responsibilities. This is a research segment, not a validated ideal customer profile.

## Candidate job to be done

**PROPOSAL:** “Help our household find the right important record and act before a deadline, without reorganising every file or surrendering ownership of originals.”

## Candidate product model

Family → people, properties, vehicles, pets, providers, documents, bills, assets, events, and reminders.

**PROPOSAL:** Use a relational domain model with explicit relationship tables and selective graph-style traversal/search. Do not assume a graph database is required; that is a technical choice evaluated separately.

## Safety principles

- **PROPOSAL:** No critical OCR or AI extraction is committed silently when confidence is uncertain.
- **PROPOSAL:** Every AI answer must be permission-filtered and cite the source family record.
- **PROPOSAL:** Least privilege, household isolation, revocation, recovery, and auditability are launch requirements.
- **PROPOSAL:** Health records, emergency/legacy access, mailbox-wide ingestion, and strong privacy claims remain excluded until evidence and security design support them.

## Discovery status

No build decision has been made. The authoritative recommendation will be recorded in `DECISIONS.md` and the factory commercial-discovery report after independent evidence review.

