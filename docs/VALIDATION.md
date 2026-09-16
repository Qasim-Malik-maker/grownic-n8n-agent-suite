# Validation record — version 1.1.1

Validated on 16 September 2026 against n8n 2.38.7 in TEST mode with outbound delivery disabled.

## Results

- All 16 workflow JSON files imported and published successfully in a clean isolated n8n instance.
- All 10 customer-facing webhook paths completed with synthetic fixtures.
- Every customer-facing request was replayed with the same event ID and returned the same stored result.
- Ten events were stored in PostgreSQL.
- The 30 automated business, database, security, signature and graph checks passed.
- No external provider action was dispatched.

## Covered agents

1. Speed to Lead
2. Lead Generation
3. Quote
4. Voice Receptionist
5. Follow Up
6. Appointment Setting
7. Recruitment Review
8. Content Repurposing
9. Marketing Experiments
10. Customer Support

## Deployment boundary

This confirms importability and synthetic execution of the packaged workflows. A customer deployment still requires the customer's own verified sender, phone, calendar, CRM, advertising and model credentials; approved business rules and knowledge; public HTTPS callback endpoints; and provider-specific sandbox or live acceptance testing. TEST mode and `outbound_enabled=false` remain the safe defaults.
