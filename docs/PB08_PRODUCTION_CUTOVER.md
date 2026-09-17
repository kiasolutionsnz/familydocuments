# PB-08 production cutover preparation — 2026-09-17 NZ

## Post-release chat authentication repair — 2026-09-17 NZ

After the owner could sign in but chat reported an expired session, live
inspection found production Auth and gateway lacked explicit JWT issuer
settings. The gateway's verifier defaulted to `supabase`, while GoTrue
v2.195.0's issuance code uses its unset issuer; this is the inferred cause,
not a decoded owner token. Production Compose now sets
`GOTRUE_JWT_ISSUER` and `JWT_EXPECTED_ISSUER` to the same
`familydocuments` value. Only Auth and the inbound/API gateway were recreated;
their images, database and other services were unchanged. Auth and public API
health returned 200, public Auth discovery reported issuer `familydocuments`,
and an unauthenticated chat request still returned 401. A fresh sign-in is
required to obtain a newly issued token. Owner confirmation of authenticated
chat success is pending; these configuration checks alone do not prove it.

## Production deployment update — 2026-09-17 15:34 NZ

The owner directed deployment while deferring the no-sign-in recovery drill and
additional backup/restore work. All 29 migrations 040–069 were applied to the
existing production database under `supabase_admin`, with error-stop and each
migration's own transaction. The before/after counts remained 41 households,
75 memberships, 125 Auth users and 30 documents; invalid `fp` constraints stayed
at zero. PostgREST was notified to reload its schema.

The previously offline-scanned gateway candidate became local release
`kia/familydocuments-inbound-gateway:0.6.0-pb08` (image ID
`sha256:98ad632f809a7e1cc74eeae63b1162cd45ff02597b236b834d26ec6843dd353d`).
Only `inbound-gateway` was recreated using the existing production Compose
configuration. Public API health and Auth settings returned 200. A production
API preflight returned 204 with the exact `https://familydocuments.app` origin
and 403 for an unrelated origin.

The public `familydocuments` Cloudflare Worker now runs version
`2be67702-23b2-4081-9390-167787f6689d`. The previous full-traffic version
`d669c428-3b62-4232-94d8-ff1d817e04da` remains available for frontend
rollback. Root, FAQ, privacy, terms, `/prototype/`, its Bootstrap and main JS
returned 200. The downloaded public main JS SHA256 exactly matched the tested
Flutter build:
`86C66A6DF4304E4A3D8779127811002A49ADDD5DEF812FA733AF7AF62ED890C8`.
An initial publish unintentionally enabled the workers.dev alias; a corrected
production configuration disabled both workers.dev and preview URLs, and the
alias subsequently returned 404. The canonical custom domain still serves.

This is a **deployed production release**, not full PB-08 acceptance. Authenticated
public user journeys, real Google Drive/email/Telegram and physical-device
tests were not run. No fresh cutover backup or new restore drill was run at the
owner's direction; the earlier verified snapshot is retained. Docker Desktop
recovery without Windows sign-in is still unproven. Do not use a frontend-only
rollback to claim database rollback: the additive migrations remain in place,
and post-release data must not be overwritten.

## Decision and scope

The original plan was a prepared replacement of the existing FamilyDocuments app at
`familydocuments.app/prototype/` with the Phase 2F Flutter app. Preserve the
public home, blog, help, privacy and terms pages, existing email delivery and
inbound addresses. Production deployment is now recorded in the update above. The owner deferred
live Drive/email/Telegram and physical-phone acceptance for this readiness
pass; those behaviors remain unverified, not passed.

## Observed pre-deployment production baseline

- Public app: `familydocuments.app`; API:
  `api-familydocuments.servicehub.co.nz`; existing public frontend is a
  Cloudflare Worker, with marketing/legal routes alongside the current app.
- Current gateway container: `family-passport-supabase-inbound-gateway-1`,
  image `sha256:f2fb36b78cb4c59d0b2da3c2bb5d150a7d8e5f1f9f442733c9c48c40fb39a8a9`.
- Database container: `family-passport-supabase-db-1`, healthy and private,
  with 41 households, 75 memberships, 125 Auth users and 30 documents.
  No invalid `fp` constraints. Production lacks the Phase 2F Lists table and
  active-Family Drive summary contract.
- Production notification and inbound workers have known interactive-task
  restart limitations. Host reboot without login has not been proven. Existing
  staging quick-tunnel addresses are not suitable for production routing.

## Completed preparation

1. `backend/scripts/backup-ux-release.ps1` produced custom-format native dump
   `fd-ux-20260917-092244/database.dump`, SHA256
   `300BB8B248E095C39DB5E33834B1BEFB76B4AEC81A6A422F8B35E524D30B42C3`.
   Restic snapshot `7211eb0b2ec348dd717a211b8f9574e2bb3b9fd84877a959993f8bfaeeb37353`
   passed integrity check. Private backup files remain ignored by Git.
2. An isolated restore completed. The fuller disposable rehearsal restored
   both `auth` and `fp`, then applied all 29 migration files numbered 040–069
   (052 does not exist). Before/after counts matched: 41 households,
   75 memberships, 125 Auth users, 30 documents, zero invalid constraints.
   Evidence: ignored `backend/backups/fd-ux-20260917-092244/pb08-upgrade-rehearsal-with-auth.json`.
   Production was not migrated. This proves migration compatibility with a
   point-in-time copy, not live application behavior after cutover.
3. Flutter production build is reproducible with
   `familydocuments_flutter/build-production.ps1`. It uses `/prototype/` as
   base href, the existing production API, and the public Google Drive client
   ID from the established ignored production configuration. The secret and
   token-encryption key are not embedded in the bundle. Source commit
   `8fddc305f31c99c5e6e5dcc445c0727f4d597bca` is backed up on GitHub
   branch `release/phase2f-pb08-20260917`. The verified main JavaScript SHA256
   is `86C66A6DF4304E4A3D8779127811002A49ADDD5DEF812FA733AF7AF62ED890C8`.
   The private production-web archive SHA256 is
   `A0D3D8E06FA8E2267AA95EE75A9B3B2E3F5704E9B7EA37C640FF9E7B2324E510`.
4. Gateway candidate `familydocuments-gateway-pb08-candidate:20260917` was
   built with no network access from the pinned local Go image. Image digest
   `sha256:98ad632f809a7e1cc74eeae63b1162cd45ff02597b236b834d26ec6843dd353d`;
   runtime config image ID
   `sha256:91e8ce96d6a16733ae93b4327041e3becd46fc9d1f0703bf9dd1c212765624f0`.
   Offline Trivy 0.67.2 with the local database updated 2026-09-16 reports
   zero High or Critical findings. Candidate is not promoted.
5. Staging Drive status function drift was repaired and verified separately;
   it is not part of the production database yet. Production replay of 058 in
   the isolated migration sequence passed.
6. Read-only task inspection found the production classifier, attachment
   scanner, notifications, inbound health, AI/OCR health and daily statistics
   tasks set to Interactive logon. The staging Telegram task is S4U, which does
   not establish production recovery. The Docker Desktop service is Stopped
   with Manual startup while its user-session engine is running. The Restic
   repository is on D:, which `Get-Disk` identifies as a non-boot SATA disk
   inside this computer. It is not an off-computer backup. The owner requires
   unattended recovery after reboot, so this remains a release gate.
7. A local candidate was assembled from the existing public Sites checkout
   (`appgprj_6a85158e62b08191ba1ddb54f77614f8`) and the verified Flutter
   build. It retains the home, blog, FAQ, privacy and terms source routes and
   replaces only the old `/prototype/` assets. The Vinext build passed and
   produced `dist/server/index.js` with a callable fetch handler plus the
   Flutter app files; its main JS hash matches the verified Flutter bundle.
   Private build archive SHA256:
   `3EFD46AAFEDEAF1A35E977B866454FA4FDC68B30826D3DD6C5E6D37A028DEF27`.
   Private source archive SHA256:
   `CC588E97098A763A796EEC3F1550BEAC1B799BF5B246F07E18379F91EA57BC2F`.
   Source archive excludes local environment files and old prototype assets.
   This local checkout has not been proven identical to the currently deployed
   production Worker, and the candidate has not been pushed or published.
8. The current Site source branch was fetched read-only at commit
   `8a37a5706f5ad55d751ae13a22d23446fb2da065`. Its `frontend/app`
   differs from the older local checkout only in privacy and terms page link
   markup. A second local candidate was assembled from this exact Site source
   plus the same verified Flutter build. Its Vinext route build and server
   syntax check passed, and its Flutter bundle SHA256 matches item 3. The
   ignored private build archive is
   `backend/backups/fd-ux-20260917-092244/pb08-exact-site-rc/pb08-exact-site-dist.tar.gz`,
   SHA256 `DC657A8A58E4BEE4DF5A92C2F501EAB655306706293C2D7372A5B40138ABD8DA`.
   This resolves Site-source provenance, not parity with the separately
   deployed `familydocuments.app` Cloudflare Worker. It was not published.
9. On 2026-09-17, Restic copied only verified production snapshot
   `7211eb0b2ec348dd717a211b8f9574e2bb3b9fd84877a959993f8bfaeeb37353`
   into a standalone encrypted repository. `restic check --read-data` passed,
   and an isolated restore of its database dump matched SHA256
   `300BB8B248E095C39DB5E33834B1BEFB76B4AEC81A6A422F8B35E524D30B42C3`.
   A static 6,059,636-byte archive with SHA256
   `751E7BCC731AE9DE075DDF9E8DAED4CA27B12E1E4E4A3143765C0F1EA54CDA81`
   was copied to the connected OneDrive sync folder under
   `FamilyDocuments-Backups/FamilyDocuments-2026-09-17-restic-encrypted.tar.gz`.
   The same private folder and archive appeared in OneDrive.com at 5.78 MB.
   The password was not copied. This proves local archive integrity and
   cloud-side visibility, not a restore downloaded independently from cloud.
   OneDrive desktop sync is not yet an unattended post-reboot backup method.

## Original cutover sequence (historical plan; see deployment update above)

The following checklist is retained as the pre-deployment record. Statements
about the owner being away, task changes being denied, and production not yet
being migrated are superseded by the dated deployment update and
`PB08_UNATTENDED_RECOVERY_PLAN.md`.

1. Reconcile the exact-Site-source frontend candidate with the currently
   deployed `familydocuments.app` Worker revision, especially marketing copy,
   auth callbacks, any non-source
   runtime config, and the old marketing links containing `#rentals` or `#auth`.
   Verify app asset paths, refresh/deep links, Google popup origin and CSP
   against the production hostname. Preserve the existing marketing/legal
   routes and record the current Worker deployment ID and a verified rollback
   artifact. The staging Sites `/_api` proxy and staging identity gate do not
   belong on the production domain.
2. Freeze one source commit and artifact hashes for Flutter, gateway, database
   migrations and the manual feedback/Telegram workers. Check the deployed
   worker scripts and task registration against this candidate. The current
   Telegram Windows transport is opt-in and the feedback runner stays disabled.
3. Close the host recovery gaps: make required notification, inbound and
   Telegram jobs start without interactive login, and prove a controlled
   no-login recovery, including a supported way for the Docker engine to start
   without an owner session. D: is an internal SATA disk, not an off-computer
   destination. A one-time encrypted FamilyDocuments archive is now visible
   in OneDrive.com; a downloaded cloud-copy restore remains to close the
   host-loss recovery gate. The
   current backup/integrity check alone does not prove host-loss recovery.
   On 2026-09-17, exact XML rollback copies of the six FamilyDocuments
   production tasks were saved privately. The task change was attempted but
   Windows denied it because the available shell is not an administrator;
   no task was changed. `backend/scripts/enable-unattended-familydocuments-tasks.ps1`
   now provides a checked preview and an elevated `-Apply` path: the three
   long-running workers move from logon to startup triggers, and all six
   tasks move from Interactive to S4U while preserving their actions and
   periodic schedules. The script backs up task XML and rolls back on failure.
   It does not restart current worker instances or solve Docker engine startup.
   Docker's documented Desktop auto-start setting runs at user sign-in;
   enabling `com.docker.service` alone is not proof that the Linux engine
   starts without sign-in. A boot-time engine design and controlled host-wide
   reboot test remain required.
   The scoped VM option, worker relocation, route switch and rollback sequence
   are recorded in `docs/PB08_UNATTENDED_RECOVERY_PLAN.md`. The owner is away
   from the computer, so no UAC prompt, task change, route change or reboot
   is attempted now.
4. Immediately before cutover, pause relevant writers for a short maintenance
   window, capture a fresh native and encrypted backup, verify the archive and
   restore it to an isolated database. Rerun migrations 040–069 there and compare
   household/member/Auth/document counts, constraints, RLS and function ACLs.
5. Apply migrations to production in order, with error-stop and a named record
   of each successful step. Promote the qualified gateway using existing
   production private networks, exact origin and secrets. Keep the previous
   image/container available. Start only the matching worker versions, then
   publish the verified frontend package to the existing public domain.
6. Validate anonymous denial, sign-in and MFA, family selection, original
   opening, Library/Rentals/Travel, Inbox, Reminders, Lists and feedback intake
   on the public URL. If the owner continues to waive live external integration
   tests, record those feature limitations explicitly at go/no-go.
7. Re-enable writers and watch queue health, error rates, reminder delivery,
   inbound email, Telegram, Drive gateway and frontend routing for a defined
   post-cutover period.

## Rollback boundary

Before database migration, restore the previous Worker and gateway deployments.
After migration, UI-only rollback is not enough: the old app does not understand
the added schema/workflows and could lose or misinterpret writes. Stop writers,
restore the fresh pre-cutover database backup to a separate verified target,
and switch the complete old stack back together. Reconcile writes made after
the snapshot before any destructive restore. Never restore over a running
production volume. Keep existing Google Drive originals and credential key
backups available; database rollback cannot undo external provider actions.

## Open release decisions

- Confirm that `/prototype/` remains the app URL and marketing/legal pages stay
  at the public root. This is the recommended route arrangement based on the
  existing site, but the complete production Worker package must still be made.
- Confirm whether the incomplete PB-07 owner-wide review screen ships later;
  feedback intake is already manual and the runner is disabled.
- Approve the final production window and rollback target only after the
  package, unattended recovery and fresh backup checks are complete.
