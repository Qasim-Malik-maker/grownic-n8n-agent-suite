from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor
from reportlab.pdfbase.pdfmetrics import stringWidth, registerFont
from reportlab.pdfbase.ttfonts import TTFont
import json

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'diagrams';OUT.mkdir(exist_ok=True)
registerFont(TTFont('Helvetica','/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'))
registerFont(TTFont('Helvetica-Bold','/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'))
data=[
('Speed to Lead','Capture the enquiry while the intent is fresh.','#EAC27A',[
('Receive enquiry','Trusted form or CRM supplies contact, service, source and consent evidence.'),('Validate and deduplicate','Reject malformed input. Replayed event IDs return the stored result.'),('Prepare acknowledgement','Use the configured business name, service and one qualifying question.'),('Review the exact message','Owner approves; optional transactional auto-send must be configured.'),('Recheck and send','Verify current consent, local hours, limits and delivery lease. Send one message.'),('Record the outcome','Save provider ID and status. Route incoming replies to the recorded contact.')],'Missing contact or consent','Hold the work for a person; never guess a recipient.','Track: time to first accepted message, replies and booked meetings.'),
('Lead Generation','Every prospect needs evidence you can inspect.','#7ECBB9',[
('Search the selected market','Tavily queries the configured ICP and returns public page content.'),('Extract evidence','Structured extraction returns company, business email and exact source quotes.'),('Check official source','Email must appear on the company domain. Reject directories and inferred addresses.'),('Deduplicate persistently','Database checks domain and email. Only new prospects create CRM work.'),('Owner reviews candidate','Inspect source URL, quoted evidence, business fit and the exact CRM payload.'),('Insert into CRM','Approved action upserts the contact in the configured HubSpot account.')],'Evidence missing or duplicate','Hold or skip candidate; no outreach email is sent by this agent.','Track: evidence pass rate, duplicate rate and accepted prospects.'),
('Quote','Language is flexible. Pricing is deterministic.','#EAC27A',[
('Receive service request','Accept structured items or a free-text enquiry with customer identity.'),('Extract missing variables','Map only known service IDs. Ask for quantities when they are absent.'),('Apply approved prices','Use integer minor units, quantity limits, configured tax and pricebook version.'),('Generate PDF estimate','Create the actual line-item PDF and attach it to the exact draft email.'),('Owner approves scope','Review amount, recipient, scope and expiry before enabling delivery.'),('Deliver and record','Send the approved estimate, then record acknowledgement and provider ID.')],'Unknown item or quantity','Ask for clarification. The model cannot invent a price or discount.','Track: estimate preparation time, approval time and accepted quotes.'),
('Voice Receptionist','A phone conversation with accountable tools.','#91B9F2',[
('Answer in Vapi','Use the generated assistant configuration and the client-owned phone number.'),('Understand the enquiry','Ask service, location and timing; disclose the automated receptionist.'),('Use business tools','Read configured services and fetch real calendar availability through n8n.'),('Confirm customer details','Read back name, email, date, local time and timezone before a booking request.'),('Book or hand off','Return confirmed only with a confirmed booking UID; otherwise offer callback.'),('Save call outcome','Record end-of-call summary, booking result or human callback task.')],'Person requested or tool error','Use configured transfer after agreement, or record a callback request.','Track: answered calls, tool latency, confirmed bookings and handoffs.'),
('Follow Up','A finite sequence that stops when the customer responds.','#7ECBB9',[
('Enroll explicitly','Record the consenting contact, funnel stage, service and approved channel.'),('Schedule next touch','Default days 1, 3, 7 and 14. Database state survives workflow restarts.'),('Check current state','Replies, bookings, bounces and opt-outs stop remaining queued touches.'),('Prepare stage-specific text','Use recorded service and stage. Owner reviews unless auto-follow-up is enabled.'),('Dispatch due message','Recheck consent, sending hours, limits and stop state immediately before send.'),('Advance only on success','Provider acknowledgement advances the sequence; fourth touch closes it.')],'Reply, booking or opt-out','Stop the enrollment and suppress queued follow-ups in one transaction.','Track: reply rate per touch, stop latency and sequence completion.'),
('Appointment Setting','Availability is live; confirmation is explicit.','#91B9F2',[
('Read customer intent','Request availability, booking, cancellation or rescheduling.'),('Fetch live slots','Cal.com supplies real openings. Offer up to three with an explicit timezone.'),('Validate selection','Require a returned future slot, customer details and explicit confirmation.'),('Approve booking action','Owner reviews unless automatic booking is enabled for this client.'),('Write to Cal.com','Record confirmed UID. Cancel/reschedule only a booking owned by the contact.'),('Confirm and remind','Cal confirms the booking; scheduler prepares 24-hour and 2-hour reminders.')],'Slot changed or booking pending','Do not claim confirmation. Offer a new slot or human callback.','Track: confirmed bookings, reschedules and attendance in client records.'),
('Recruitment Review','Organize evidence for a human hiring decision.','#C4A5EC',[
('Receive application','Trusted form supplies resume text and applicant contact details.'),('Load the job rubric','Use the client-approved requirements held in server configuration.'),('Extract exact evidence','Find supporting resume quotes. Missing evidence remains unclear.'),('Build the review record','Store each requirement, its evidence and useful clarification questions.'),('Human decides invitation','Review the full context and exact interview invitation; no automatic rejection.'),('Send approved invitation','Use the client interview booking link and record the provider result.')],'Unclear or unsupported evidence','Leave requirement unclear and ask a question; never invent qualifications.','Track: review time, evidence quality and human-approved invitations.'),
('Content Repurposing','Turn one source into a reviewable set of distinct posts.','#E6AB91',[
('Receive source material','Input approved source text, source URL and the configured voice profile.'),('Draft distinct angles','Structured generation creates platform-specific posts from the supplied material.'),('Validate source support','Require an exact supporting quote, character limits and at most two hashtags.'),('Save drafts for approval','Owner sees the exact post, source quote and destination.'),('Publish through chosen route','LinkedIn and visual platforms remain manual. Optional X delivery uses Publora.'),('Keep the publication record','Store approvals and provider acknowledgement where publication is connected.')],'Unsupported text or oversized post','Hold it for correction. Do not invent experience or numerical results.','Track: approved drafts, edit effort and actual published-post performance.'),
('Marketing Experiments','Use real observations to propose the next test.','#C4A5EC',[
('Read Meta performance','Retrieve the last 30 complete days, bounded to the first 100 returned ads.'),('Calculate clean metrics','Compute CTR, CPL and CPA without double-counting overlapping conversion events.'),('Draft test hypotheses','Use the approved offer and cite the source ad IDs behind each variant.'),('Owner reviews the creative','Inspect copy, hypothesis, assets and target adset before creating anything.'),('Create a paused test ad','Approved creative leads to a separately reviewed PAUSED ad action.'),('Review results next cycle','A person launches and controls spend; later runs include observed performance.')],'Small sample or missing setup','Label uncertainty and keep proposals for manual review.','Track: approved tests, spend and conversions measured in the ad account.'),
('Customer Support','Answer from approved knowledge and show the source.','#7ECBB9',[
('Receive customer question','Trusted chat or inbox integration supplies the question and contact.'),('Retrieve current FAQs','PostgreSQL retrieves up to 20 approved, unexpired knowledge records.'),('Select supporting answers','Model selects relevant IDs and intent; it does not write policy answers.'),('Apply deterministic routing','Public FAQ answers render verbatim. Account, refund and human requests escalate.'),('Review or reply','Owner review is default; optional automatic FAQ replies require client setup.'),('Record answer and handoff','Store citations, delivery outcome and a staff task for unresolved questions.')],'Insufficient or private context','Create a human handoff; do not invent policy or disclose account data.','Track: grounded replies, handoff rate and outcomes verified by staff.')
]

def wrap(text,font,size,width):
    words=text.split();lines=[];line=''
    for word in words:
        trial=(line+' '+word).strip()
        if stringWidth(trial,font,size)>width and line: lines.append(line);line=word
        else: line=trial
    if line:lines.append(line)
    return lines

c=canvas.Canvas(str(OUT/'Grownic-10-Agent-Flow-Diagrams.pdf'),pagesize=(720,900))
c.setTitle('Grownic - Ten Agent Workflow Diagrams')
for idx,(title,sub,accent,steps,branch,detail,metric) in enumerate(data,1):
    ac=HexColor(accent);c.setFillColor(HexColor('#0B1018'));c.rect(0,0,720,900,fill=1,stroke=0)
    c.setFillColor(ac);c.setFont('Helvetica-Bold',13);c.drawString(42,857,'GROWNIC / AUTOMATION SYSTEMS')
    c.setFont('Helvetica-Bold',56);c.drawRightString(680,824,f'{idx:02}')
    c.setFillColor(HexColor('#F1F4F8'));c.setFont('Helvetica-Bold',29);c.drawString(42,805,title)
    c.setFont('Helvetica',12);c.setFillColor(HexColor('#A9B9CB'));c.drawString(42,779,sub)
    c.setStrokeColor(HexColor('#324152'));c.line(42,756,678,756)
    for j,(name,desc) in enumerate(steps):
        y=648-j*95
        c.setFillColor(HexColor('#152130'));c.setStrokeColor(HexColor('#2F4054'));c.roundRect(42,y,440,77,10,fill=1,stroke=1)
        c.setFillColor(ac);c.circle(65,y+54,12,fill=1,stroke=0);c.setFillColor(HexColor('#0B1018'));c.setFont('Helvetica-Bold',11);c.drawCentredString(65,y+50,str(j+1))
        c.setFillColor(HexColor('#F1F4F8'));c.setFont('Helvetica-Bold',13);c.drawString(88,y+50,name)
        c.setFillColor(HexColor('#B7C5D5'));c.setFont('Helvetica',10.5)
        for k,line in enumerate(wrap(desc,'Helvetica',10.5,365)):c.drawString(88,y+31-k*13,line)
        if j<5:
            c.setStrokeColor(ac);c.line(263,y,263,y-14);p=c.beginPath();p.moveTo(259,y-10);p.lineTo(263,y-16);p.lineTo(267,y-10);c.drawPath(p,stroke=1)
    c.setFillColor(HexColor('#1F2430'));c.setStrokeColor(ac);c.roundRect(509,400,168,190,10,fill=1,stroke=1)
    c.setFillColor(ac);c.setFont('Helvetica-Bold',10);c.drawString(523,567,'EXCEPTION PATH')
    yy=543
    c.setFillColor(HexColor('#F1F4F8'));c.setFont('Helvetica-Bold',12)
    for line in wrap(branch,'Helvetica-Bold',12,138):c.drawString(523,yy,line);yy-=16
    yy-=10;c.setFont('Helvetica',11);c.setFillColor(HexColor('#B7C5D5'))
    for line in wrap(detail,'Helvetica',11,138):c.drawString(523,yy,line);yy-=15
    c.setStrokeColor(ac);c.line(482,515,500,515);c.line(500,515,500,510);c.line(500,510,509,510)
    c.setFillColor(ac);c.setFont('Helvetica-Bold',10);c.drawString(509,346,'SHARED CONTROLS')
    c.setFillColor(HexColor('#B7C5D5'));c.setFont('Helvetica',11)
    for k,line in enumerate(['Authenticated intake','Durable event IDs','Exact-action approval','Consent and local hours','Provider status log','Human recovery queue']):c.drawString(509,322-k*24,line)
    c.setStrokeColor(HexColor('#324152'));c.line(42,129,678,129);c.setFillColor(ac);c.setFont('Helvetica-Bold',10);c.drawString(42,108,'WHAT TO MEASURE')
    c.setFillColor(HexColor('#B7C5D5'));c.setFont('Helvetica',11)
    for k,line in enumerate(wrap(metric,'Helvetica',11,636)):c.drawString(42,89-k*14,line)
    c.setFont('Helvetica',9);c.setFillColor(HexColor('#7E91A7'));c.drawString(42,34,'v1.1.0 / Client configuration and live provider testing required');c.drawRightString(678,34,f'{idx:02} / 10');c.showPage()
c.save();(OUT/'flow-data.json').write_text(json.dumps(data,indent=2))
print(OUT/'Grownic-10-Agent-Flow-Diagrams.pdf')
