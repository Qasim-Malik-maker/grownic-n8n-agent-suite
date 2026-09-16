BEGIN;
CREATE OR REPLACE FUNCTION grownic.due_work() RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE en grownic.enrollments;c grownic.contacts;cfg jsonb;key text;b grownic.objects;hours int;due timestamptz;
BEGIN
 SELECT config INTO cfg FROM grownic.settings WHERE id;
 UPDATE grownic.enrollments SET status='expired' WHERE status='active' AND enrolled_at<now()-make_interval(days=>(cfg->>'followup_max_age_days')::int);
 FOR en IN SELECT * FROM grownic.enrollments WHERE status='active' AND next_due<=now() ORDER BY next_due LIMIT 100 LOOP
 SELECT * INTO c FROM grownic.contacts WHERE contact_key=en.contact_key;IF NOT c.consent OR c.state<>'active' THEN CONTINUE;END IF;
 key:='followup:'||en.contact_key||':'||en.next_touch;
 IF EXISTS(SELECT 1 FROM grownic.outbox WHERE action_key=key) THEN CONTINUE;END IF;
 RETURN NEXT jsonb_build_object('agent','follow-up','event_id',key,'operation','scheduled','contact_key',en.contact_key,'stage',en.stage,'service',en.service,'channel',en.channel,'touch_index',en.next_touch,'action_key',key);
 END LOOP;
 FOR b IN SELECT * FROM grownic.objects WHERE kind='booking' AND data->>'status'='accepted' AND(data->>'start')::timestamptz>now() LOOP
 FOREACH hours IN ARRAY ARRAY[24,2] LOOP due:=(b.data->>'start')::timestamptz-make_interval(hours=>hours);key:='reminder:'||b.object_key||':'||hours;
 IF due<=now() AND due>now()-interval '60 minutes' AND NOT EXISTS(SELECT 1 FROM grownic.outbox WHERE action_key=key) THEN RETURN NEXT jsonb_build_object('agent','follow-up','event_id',key,'operation','reminder','contact_key',b.contact_key,'booking_uid',b.object_key,'start',b.data->>'start','action_key',key);END IF;END LOOP;END LOOP;
END $$;
CREATE OR REPLACE FUNCTION grownic.approved_meta_ad(p_id bigint) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a grownic.outbox;p jsonb;
BEGIN SELECT * INTO a FROM grownic.outbox WHERE id=p_id;IF a.kind<>'meta_creative' OR a.status<>'accepted' THEN RETURN '{}'::jsonb;END IF;
 p:=jsonb_build_object('name',a.metadata->>'ad_name','adset_id',a.metadata->>'adset_id','creative',jsonb_build_object('creative_id',a.provider_id),'status','PAUSED');
 INSERT INTO grownic.outbox(action_key,agent,event_id,kind,payload,payload_hash,status,metadata) VALUES(a.action_key||':paused-ad',a.agent,a.event_id,'meta_ad',p,grownic.hash_payload(p),'needs_review',a.metadata) ON CONFLICT DO NOTHING;RETURN jsonb_build_object('status','paused_ad_needs_review');END $$;
CREATE OR REPLACE FUNCTION grownic.apply_provider_receipt(p jsonb) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE k text;uid text;b jsonb;
BEGIN
 IF p->>'provider'='cal' THEN b:=p->'payload';uid:=b->>'uid';IF coalesce(uid,'')='' THEN RAISE EXCEPTION 'Booking UID required';END IF;
 IF p->>'type'='BOOKING_CANCELLED' THEN INSERT INTO grownic.objects(kind,object_key,data) VALUES('booking',uid,jsonb_build_object('uid',uid,'status','cancelled')) ON CONFLICT(kind,object_key) DO UPDATE SET data=grownic.objects.data||'{"status":"cancelled"}',updated_at=now();UPDATE grownic.outbox SET status='suppressed',last_error='Booking cancelled' WHERE purpose='reminder' AND metadata->>'booking_uid'=uid AND status IN('needs_review','ready');
 ELSIF p->>'type' IN('BOOKING_CREATED','BOOKING_RESCHEDULED') THEN
 SELECT contact_key INTO k FROM grownic.contacts WHERE lower(email)=lower(b->'attendees'->0->>'email');IF k IS NULL THEN RETURN false;END IF;
 IF b->>'rescheduledFromUid' IS NOT NULL THEN UPDATE grownic.objects SET data=data||'{"status":"rescheduled"}' WHERE kind='booking' AND object_key=b->>'rescheduledFromUid';END IF;
 IF lower(coalesce(b->>'status','accepted'))<>'accepted' THEN RETURN true;END IF;
 INSERT INTO grownic.objects(kind,object_key,contact_key,data) VALUES('booking',uid,k,jsonb_build_object('uid',uid,'start',b->>'startTime','status','accepted')) ON CONFLICT(kind,object_key) DO UPDATE SET contact_key=excluded.contact_key,data=CASE WHEN grownic.objects.data->>'status' IN('cancelled','rescheduled') THEN grownic.objects.data ELSE excluded.data END,updated_at=now();PERFORM grownic.contact_event(jsonb_build_object('operation','booked','contact_key',k,'event_id',p->>'event_id'));END IF;
 ELSE
 SELECT contact_key INTO k FROM grownic.outbox WHERE provider_id=p->>'provider_id' AND kind=CASE p->>'provider' WHEN 'resend' THEN 'email' ELSE 'sms' END LIMIT 1;IF NOT FOUND THEN RETURN false;END IF;
 IF p->>'type' IN('email.delivered','delivered') THEN UPDATE grownic.outbox SET status='delivered',updated_at=now() WHERE provider_id=p->>'provider_id' AND status='accepted';
 ELSIF p->>'type' IN('email.bounced','email.complained','undelivered','failed') THEN UPDATE grownic.outbox SET status='bounced',last_error='Provider delivery failure',updated_at=now() WHERE provider_id=p->>'provider_id';PERFORM grownic.contact_event(jsonb_build_object('operation','bounce','contact_key',k,'event_id',p->>'event_id'));END IF;END IF;RETURN true;
END $$;
CREATE OR REPLACE FUNCTION grownic.provider_event(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r grownic.provider_receipts;applied boolean;
BEGIN IF p->>'provider' NOT IN('cal','resend','twilio') OR coalesce(p->>'event_id','')='' THEN RAISE EXCEPTION 'Invalid provider event';END IF;
 INSERT INTO grownic.provider_receipts(provider,event_id,payload) VALUES(p->>'provider',p->>'event_id',p) ON CONFLICT DO NOTHING;SELECT * INTO r FROM grownic.provider_receipts WHERE provider=p->>'provider' AND event_id=p->>'event_id' FOR UPDATE;
 IF r.payload<>p THEN RAISE EXCEPTION 'Provider event ID collision';END IF;IF r.applied_at IS NOT NULL THEN RETURN jsonb_build_object('ok',true,'duplicate',true);END IF;
 applied:=grownic.apply_provider_receipt(p);IF applied THEN UPDATE grownic.provider_receipts SET applied_at=now() WHERE provider=r.provider AND event_id=r.event_id;END IF;INSERT INTO grownic.audit(kind,details) VALUES('provider_event',jsonb_build_object('provider',r.provider,'event_id',r.event_id,'applied',applied));RETURN jsonb_build_object('ok',true,'pending_reconciliation',NOT applied);
END $$;
CREATE OR REPLACE FUNCTION grownic.reconcile_provider_events() RETURNS int LANGUAGE plpgsql AS $$DECLARE r grownic.provider_receipts;n int:=0;BEGIN FOR r IN SELECT * FROM grownic.provider_receipts WHERE applied_at IS NULL ORDER BY received_at FOR UPDATE SKIP LOCKED LIMIT 100 LOOP IF grownic.apply_provider_receipt(r.payload) THEN UPDATE grownic.provider_receipts SET applied_at=now() WHERE provider=r.provider AND event_id=r.event_id;n:=n+1;END IF;END LOOP;RETURN n;END $$;
COMMIT;
