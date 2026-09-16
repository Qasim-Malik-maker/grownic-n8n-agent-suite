# Deployment and operating guide

## 1. Dedicated customer installation

Deploy one copy per customer. The workflows trust the authenticated integration endpoint, not an arbitrary browser caller. Keep the webhook key on the customer's form/CRM backend; do not expose it in public JavaScript. User-supplied data cannot set client configuration, live mode, approval or prices. The database and credentials are the tenant boundary.

The Compose file binds n8n and the callback gateway to localhost. For external services, place an HTTPS reverse proxy in front of the required webhook paths. Keep the editor and approval console private or access-controlled. Set `WEBHOOK_URL`, `N8N_HOST`, `N8N_PROTOCOL`, `PUBLIC_GATEWAY_URL` and `config/client.json.public_n8n_url` to the actual hostnames. Keep `.env`, `runtime/` and database backups private.

Run `npm ci`, `npm run build`, then `npm run configure`. The build creates the combined `all-workflows.json` CLI import file required by the import script. The configure script generates independent random secrets and preserves existing configuration. It writes all n8n credentials, with `UNCONFIGURED` placeholders for providers so you can import and test without API keys. The n8n Docker container runs as its `node` user: grant that user read access to `runtime/credentials.json` on the host (for example, `sudo chown -R 1000:1000 runtime` on Linux) before importing. Do not make credential files publicly readable.

Run `docker compose up -d`; complete owner signup; run `node scripts/import.mjs --publish-test`; restart n8n. Publishing enables local test webhooks and timers, but TEST mode and the database outbound flag block provider dispatch. The PostgreSQL initialization scripts execute only for a new volume. To change client settings later, edit `config/client.json` and run `node scripts/apply-config.mjs`.

The `grownic_app` role receives DML access to the dedicated schema. It does not own the database. n8n stores its own metadata/credential encryption in `n8n_data`; business state is in `grownic_db`. Keep `N8N_ENCRYPTION_KEY` stable and back up both volumes. Never reuse workflow IDs to overwrite unrelated customer workflows; use a dedicated project/instance or generate new IDs deliberately when creating another installation.

## 2. Provider connections

| n8n credential | Setup |
|---|---|
| Grownic Postgres | Dedicated database containing `sql/001_schema.sql`, then `sql/002_operations.sql`, and one `grownic.settings` row |
| Grownic Webhook Key | Header `x-grownic-key`, value from your `.env` |
| Grownic Review Login | HTTP Basic, user `owner`, password from your `.env` |
| Grownic OpenAI | `Authorization: Bearer <key>`; Responses API; configured structured-output model |
| Grownic Resend | Verified client sender domain and sending key; one email recipient per action |
| Grownic Twilio | Basic Auth account SID / auth token; configure matching Messaging Service SID and account SID in client config |
| Grownic Cal | `Authorization: Bearer <key>`; a real event type, connected calendar and timezone |
| Grownic Tavily | `Authorization: Bearer <key>`; search results need raw page content |
| Grownic HubSpot | Private app access token with contact read/write scope |
| Grownic Meta | Token with the permissions for the selected client's ads; real account, page, adset and image hash |
| Grownic Publora | Header `x-publora-key`; optional connected X profile only |

After entering provider keys in `.env`, rerun `npm run configure` and import credentials again, or edit the named credentials inside n8n. Existing API keys are not fetched from your personal accounts by this package. Change sender, reply inbox, postal address, business name, prices, tax, service area, calendar, job rubric, voice and offer for each customer. Do not sell demo prices as real quotes.

## 3. Callbacks and reply visibility

Configure the gateway public URL paths:

- `/callbacks/twilio`: both inbound messages and Messaging Service delivery status callbacks. Signatures use the exact public URL.
- `/callbacks/resend`: `email.delivered`, `email.bounced`, `email.complained`, `email.received`; set the endpoint's signing secret. Resend receiving must be configured for the actual **reply-to inbox/domain**. If replies go to Gmail or another provider instead, connect that inbox to the authenticated follow-up webhook using the documented payload. A sender webhook alone cannot detect inbox replies.
- `/callbacks/cal`: `BOOKING_CREATED`, `BOOKING_RESCHEDULED`, `BOOKING_CANCELLED`; set the Cal webhook secret.

The gateway verifies signatures before forwarding. Inbound email/SMS always stops the sequence, including out-of-office messages; an operator can decide the next action. Replies, bookings, bounces and opt-outs must be connected and tested before enabling automatic follow-up. Reply/opt-out events commit atomically with their audit entry. Receipts arriving before provider IDs are recorded are retried by reconciliation. Delivery status `accepted` means provider acknowledgement, not proven inbox delivery.

## 4. Review and live activation

Default: `mode=test`, `outbound_enabled=false`, all auto flags false. In TEST, model and upstream responses come only from fixtures; approvals simulate actions. Existing simulated actions never become live when you change the mode. Use new real events after configuration.

For live testing, supply all client facts and set `mode=live` while keeping `outbound_enabled=false`. Live mode allows API reads and model calls; dispatch stays blocked. Review the resulting exact payloads. Approvals bind to the displayed payload hash. Suggestions are saved in audit history; they do not silently rewrite an approved message. To edit a draft, reject it and submit corrected input under a new event ID.

When the provider checks pass, set `outbound_enabled=true` and apply configuration. Enable only the desired automatic flags: `auto_send_transactional`, `auto_followup`, `auto_book`, `auto_support`. Hiring invitations, quotes, CRM insertions, content and ad actions still require owner review. The automatic voice booking path requires `auto_book=true`; otherwise the caller receives an explicit unconfirmed result and callback option.

Pause by setting `outbound_enabled=false` and applying configuration. Already in-flight provider requests cannot be recalled. Leases and a final database recheck prevent stale queued work from continuing; they do not create an impossible exactly-once guarantee across independent APIs.

## 5. Recovery and monitoring

Inspect `grownic.health`, `grownic.audit`, `grownic.failures`, `grownic.events`, `grownic.objects` and the review console. Failed/unknown actions appear in review with the recorded reason. `unknown` is not automatically resent. Reconcile it with the provider and record the result before a deliberate retry. Resend retries retain the same idempotency key only inside a conservative 23-hour window. SMS/calendar/CRM/social/ads timeouts are held because those actions can have occurred despite a missing response.

The worker claims one action per 10-second run; quota limits are shared with voice bookings. Set realistic send windows in the recipient's timezone. Follow-up days are **calendar days after enrollment**, shifted by the send window, with at least one day between accepted touches and a maximum of four. Appointment reminders run at 24 hours and 2 hours, with a one-hour catch-up window; stale reminders are skipped.

Keep error-execution retention appropriate to client data; defaults prune n8n execution data after seven days, while business audit tables persist. Export/retain/delete those business tables according to the customer's agreed policy. Add infrastructure alerting on n8n, database availability and the failures table as part of customer operations.

## 6. Commercial delivery scope

Sell configuration, workflow implementation and ongoing operation in the customer's environment. Provider subscriptions, consumption and any required n8n commercial agreement are separate. Confirm the applicable [n8n license](https://docs.n8n.io/sustainable-use-license/) before offering a shared hosted platform or reselling access to n8n itself. No performance guarantee, conversion uplift or $1,000 ROI has been measured by this package.
