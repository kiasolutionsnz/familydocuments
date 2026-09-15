# Telegram staging activation

PB-03 deliberately accepts only private Telegram chats. The bot is a transport
into the existing FamilyDocuments conversation and confirmation flows; it does
not gain permission to save, move, share or delete items independently.

## Preconditions

1. The product owner creates or selects a dedicated FamilyDocuments Telegram
   bot in BotFather and confirms its public `@username`.
2. Copy `backend/.telegram.local.example` to the ignored
   `backend/.telegram.local` file and add the BotFather token plus a new 32+
   character webhook secret. Never send either value in chat, commit either
   file, or put either value in the Flutter bundle.
3. The staging gateway receives only `TELEGRAM_BOT_IDENTITY`,
   `TELEGRAM_BOT_USERNAME` and `TELEGRAM_WEBHOOK_SECRET`. The host-side worker
   receives those values plus `TELEGRAM_BOT_TOKEN` from the untracked
   `backend/.telegram.local` configuration.

## Activation and acceptance

After the configuration is present, register the supervised private staging
worker:

```powershell
powershell -ExecutionPolicy Bypass -File familydocuments-staging-20260913/register-telegram-staging-task.ps1
```

Then, with explicit owner approval, register only the staging HTTPS endpoint:

```text
https://<staging-api-host>/integrations/telegram/webhook
```

using `backend/scripts/telegram-bot.ps1 set-webhook`. Also register the bot
commands using `set-commands`. The command script intentionally does not print
tokens or the webhook secret.

Acceptance must use a private chat and cover: Settings link generation,
single-use `/start` linking, `/help`, a confirmation-gated action, an
attachment sent to Inbox only when a decision is needed, a reply/outbox retry,
and disconnect. Do not add the bot to a family group.

Rollback is to delete the webhook, stop/disable the supervised worker, and
remove the three gateway configuration values. Existing FamilyDocuments
records remain intact; disconnecting a member only revokes their Telegram
identity and outstanding Telegram controls.
