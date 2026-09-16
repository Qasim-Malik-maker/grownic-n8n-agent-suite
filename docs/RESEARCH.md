# Technical decisions and primary references

Checked 15 September 2026. The attached ten-agent guide defines the product categories; its marketing claims are not treated as measured results for this implementation.

| Decision | Reason / official reference |
|---|---|
| n8n 2.38.7 JSONs with built-in nodes | Pin the import target and avoid third-party node installation. [n8n CLI imports and publishing](https://docs.n8n.io/deploy/host-n8n/configure-n8n/use-the-command-line) |
| Separate task-runner container | Isolates Code execution from the n8n process. Use matching n8n/runner image versions. [Task runners](https://docs.n8n.io/deploy/host-n8n/configure-n8n/set-up-task-runners) |
| Structured model output and deterministic actions | Models extract or draft. Code validates evidence, prices, identities and action eligibility. [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs) |
| Cal live availability and explicit status | A returned UID with pending status is not confirmation; the booking API version is 2026-02-25. [Create booking](https://cal.com/docs/api-reference/v2/bookings/create-a-booking), [Slots](https://cal.com/docs/api-reference/v2/slots/get-available-time-slots-for-an-event-type) |
| Resend idempotency and conservative retries | Keep the same key within its retention window; do not blindly retry providers without an equivalent guarantee. [Idempotency keys](https://resend.com/docs/dashboard/emails/idempotency-keys) |
| Vapi owns real-time speech and telephony | n8n handles bounded business tools. Use credential references for authenticated server calls. [Function tools](https://docs.vapi.ai/tools/custom-tools), [Server authentication](https://docs.vapi.ai/server-url/server-authentication), [Transfer Call](https://docs.vapi.ai/tools/transfer-call) |
| Signed provider callbacks | Validate the exact callback data before updating contact or delivery state. [Twilio request validation](https://www.twilio.com/docs/usage/security#validating-requests), [Resend webhook verification](https://resend.com/docs/webhooks/verify-webhooks-requests) |
| Source-backed lead research | Require exact public page evidence; discovery does not imply permission to send messages. [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search) |
| Bounded advertising experiments | Existing metrics generate proposals; owner controls spend and activation. [Meta Marketing APIs](https://developers.facebook.com/docs/marketing-apis/) |
| Optional X publication | Keep the rest of the content queue manual until platform-specific media and permissions are configured. [Publora API documentation](https://docs.publora.com/getting-started) |

The competitive improvement implemented here is operational: approvals tied to exact payloads, persistent deduplication, current-state checks at dispatch, signed callbacks, cautious retries, visible exceptions, source-supported drafts and configurable client boundaries. Whether this improves outcomes over a customer's current system must be established with that customer's live acceptance tests. No fabricated conversion, recovery, cost-saving or revenue result is included.
