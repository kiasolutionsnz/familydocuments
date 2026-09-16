# PB-16 — Household Lists and Tasks

Status: Complete — staging, 2026-09-16. The shared Lists feature is deployed
as private staging Site version 19. Live Telegram transport acceptance remains
part of PB-03, not a claim of this release.

## Delivered implementation

- Shared Lists destination for groceries, errands and chores. All active Family
  members can create/edit items. Assignment does not restrict visibility.
- Title, quantity, notes, category/store section, assignee and optional due date.
- Completion/reopening, completed-item filter, recent activity and refresh.
- Daily/weekly/monthly chores advance one occurrence from the scheduled date on
  completion. Monthly dates clamp to the last day of a shorter month. These are
  date-only tasks, with no timezone conversion or automatic alerts.
- Family-scoped RPCs, active-member validation, retry-safe creation UUIDs and
  optimistic version checks prevent silent overwrites and duplicate creation.
- Chat: "Add milk to Weekly shopping list" requires confirmation.
  Missing/ambiguous lists request clarification. Telegram reuses this action
  once the existing PB-03 transport setup is complete.
- Reminders offer Add to shared list: select a list, review the copied title,
  then Save. The original reminder is not changed or automatically completed.
- Lists are application records, not Google Drive files or Library collections.
  No purchases, supermarket integration, payments or meal planning.

## Verification

- Full Flutter regression suite: 264 passed before the final dialog fix.
- Final focused Flutter suite: 3 passed, including 360x800 layout, explicit
  reminder-copy Save, completion, and preserving typed text after failed save.
- Flutter analysis: no errors/warnings; 22 existing informational findings.
- Release web build passed after the dialog lifecycle correction.
- Go gateway suite passed; staging Worker proxy suite: 11 passed.
- Full migration replay and household-lists SQL suite passed in disposable
  PostgreSQL, including two-member collaboration, cross-Family denial,
  suspended-member denial, retry/conflict protection, recurrence, durable
  confirmation and duplicate confirmation handling.
- Gateway built from the existing pinned Go base. Offline Trivy scan with
  refreshed 2026-09-16 definitions: zero High/Critical findings.
- No live Telegram or authenticated staging browser acceptance claimed.

## Resolved staging blocker and recovery record

The user approved recovery. The latest valid staging backup was restored into
a separate named persistent Docker volume with the same pinned database image.
Recovered: 3 households, 4 members, 4 Auth users and 13 documents. Original
ownership and grants were restored, including the NOLOGIN feedback_runner role.
Persistence across restart, two restored sign-ins, authenticated Lists reads,
anonymous denial and the PB-16 transactional database suite passed.

Migration 067 was reapplied from source, followed by 068 and 069. The prior
gateway and volatile database container are retained. Production was untouched.
Existing backups are retained; pre-pb16-recovered.dump captures restored data
before PB-16. The manual environment generator now uses named database volumes;
disposable test runs remain ephemeral.

No newer staging data backup was found. Changes after 2026-09-15 19:03 NZ time
cannot be claimed recovered and may need re-entry; source code is preserved.
The published URL is https://familydocuments-phase2f-staging.inderchauhan.chatgpt.site.
Site deployment appgdep_6aaa025983148191aac8ed3b7cb07987 succeeded.

### Original incident evidence (retained for audit)

Observed 2026-09-16: fd-phase2f-9bda2e8f17e5-db has no fp schema and no Docker
mounts. Staging Auth and PostgREST are stopped. PostgREST logs show database
authentication failure after the earlier restart. This is consistent with
disposable storage loss; the full cause has not been established.

The attempted 068 migration failed within its transaction before creating any
table. Gateway replacement never ran. The existing frontend deployment was
not changed. New frontend source was pushed to its private Sites repository,
but no version was deployed.

Non-empty runtime backups include post-066-feedback-prefix.dump and
pre-067-feedback-first-word.dump from 2026-09-15 (latest at 19:03 Pacific/Auckland).
The latter has not yet been restore-tested. The new pre-pb16.dump records the
current mostly-empty database, not a recoverable application backup.
The zero-byte pre-066-feedback-prefix.dump must not be used.

Confirmation required for expanded recovery: restore-test the latest valid
backup into a separate persistent staging database, reconcile any work after
its timestamp, repair scoped Auth/API credentials, then apply 067 if required
and PB-16, verify and publish. Preserve existing backups, containers and files.
Do not restore production data into staging.

Rollback: retain the existing frontend version and gateway. Once deployed,
retain additive PB-16 tables if reverting UI; do not drop newly created lists.
