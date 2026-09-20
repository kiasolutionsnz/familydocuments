# Telegram production cutover — 2026-09-18

Owner chose to move the existing `@FamilyDocumentsapp_bot` from staging to production. A Telegram bot has one active webhook; the staging worker and webhook must be retired as the production webhook is registered.

Preflight: Telegram `getMe` confirms the bot username. Its webhook still points to the staging `trycloudflare.com` endpoint with zero pending updates. The production gateway uses the previously approved `0.6.0-pb08` image (image ID `sha256:98ad632f809a7e1cc74eeae63b1162cd45ff02597b236b834d26ec6843dd353d`). Three non-token Telegram settings were added to production Compose; the token and secret were copied only to ignored private configuration. The gateway was recreated without building/pulling an image. Local and public unsigned `POST /integrations/telegram/webhook` now return 401, and public API health is 200. Database and other containers were not changed.

Cutover update: the owner registered `Family Documents Production Telegram` from an administrator session. The task was observed Running, and a manual production worker cycle completed. The staging task was stopped (Ready). Telegram's webhook and bot commands were moved to the production URL; `getWebhookInfo` showed zero pending updates and no last error. The owner connected their production account through Settings → Telegram and received the expected `/help` response in the private bot chat. Production inbound processing, reply delivery, and account linking are therefore verified.

On the host, an administrator can run:

```powershell
powershell -ExecutionPolicy Bypass -File 'C:\Users\Inder\My Codex Apps\familydocuments-phase2f-baseline\backend\scripts\register-telegram-production-task.ps1'
```

Still to verify: the staging task was stopped but disabling it requires the owner's administrator session; do that before the next host reboot. Confirmed action, attachment review, retry/no duplicate, and disconnect acceptance are not yet exercised. If production delivery fails, restore the staging webhook and staging task. Avoid printing or committing token, webhook secret, or JWT secret.
