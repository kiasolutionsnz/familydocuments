# FP-035 bounded OCR contract spike

Synthetic-development implementation only. This spike defines the replaceable OCR contract, normalizes pinned PaddleOCR output, creates non-authoritative review candidates, and proves timeout/cleanup/confirmation behavior.

It does **not** call Docker, accept uploads, hold OAuth tokens, authorize users, persist family data, expose an API, or complete FP-035. The production launcher/parser boundary, authentication, database isolation, hardened OCR image and independent review remain gates.

Run:

```powershell
npm test
```

The tests consume only fictional OCR JSON under the Software Factory OCR smoke run.

