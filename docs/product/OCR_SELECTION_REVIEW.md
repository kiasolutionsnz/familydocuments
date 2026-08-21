# OCR and Document-Intelligence Selection Review

LAST REVIEWED: 2026-08-18 (Pacific/Auckland)  
RESEARCH OWNER: Factory Orchestrator with Open-Source Assessor, Solution Architect and Security Reviewer  
SOURCES: Current official repositories, licences, releases, vendor documentation, pricing and privacy sources recorded under `software-factory/runs/family-passport-ocr-2026-08-18/`  
COUNTRIES CHECKED: New Zealand and Australia; global open-source/service availability  
VERIFICATION STATUS: PROVISIONAL SHORTLIST COMPLETE; REPRESENTATIVE BENCHMARK REQUIRED

Evidence labels: **VERIFIED FACT**, **ESTIMATE**, **ASSUMPTION**, **PROPOSAL**, and **NEEDS RESEARCH** retain their meanings from the main discovery pack.

## Decision

**PROPOSAL:** Select an engine-neutral routed pipeline after a controlled 500-document/1,000-page benchmark. Do not select a universal OCR engine or begin application implementation from vendor claims.

Provisional route:

1. Preserve and quality-check native PDF text.
2. Use Apple Vision/VisionKit and Android ML Kit for scanning, image-quality guidance and privacy-preserving first-pass text.
3. Use OCRmyPDF + Tesseract as the deterministic local baseline.
4. Benchmark PaddleOCR and RapidOCR as local challengers.
5. Benchmark Google Document AI Enterprise OCR in Sydney as lead cloud fallback; Azure Australia East and AWS Textract Sydney are challengers.
6. Use Docling only where layout/table reconstruction adds measured value.
7. Test a bounded difficult-page/VLM fallback only if it materially improves eligible pages; it must never be the uncorroborated source of a critical fact.
8. Attach confidence and exact provenance to field candidates and require human confirmation for critical fields.

**Status:** GO to benchmark; NO-GO to production engine selection.

## Candidate matrix

| Candidate | Benchmark role | Main advantage | Main concern |
|---|---|---|---|
| Native PDF extraction | Default first lane | Highest fidelity/cost efficiency when text is trustworthy | Corrupt text, reading order and tables need checks |
| OCRmyPDF + Tesseract 5.5.x | Local baseline | Mature, CPU-friendly searchable-PDF pipeline | Poor photos/layout may favour neural engines |
| PaddleOCR | Local challenger | Broad, active modern OCR/layout ecosystem | Freeze exact model/runtime; operational complexity |
| RapidOCR ONNX | Lightweight local challenger | Potentially simpler CPU deployment | Target accuracy and provenance unverified |
| Docling | Selective layout layer | PDF-aware layout/tables, multiple OCR backends | Heavier and unnecessary for simple pages |
| Google Document AI OCR | Lead cloud fallback | Sydney region, USD1.50/1,000 raw OCR pages, no-training statement | Content leaves Drive temporarily; quotas/configuration |
| Azure Document Intelligence | Cloud challenger | Australia East, broad Read/Layout support, deletion API | Australian numeric S0 price not captured |
| AWS Textract | Cloud challenger | Sydney; OCR/forms/tables/queries/expense | Enforced AI-services opt-out and result deletion required |
| Apple Vision/VisionKit | iOS capture | On-device privacy and capture correction | Device/OS variance; not full backend parser |
| Android ML Kit | Android capture | On-device scanner cleanup/offline OCR | Device/model variance; not semantic parser |
| olmOCR | Small difficult-page cohort | Potential VLM improvement | GPU, hallucination and provenance risk |

Secondary only: docTR and EasyOCR. Surya model-weight thresholds and MinerU's custom licence introduce material risks. ABBYY is technically serious but has opaque pricing/retention friction. Mindee, Veryfi and Nanonets are ineligible until authoritative location, retention, training, deletion and price evidence is available. No licence commitment is approved.

## Cost findings

**ASSUMPTION:** 10 new two-page documents/family/month; 60% need OCR; 20% need structured extraction. These are service-price illustrations, not the fully loaded cost verdict.

| Strategy | Estimated service cost/family/month |
|---|---:|
| Google/AWS-reference raw OCR | ~USD0.018 |
| Selective Google OCR + generic structured extraction | ~USD0.138 |
| Google OCR + two receipt/invoice parsers | ~USD0.218 |
| All 20 pages through Google Form Parser | ~USD0.60 — reject before other costs |
| 100 pages/month through Form Parser | ~USD3.00 — incompatible with target pricing |

Select on **cost per correctly confirmed critical field**, not price per page. Initial backfill must be capped and progressively indexed. Azure Australia pricing and exact AWS Sydney pricing remain **NEEDS RESEARCH**. **Current fully loaded cost verdict: INCONCLUSIVE** until the benchmark measures regional service price, local compute, retries, review labour, storage/egress and support burden. The gate remains below USD0.50/family/month under the base workload and below USD1 under the declared high workload.

## Benchmark corpus and metrics

Use 500 documents and at least 1,000 pages with a 20% development / 80% blind split, grouped by source/template. Six launch classes receive at least 50 documents each; secondary safety strata cover handwriting, malformed/adversarial inputs and out-of-scope material. Include born-digital and scanned insurance, council/property notices, vehicle WoF/registration/service records, synthetic identity specimens (expiry only), receipts/warranties and adverse phone captures.

The 99% precision claim requires at least 300 high-confidence critical-field predictions across at least 150 source documents plus per-class minima and an a-priori clustered power simulation. Results that cannot support the required confidence bound are **INCONCLUSIVE**, not passing. Device capture quality is a separate controlled experiment from byte-identical backend inference. Human confirmation uses a frozen 12-reviewer Latin-square protocol. Score both the deployable router and an oracle router so routing failure cannot be hidden by component accuracy.

Measure CER/WER, layout/reading order, classification macro F1, exact/normalized critical-field precision/recall/F1, provenance correctness, entity association, calibration, abstention, confirmation time, latency, failures, resources and cost.

## Hard gates

- Privacy/security protocol passes; uncontrolled personal-data upload, prohibited training/retention or missing deletion assurance is an automatic veto.
- High-confidence critical-field precision ≥99%, with clustered 95% CI lower bound ≥97%.
- Critical-field false-accept rate ≤1%; zero silent critical commits.
- High-confidence critical-field recall ≥80%.
- Overall critical-field F1 ≥90%; each launch class ≥85%; poor-capture stratum ≥75%.
- Classification macro F1 ≥90%; out-of-scope precision ≥95%.
- Entity association ≥90%, with abstention on ambiguity.
- Correct provenance for ≥99% of suggested critical fields.
- Median confirmation ≤20 seconds; p90 ≤45 seconds.
- Supported-file failure ≤1%; adverse supported files ≤3%.
- Weighted steady-state document intelligence ≤USD0.50/active family/month; redesign above USD1.
- Interactive p95 ≤15 seconds/page or a clearly communicated asynchronous workflow.

After eliminating hard failures, score safety/accuracy 35%, privacy/security 25%, confirmation burden 15%, reliability/latency 10%, cost 10%, and deployment/licence/operations 5%. Prefer the simplest local/routed configuration within two points of the best eligible critical-field F1 without a material safety deficit.

## Privacy controls

Use synthetic documents first. Real documents require separate consent, minimisation and de-identification approval; identity tests remain synthetic. Freeze vendor/region/data-use configuration before upload. Do not use globally routed generative extractors under a residency promise. AWS requires organisation-level AI-services opt-out; Azure results require deletion before default retention expires. Record engine/model/version, input hash, page/box, preprocessing, confidence, region and time. Never publish personal source images or raw output.

## Provisional recommendation

**Native text → device capture quality → local OCR baseline/challenger → selective Sydney cloud fallback → schema extraction → confidence/provenance → human confirmation.**

The final default between Tesseract, PaddleOCR and RapidOCR—and whether Google, Azure or AWS earns a fallback role—must come from the benchmark, not marketing.

Benchmark execution itself requires separate approvals by tier: synthetic corpus generation; local execution and approved model acquisition; each cloud provider/region/data-use configuration; and any later structured or generative processing. No approval is implied by this review.

Detailed sources and evidence:

- `software-factory/runs/family-passport-ocr-2026-08-18/open-source-assessment/`
- `software-factory/runs/family-passport-ocr-2026-08-18/cloud-device-assessment/`
- `software-factory/runs/family-passport-ocr-2026-08-18/benchmark-design/`
