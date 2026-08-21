# Family Passport inbound email and selective extraction

LAST REVIEWED: 2026-08-21  
RESEARCH OWNER: Product / Architecture  
SOURCES: User-directed product requirements; existing Family Passport privacy, OCR and architecture decisions  
COUNTRIES CHECKED: New Zealand initial product boundary  
VERIFICATION STATUS: APPROVED REQUIREMENT; INTERNET MAIL INFRASTRUCTURE AND IMPLEMENTATION NEEDS RESEARCH

## Product outcome

Each household receives a stable Family Passport inbox alias. Messages sent to that alias are treated as household records, not as authentication messages. The sign-in email and household inbox are separate concepts.

Example development alias: `family-<random-id>@family-passport.local`  
Example production shape: `<random-alias>@inbox.<approved-domain>`

The alias must be random, unique, rotatable, disableable and never used as proof of identity. Household owners/admins may copy it, rotate it and view ingestion status. Changing a family display name must not change the alias.

## Ingestion workflow

```text
Inbound email
→ spam/type/size/malware controls
→ exact household alias resolution
→ save original RFC822 email and allowed attachments
→ lightweight text and metadata extraction
→ local-AI classification and tag proposal
→ confidence and policy checks
→ user review when uncertain or critical
→ category/entity assignment
→ bill/subscription reminder proposal
→ searchable household record with source evidence
```

Both the original email and each accepted PDF attachment are retained with immutable source identifiers, hashes and ingestion timestamps. Derived text, tags, facts and reminders retain lineage to the email and attachment used.

## Organisation model

Default categories:

- Bills
- Subscriptions
- Travel
- Vehicles
- Home
- Insurance
- Purchases and warranties
- Household assets
- Legal
- Other / needs review

Users may add, rename and archive custom categories. System identifiers remain stable so renaming cannot change permissions or expose information.

Property-specific groupings are entity-filtered saved views rather than duplicated security categories:

- `Bills` + `Main house` → **Main house bills**
- `Bills` + `Rental 1` → **Rental 1 bills**
- `Vehicles` + `Toyota Corolla` → **Toyota records**

Tags are separate from categories and entities. Examples: `electricity`, `monthly`, `due-soon`, `air-new-zealand`, `receipt`, `insurance-renewal`, `tax-year-2027`.

## Selective OCR and extraction

The normal email path does not OCR every page.

Processing order:

1. Email envelope, sender, subject, body and attachment metadata.
2. Existing machine-readable PDF text when available.
3. First relevant page or bounded page sample only when categorisation or key-field extraction needs OCR.
4. Full-document OCR only after an explicit user request or a narrowly approved workflow that explains the additional processing.

Normal extracted proposals:

- category and related household entity;
- provider / merchant / bought from;
- document or transaction date;
- due date, renewal date or expiry date;
- amount and currency when supported;
- billing period and recurrence;
- account/policy/reference number with masking in summaries;
- concise tags;
- attachment type and source citation.

Confidence is advisory. Important dates, amounts, account/policy identifiers and entity matches are not silently committed when uncertain or conflicting. The UI shows the supporting email/attachment excerpt and allows confirm, correct, reject or leave unfiled.

## Bills and subscription reminders

When a bill or subscription contains adequate source evidence, propose:

- provider;
- amount and currency;
- due date;
- billing period;
- recurring frequency;
- related property/person/vehicle;
- reminder timing.

One-off bills create a due-date reminder. Recurring subscriptions create the next renewal/payment reminder and a recurrence rule only after confirmation. Duplicate messages, revised invoices and payment receipts must reconcile to the same obligation rather than creating duplicate reminders.

## Local AI boundary

Local AI proposes classification, entities, tags and key fields. It cannot grant permissions, choose a household from message content, execute email instructions or commit critical values outside the confirmation policy.

Email bodies and attachments are hostile input. Prompts must treat embedded instructions as data, use a fixed structured-output schema and fail closed on malformed, conflicting or low-confidence output. Permission and household resolution happen before the model call and are not model-controlled.

## Privacy and security requirements

- Adult households only for the initial scope.
- Exact alias resolution before content processing.
- Per-household isolation for originals, derived text, tags and reminders.
- Attachment allow-list, bounded size/page count, malware scanning and parser sandbox.
- No active HTML, remote-image loading, scripts or macros in previews.
- Sender authentication signals retained where available, but never treated as proof that extracted facts are correct.
- Original email/PDF deletion, export, audit and retention controls.
- No health inference or cloud-AI processing by default.
- No public inbound deployment until domain, MX, SPF/DKIM/DMARC handling, anti-spam/abuse controls, TLS, rate limits, bounce handling and operational monitoring are approved.

## Development boundary

The first executable slice may use Mailpit and `@family-passport.local` aliases with fictional messages and PDFs. This proves routing, storage, local-AI classification, selective extraction, category/entity/tag proposals and reminders. It is not evidence that real internet mail or sensitive family documents are safe.

## Acceptance criteria

1. Every household has exactly one active inbox alias and alias history supports rotation.
2. A message addressed to household A cannot be observed, classified or retrieved by household B.
3. Original email and allowed PDF attachments are retained with hashes and source lineage.
4. Default and custom categories coexist; category renaming does not alter authorization.
5. Main-house/rental views are category-plus-entity filters.
6. Local AI returns schema-valid classification/tags or abstains.
7. Routine categorisation does not perform full-document OCR.
8. Full OCR requires explicit user intent and is auditable.
9. Critical fields require confirmation according to confidence/conflict policy.
10. Confirmed bill/subscription dates create non-duplicate reminders.
11. Prompt-injection, cross-household, malicious attachment, duplicate-message and malformed-model-output tests fail closed.

