# FD-7 — Secure offline travel pack

## Decision

FD-7 is a mobile-only, per-device capability inside **Library → Travel → Trip**. A member explicitly chooses which critical travel documents to keep offline. The browser does not pretend to provide durable offline storage; it explains that the feature is available in the mobile app.

## User experience

1. Open a trip in Library.
2. In **Offline travel pack**, select **Keep offline** beside a document.
3. Review the local-storage explanation, keep the suggested expiry or choose another date, then confirm.
4. The row shows download progress and then the date through which the copy is available.
5. Use the document menu to open the encrypted copy without a network request or remove it from the device.

The default expiry is seven days after a future trip end date. If the trip has no future end date, the default is 30 days from download. Expired copies are purged when the offline pack is opened.

## Security and storage contract

- Document bytes and the local manifest are encrypted with AES-256-GCM before being written to application-support storage.
- A random device key is held in Android Keystore or iOS Keychain through Flutter secure storage; it is not written beside the documents.
- Storage directories and secure-storage keys are scoped to a hash of the signed-in account, so another account using the same device cannot list or decrypt those copies through the app.
- The source document and Family/Drive permissions remain authoritative. Offline copies are device-local derivatives; they are not uploaded, shared, indexed, or backed up by FamilyDocuments.
- Each offline document is limited to 20 MB in this first release.
- Removal deletes the encrypted file and its manifest entry. Device compromise, rooted/jailbroken operating systems, or a user extracting app/OS secrets are outside this control's threat boundary.

## Acceptance status

- Encrypted storage and in-session offline viewer: complete.
- Automated Library behavior tests: passing.
- Full Flutter suite: 283 tests passing.
- Release web build: passing and deployed to production; browser receives only the mobile-availability explanation.
- Secure cold-start entry while the phone has no network: implemented. When normal online session restoration cannot complete, Android/iOS can discover the last account-scoped vault and offer **Open offline travel pack**. Device authentication is required before document names or bytes are shown, and the vault locks again when the app is backgrounded.
- Production web deployment: Worker `42d691cb-e306-4c00-a49f-05165135d24f`; live bundle SHA-256 `054839FC649D87FE438EF8B7A21B0F2B80078A5D4FBF0F89CEDF310CCA5BF424`. Public root, app, FAQ, privacy, terms and API health returned HTTP 200, and the live bundle matched the tested build.
- Android/iOS physical-device acceptance: pending. This Windows host currently has no Android SDK, and iOS builds require macOS/Xcode.

Physical-device acceptance must verify: save while online, enable airplane mode, restart the app, open the saved PDF/image, confirm a non-saved document fails honestly, remove a copy, and verify expiry purge. Android screenshots must also confirm the key is protected by Keystore-backed secure storage; iOS must confirm Keychain behavior after device restart.

FD-7 should not be marked fully accepted or production-mobile complete until those checks pass on a signed mobile build.
