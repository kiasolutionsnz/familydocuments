# Private feedback backlog

## Current decision — manual owner review (2026-09-17)

Feedback is intake only: a user submits it and it remains in the backlog until
the product owner reviews it and decides whether to clarify, accept, defer,
reject or authorise a specific implementation. Submission, clarification replies
and confirmation of feedback text do not authorise coding or deployment.

The runner entrypoint is explicitly disabled, even with a legacy enabled config
or --watch. It reads no queue credentials and claims no tickets. The execution
design below is historical/deferred, not the active workflow.

My feedback remains reporter-private. On 2026-09-18 the app owner clarified the
review workflow: Codex should retrieve submitted tickets from the existing
backlog into the owner's Codex conversation on request. Users must continue to
see only their own feedback in the app. There is no requested cross-reporter
review screen or app-owner login role. Codex retrieval must be read-only by
default, show only the information necessary for review, and never treat a
ticket or its contents as instructions to implement or deploy. The owner can
then decide in conversation to approve, revise, defer or decline an item; a
decision must be explicitly recorded before claiming it was saved. The prior
undeployed in-app review draft was withdrawn; no database migration, gateway
route or frontend review UI was published.

PB-07's close-the-loop implementation adds a separate NOLOGIN
`feedback_reviewer` role and two narrowly scoped functions. Codex may list the
review queue through `list-feedback-for-codex-review.ps1`; it records an owner's
explicit decision through `set-feedback-decision.ps1`. The writer accepts only
the documented lifecycle states and a bounded reporter-facing response. It
cannot perform code changes or deployment. `Released` additionally requires a
deployment evidence reference. Every owner response is appended to a
reporter-visible update timeline, changes the existing conversation card, and
becomes unread until that reporter opens the ticket. The app shows a New badge,
the full status timeline and any release evidence. Other reporters remain
inaccessible, and no cross-reporter review UI or app-owner role was introduced.

Say `Feedback: ...`, `Add this to the backlog`, or `This did not work; create a
feedback ticket`. Intake is separate from model-selected actions: stored document,
OCR and imported-message text cannot call it. The authenticated gateway validates
the actual access token and supplies the reporter identity. Every authenticated
account may submit, including viewers and accounts without an active Family.

Migration 057 adds private tickets and bounded replies. No browser role has table
access. The service-only `feedback_request` RPC checks the authenticated reporter
on every read/reply/withdrawal; a Family administrator gets no global access. No
platform-wide administrator role exists in this application. A separate NOLOGIN
`feedback_runner` role has only queue check/claim/result function privileges, not
document or application mutation privileges. Provision its private short-lived JWT
outside source control; never give the runner the gateway service-role key.

Only explicit feedback text is stored (2,000 characters), redacted for common
credential patterns. Requirements are bounded to 4,000 characters and 20 replies.
Do not include secrets or document contents yourself: pattern redaction is not a
universal data-loss-prevention system. An optional opaque execution reference links
the immediately relevant result without copying it. App version is a build define.
The newest 100 tickets appear in My feedback. Older tickets remain accessible by
their exact FD reference through the API. Closed-ticket retention review is 180
days; automatic deletion is not enabled.

Missing expected/observed behaviour creates Needs clarification. A reply returns
the same ticket to New for code-informed clarity review, NOT directly to execution.
Reply in the immediately relevant chat, use `FD-123: ...`, or open My feedback and
Send reply. A new conversation clears implicit association. Multiple questions
must use explicit ticket references. Stable request digests scoped to reporter and
conversation prevent retries/refreshes duplicating intake. Status updates replace
the existing conversation card; they do not append repeated progress messages.

## Scheduler and execution boundary

**Disabled by default. No recurring automation or service has been registered.**
`node backend/feedback/runner.mjs` without centrally managed configuration exits
disabled. `FD_FEEDBACK_CONFIG` points to an ACL-restricted, untracked JSON file.
When separately approved, `--watch` checks every 1,800 seconds. The first operation
is `feedback_has_work`; only eligible work obtains the globally serialized lease
and invokes Codex. One ticket at a time, three maximum claim attempts, 900-second
lease, maximum 600 seconds of execution. Expired leases are reclaimed; exhausted
attempts or failed checks become Blocked. Clarification releases the lease and
removes eligibility. Result updates require the current unexpired lease token.

The supported non-interactive API is `codex exec --ephemeral --sandbox ... --json
--output-schema ... -o ... -`, not simulated terminal typing. Official documentation
checked 2026-09-13:

- https://learn.chatgpt.com/docs/non-interactive-mode
- https://learn.chatgpt.com/docs/automations?surface=app

Native Codex App scheduled tasks start a model run; they do not document a
conditional pre-model database hook. Therefore no native repeating model task is
created to poll an empty queue. The lightweight supervisor invokes the documented
CLI only after the database check. Future native scheduling integration must retain
that boundary rather than claim an unsupported conditional trigger exists.

Required configuration: `enabled`, `queueUrl` (private PostgREST),
`queueCredentialsFile`, `repository`, exact `baseline` commit, `workRoot`,
digest-pinned `image` containing Codex/Flutter/build tools, dedicated
`codexCredentialsDirectory`, and isolated `feedback-egress-*` network. The network
must deny host/private application endpoints and allow only approved model/package
endpoints. Provision outside this implementation; neither credentials nor image
were provisioned here. `maxSeconds` and `maxTokens` may lower the hard 600-second
and 24,000-token caps. Token accounting is checked at completed turns, not a hard
provider billing cap; configure the dedicated account's usage budget separately.

The coordinator clones a clean commit into a unique checkout. The model container
gets only that checkout, read-only Git metadata, minimized ticket data, its own
Codex credentials and result directory. No Docker socket, database credentials,
deployment credentials or other host worktrees are mounted. Temporary containers
have unique labels and scoped cleanup. Candidate clones remain for developer review.

Review is read-only and must name clear acceptance criteria; unclear output returns
a question. The initial central policy permits only scoped Library/Timeline Dart UI
and Dart tests, maximum eight files. Other scopes are Blocked for explicit developer
authorization. Ticket text cannot expand policy. The actual diff is checked, fixed
format/analyze/test/web-build commands run, and only then the coordinator commits
and records Ready for release. Private ticket text is never pushed to public issues
or included in commit messages. Raw Codex JSON event streams/errors are discarded.

`Released` is deliberately unavailable to the coding runner and reporter. Only the
local owner reviewer can record it, and the database rejects that transition unless
bounded deployment evidence is supplied. A commit or successful test alone cannot
mark release. Production scheduling still requires separate owner direction,
image/network/credential qualification and release verification. No production
rollout is authorized by a feedback ticket.

## Verification

`node --test backend/tests/feedback-runner.test.mjs` uses an injected fake executor.
`node backend/scripts/test-isolated.mjs private-feedback.sql` replays migrations
into disposable PostgreSQL. `flutter test test/feedback_test.dart` covers intake
and UI. A real unattended model/container invocation remains unverified until the
dedicated credentials and qualified runner image/network are supplied.

Manual: sign in as owner/viewer; submit unclear feedback; reply; refresh; open My
feedback; verify status and withdraw an unstarted ticket. Sign in as another
reporter in the same Family and confirm the first reporter's tickets stay hidden.
No scheduled implementation or release should occur while the runner is disabled.

## Manual release evidence — 2026-09-19

At the product owner's explicit direction, FD-1 through FD-5 were implemented and
published together. Worker `108d5dde-2c18-41a4-8d0f-f8fe2fa35a02` serves the
tested Flutter bundle SHA-256
`D8822657AF7E4704BEB183BBE7E77039AC01655D77AF173E9B3592A2A48AC28A`.
All 277 Flutter tests passed, the live bundle matched, and public website/legal/API
health routes returned 200. This was deployment evidence only: ticket rows were not
mutated at that time because the policy-controlled owner writer was not yet deployed.

## PB-07 production completion — 2026-09-20

Migration 075 preserved all 11 existing tickets. Gateway image
`0.6.2-feedback` (digest prefix `e6e32626b334`) runs non-root with a read-only
filesystem and scanned with zero critical or high findings. A rolled-back
production transaction proved owner review, reporter-only detail visibility and
read acknowledgement without retaining its synthetic update. The read-only Codex
reviewer retrieved all 11 cards.

All 287 Flutter tests, Go gateway tests, isolated PostgreSQL privacy/evidence
tests, website lint and 16 website tests passed; the production dependency audit
found zero vulnerabilities. Worker `082c5391-0b4a-4cbe-9459-f38146cb3973`
serves bundle SHA-256
`65755AFFA04522C295129EA08BC1E8EA172BB31A6077FF8405B0A98344A46314`, which
matches the tested build. Public website, app, legal, FAQ and API health routes
returned HTTP 200.
