# PB-08 production cutover preparation — 2026-09-17 NZ

## Decision and scope

This is a prepared replacement of the existing FamilyDocuments app at
`familydocuments.app/prototype/` with the Phase 2F Flutter app. Preserve the
public home, blog, help, privacy and terms pages, existing email delivery and
inbound addresses. Production deployment has not occurred. The owner deferred
live Drive/email/Telegram and physical-phone acceptance for this readiness
pass; those behaviors remain unverified, not passed.

## Observed production baseline

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
   token-encryption key are not embedded in the bundle.
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

## Cutover sequence to prepare before approval

1. Create an exact production frontend package that serves the Flutter build
   under `/prototype/` while preserving the current Worker marketing, legal,
   auth callback and other existing routes. Do not publish the staging Sites
   `/_api` proxy or staging identity gate to the production domain. Verify
   asset paths, refresh/deep links, Google popup origin and CSP against the
   production hostname. Record the current Worker deployment ID and a verified
   rollback artifact.
2. Freeze one source commit and artifact hashes for Flutter, gateway, database
   migrations and the manual feedback/Telegram workers. Check the deployed
   worker scripts and task registration against this candidate. The current
   Telegram Windows transport is opt-in and the feedback runner stays disabled.
3. Close the host recovery gaps: make required notification, inbound and
   Telegram jobs start without interactive login, and prove a controlled
   no-login recovery. Confirm the existing Restic repository's off-host status;
   the current backup/integrity check alone does not prove host-loss recovery.
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
