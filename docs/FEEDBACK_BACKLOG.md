# Private feedback backlog

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

`Released` is deliberately unavailable to the coding runner and reporter. A future
separate deployment-evidence service/policy is required; a commit or successful test
alone cannot mark release. Production scheduling requires a separately approved
restricted service account, image/network/credential qualification, restart and
lease-recovery verification, and explicit task registration. No production rollout
is authorized by a feedback ticket.

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
