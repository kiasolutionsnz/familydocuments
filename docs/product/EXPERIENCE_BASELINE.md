# Experience baseline — Household Records Assistant

LAST REVIEWED: 2026-08-19  
RESEARCH OWNER: Software Factory UX Architect  
SOURCES: approved product definition and competitive UX pack  
COUNTRIES CHECKED: New Zealand primary; responsive experience intended for later internationalisation  
VERIFICATION STATUS: REVISED PROPOSAL; INDEPENDENT RE-REVIEW AND HUMAN APPROVAL REQUIRED

The proposed product experience is calm, source-first and action-oriented. Home shows the next three actions, Review shows unconfirmed suggestions with their exact evidence, Records groups authorized material around People, Home and Vehicles, and Search provides permission-safe cited retrieval. Add is an action rather than a navigation destination.

Desktop uses a slim rail and a two-pane review workspace. Mobile uses four bottom destinations—Home, Review, Records and Search—and stacks source evidence before editable fields. The design uses a warm neutral canvas (`#F7F6F1`), white surfaces, dark ink (`#172321`) and deep green actions (`#0E4A45`), with amber and red reserved for labelled states.

Critical facts require explicit confirmation. Sharing defaults private, previews what another adult will and will not see, and never gives administrators a private-content override. Search either cites an authorized exact source or abstains. Security, connection and privacy controls appear in context rather than dominating routine work.

**D-025/D-042 authentication trace:** S02 presents verified email/password and “Continue with Google” as equal AAL1 choices, while clearly separating Google login from later Google Drive consent. Email collision stops with no automatic linking; linking requires an authenticated account, password+TOTP step-up and confirmation; last-primary unlink is blocked. Google-only accounts show restricted AAL1 status and must securely enroll a local password plus application-owned SHA-256 TOTP before Owner/Admin or sensitive actions. Magic links remain invite/verify/reset initiation only. S16 covers identity methods, sessions, TOTP/recovery codes, 72-hour recovery and truthful lost-all-factor failure. Passkeys remain Phase 2.

Immediate Google-only bootstrap lasts exactly 900 seconds and shows an absolute deadline/timezone plus accessible remaining time. Cancel/interruption/expiry discards staged factors and moves the next attempt to the notified 72-hour path. Successful Google link/unlink signs out every device and returns to fresh S02 sign-in after a safe receipt. Provisional invitation/join preserves only an opaque reference and reveals no household metadata before post-setup revalidation.

The revised normative pack adds a J1–J7 trace, desktop/320px layouts for S01–S17, screen-specific state/recovery/leakage rules, keyboard/focus semantics, explicit custody/access/deletion/recovery consequences, mobile escape actions, and safe search result/abstention/conflict/restricted examples. It remains unapproved until independent re-review and the human gate pass.
