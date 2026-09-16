# Agent inputs and acceptance checks

All main endpoints are POST `/webhook/grownic/<slug>/v1` with JSON and the `x-grownic-key` header. Use a stable `event_id` for each source event; retries with the same content return the stored result. Reusing an ID with different content returns a conflict. All examples in `fixtures/` are synthetic. `npm run examples` refreshes the calendar timestamps.

| # / endpoint | Inputs and output | Acceptance check / scope |
|---|---|---|
| 01 `speed-to-lead` | contact, service, source, optional channel=sms; returns acknowledgement and review action | Validate source backend, recorded consent, timezone and exact recipient. An acknowledgement is immediate preparation; actual delivery depends on review, quotas and sending hours. Qualification replies are handed to staff; this is not a limitless conversational bot. |
| 02 `lead-generation` | query or configured ICP search; returns candidates and held records with source quotes | Requires an official page with a literal business email matching its domain. Rejects directory domains and inferred addresses. Persistent company-domain/email dedupe; CRM insertions require review. No personal-name inference, arbitrary scraping, cold-email sending, mailbox verification or CRM-wide dedupe unless its existing history is imported. Synthetic fixture intentionally holds `example.com`. |
| 03 `quote` | contact; items `[{service_id,quantity}]` or free-text message | Approved pricebook, integer minor units, tax basis points and quantity bounds. Generates a real one-page PDF attachment. Incomplete input asks for missing information. PDF uses an ASCII-compatible font and up to 12 lines; review non-English branding. Estimates require owner approval and scope confirmation. |
| 04 `voice` | Vapi `message` envelope; current `toolCallList` supported | `lookup_services`, `check_availability`, `book_appointment`, `request_callback`, end-of-call summary. Voice/speech/phone live in Vapi. Run `node scripts/voice-config.mjs`, add actual server credential ID, then import assistant into Vapi and connect an owned number. Native transfer only appears when an actual transfer number is configured. |
| 05 `follow-up` | contact, operation=enroll, stage=inquired/quoted/interested, service, channel | Explicit enrollment; default four touches on days 1,3,7,14. Inbound operations reply/optout/booked/bounce stop it. Scheduler 81 creates due work; worker 80 dispatches. One enrollment per contact; stopped/expired sequences require explicit operator review to restart. |
| 06 `appointment` | contact; operation availability/book/cancel/reschedule; offset timestamp start; confirmed=true for mutations | Real Cal slots, attendee name/email/timezone, and contact-owned booking UID for cancellation/reschedule. Cal's own booking validation is authoritative. A queued/pending booking is never reported confirmed. Cal sends booking confirmation; reminder scheduler handles 24h/2h touches. |
| 07 `recruitment` | contact and extracted resume_text; server-owned job rubric | Exact evidence quotations per job requirement. No autonomous hire, reject or suitability ranking. All invitations require human review; booking link uses client interview calendar. PDF/OCR ingestion is upstream of this text endpoint. |
| 08 `content` | source_text, source_url; configured voice/platforms | Up to six drafts, exact source support, two-hashtag limit. Human approves each draft. LinkedIn/Instagram/video are manual; optional X publishing through configured Publora connection. Audio transcription, video/image generation and engagement management are not included. |
| 09 `marketing` | approved_offer and historical Meta ad account | Reads last 30 complete days, up to 100 ads; calculates CTR/CPL/CPA without duplicate conversion counting. Proposes copy experiments. With real asset IDs, separately approves creative and PAUSED ad. No automatic budget change, ad activation, fabricated testimonials or statistical-significance claims. |
| 10 `support` | contact, question; approved FAQ knowledge | PostgreSQL text retrieval of up to 20 current approved FAQ records, model selection, verbatim answer rendering. Missing evidence, account/payment/refund/human requests create handoff tasks. This is curated FAQ support, not an authenticated order-lookup or refund engine. |

## Voice installation

Create a Vapi Custom Credential that sends `x-grownic-key` with the locally configured webhook secret, with **no Bearer prefix**. Set `VAPI_SERVER_CREDENTIAL_ID` when generating the assistant. The output has full tool schemas and prompt, but its URL/credential/phone routing must be client-specific. Select a model/voice supported by your Vapi account; the supplied defaults are OpenAI `gpt-4.1` and `alloy`.

Test service lookup, unavailable time, rejected booking, explicit timezone, caller requesting a person, transfer unavailable, email correction, timeout and duplicate tool delivery. A tool timeout must produce a callback offer, never a false confirmation. The flow uses a 7-second availability timeout and 8-second booking timeout inside a 25-second server timeout; measure actual latency on the deployed infrastructure.

## Extra useful payloads

Stop on reply:
```json
{"event_id":"inbound-message-unique-id","operation":"reply","contact":{"email":"actual-customer@their-domain.com","consent":false}}
```
Submit this only from a trusted inbox integration after receiving the real message. Use `optout` for unsubscribe/no-thanks, `bounce` for delivery failure, `booked` for confirmed meetings.

Book a returned slot:
```json
{"event_id":"booking-request-unique-id","operation":"book","start":"REPLACE_WITH_RETURNED_ISO_SLOT","confirmed":true,"contact":{"name":"Actual customer","email":"actual-customer@their-domain.com","timezone":"Europe/London","consent":true,"consent_source":"Customer confirmed appointment and contact details"}}
```

Knowledge ingest uses Basic Auth at POST `/webhook/grownic/knowledge/v1`; see `fixtures/00-knowledge.json`. All records must carry `approved:true`, real source URL and current exact answer. Optional `expires_at` prevents stale policy from being retrieved. A task record means a staff member needs to act; it is not proof they have received a notification or resolved the task.
