# FP-003 identity-assurance spike

This is a disposable provider-neutral contract harness, not application authentication code and not a production provider integration.

Run:

```powershell
npm test
npm run evaluate
```

`npm test` proves that the proposed application-side assurance contract is executable. `npm run evaluate` intentionally exits non-zero until one real candidate has executable evidence for every control. Documentation is never upgraded to runtime proof.
