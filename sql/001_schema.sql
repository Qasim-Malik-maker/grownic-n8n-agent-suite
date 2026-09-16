BEGIN;
CREATE SCHEMA IF NOT EXISTS grownic;
CREATE TABLE IF NOT EXISTS grownic.settings(id boolean PRIMARY KEY DEFAULT true CHECK(id),config jsonb NOT NULL);
CREATE TABLE IF NOT EXISTS grownic.contacts(contact_key text PRIMARY KEY,email text,phone text,name text NOT NULL DEFAULT '',timezone text NOT NULL DEFAULT 'UTC',consent boolean NOT NULL DEFAULT false,consent_source text NOT NULL DEFAULT '',state text NOT NULL DEFAULT 'active' CHECK(state IN('active','replied','booked','opted_out','bounced')),updated_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX IF NOT EXISTS grownic_contact_email ON grownic.contacts(lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS grownic_contact_phone ON grownic.contacts(phone) WHERE phone IS NOT NULL;
CREATE TABLE IF NOT EXISTS grownic.events(agent text NOT NULL,event_id text NOT NULL,request jsonb NOT NULL,status text NOT NULL DEFAULT 'processing',result jsonb,usage jsonb,error text,created_at timestamptz NOT NULL DEFAULT now(),lease_until timestamptz NOT NULL DEFAULT now()+interval '5 minutes',PRIMARY KEY(agent,event_id));
CREATE TABLE IF NOT EXISTS grownic.objects(kind text NOT NULL,object_key text NOT NULL,contact_key text,data jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(kind,object_key));
CREATE TABLE IF NOT EXISTS grownic.prospects(domain text PRIMARY KEY,email text NOT NULL UNIQUE,company text NOT NULL,data jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS grownic.outbox(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,action_key text NOT NULL UNIQUE,agent text NOT NULL,event_id text NOT NULL,kind text NOT NULL CHECK(kind IN('manual','email','sms','hubspot_contact','cal_book','cal_cancel','cal_reschedule','publora_post','meta_creative','meta_ad')),contact_key text,purpose text NOT NULL DEFAULT 'transactional',payload jsonb NOT NULL,payload_hash text NOT NULL,status text NOT NULL CHECK(status IN('needs_review','ready','sending','accepted','simulated','rejected','suppressed','failed','unknown','delivered','bounced')),metadata jsonb NOT NULL DEFAULT '{}',due_at timestamptz NOT NULL DEFAULT now(),attempts int NOT NULL DEFAULT 0,first_attempt_at timestamptz,lease_token text,lease_until timestamptz,provider_id text,response jsonb,last_error text,created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS grownic_due ON grownic.outbox(status,due_at);
CREATE TABLE IF NOT EXISTS grownic.audit(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,at timestamptz NOT NULL DEFAULT now(),action_id bigint,kind text NOT NULL,actor text NOT NULL DEFAULT 'system',details jsonb NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS grownic.enrollments(contact_key text PRIMARY KEY REFERENCES grownic.contacts(contact_key),enrolled_at timestamptz NOT NULL DEFAULT now(),stage text NOT NULL,service text NOT NULL,channel text NOT NULL,next_touch int NOT NULL DEFAULT 0,status text NOT NULL DEFAULT 'active',next_due timestamptz NOT NULL);
CREATE TABLE IF NOT EXISTS grownic.knowledge(id text PRIMARY KEY,title text NOT NULL,question text NOT NULL,answer text NOT NULL,source_url text NOT NULL,approved boolean NOT NULL DEFAULT false,expires_at timestamptz,search tsvector GENERATED ALWAYS AS(to_tsvector('english',title||' '||question||' '||answer)) STORED,updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS grownic_kb_search ON grownic.knowledge USING gin(search);
CREATE TABLE IF NOT EXISTS grownic.failures(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,at timestamptz NOT NULL DEFAULT now(),workflow text,execution_id text,message text);
CREATE TABLE IF NOT EXISTS grownic.provider_receipts(provider text NOT NULL,event_id text NOT NULL,payload jsonb NOT NULL,received_at timestamptz NOT NULL DEFAULT now(),applied_at timestamptz,PRIMARY KEY(provider,event_id));
CREATE OR REPLACE FUNCTION grownic.hash_payload(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT encode(sha256(convert_to(p::text,'UTF8')),'hex') $$;
CREATE OR REPLACE FUNCTION grownic.contact_event(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE s text;keys text[];n int;
BEGIN
 s:=CASE p->>'operation' WHEN 'reply' THEN 'replied' WHEN 'optout' THEN 'opted_out' WHEN 'booked' THEN 'booked' WHEN 'bounce' THEN 'bounced' END;
 IF s IS NULL THEN RAISE EXCEPTION 'Unsupported inbound event';END IF;
 SELECT array_agg(contact_key) INTO keys FROM grownic.contacts WHERE contact_key=p->>'contact_key' OR email=p->>'contact_key' OR phone=p->>'contact_key';
 UPDATE grownic.contacts SET state=CASE WHEN state IN('opted_out','bounced') THEN state ELSE s END,consent=CASE WHEN s IN('opted_out','bounced') THEN false ELSE consent END,updated_at=now() WHERE contact_key=ANY(keys);GET DIAGNOSTICS n=ROW_COUNT;
 UPDATE grownic.enrollments SET status='stopped' WHERE contact_key=ANY(keys);
 UPDATE grownic.outbox SET status='suppressed',last_error='Inbound '||s,updated_at=now() WHERE contact_key=ANY(keys) AND status IN('needs_review','ready') AND (purpose='followup' OR s IN('opted_out','bounced'));
 INSERT INTO grownic.audit(kind,details) VALUES('contact_'||s,p||jsonb_build_object('matched',n));RETURN jsonb_build_object('ok',true,'matched',n,'state',s);
END $$;
CREATE OR REPLACE FUNCTION grownic.begin_event(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE cfg jsonb;e grownic.events;c grownic.contacts;incoming jsonb;k text;fresh boolean;docs jsonb;related jsonb;
BEGIN
 SELECT config INTO cfg FROM grownic.settings WHERE id;IF cfg IS NULL OR coalesce(cfg->>'mode','') NOT IN('test','live') THEN RAISE EXCEPTION 'Valid client configuration required';END IF;
 incoming:=p->'contact';k:=p->>'contact_key';
 IF incoming IS NOT NULL THEN
   IF(SELECT count(*) FROM grownic.contacts WHERE email=nullif(incoming->>'email','') OR phone=nullif(incoming->>'phone',''))>1 THEN RAISE EXCEPTION 'Contact identity collision; human resolution required';END IF;
   SELECT contact_key INTO k FROM grownic.contacts WHERE email=nullif(incoming->>'email','') OR phone=nullif(incoming->>'phone','') LIMIT 1;
   k:=coalesce(k,p->>'contact_key');p:=p||jsonb_build_object('contact_key',k);
 END IF;
 INSERT INTO grownic.events(agent,event_id,request) VALUES(p->>'agent',p->>'event_id',p) ON CONFLICT DO NOTHING;fresh:=FOUND;
 SELECT * INTO e FROM grownic.events WHERE agent=p->>'agent' AND event_id=p->>'event_id' FOR UPDATE;
 IF e.request<>p THEN RETURN jsonb_build_object('proceed',false,'http_code',409,'result',jsonb_build_object('error','event_id reused with different payload'));END IF;
 IF NOT fresh THEN RETURN jsonb_build_object('proceed',false,'duplicate',true,'http_code',CASE WHEN e.status='completed' THEN 200 ELSE 202 END,'result',coalesce(e.result,jsonb_build_object('status',e.status,'recovery','Inspect existing actions before submitting a new event ID')));END IF;
 IF incoming IS NOT NULL AND k IS NOT NULL THEN
 INSERT INTO grownic.contacts(contact_key,email,phone,name,timezone,consent,consent_source) VALUES(k,nullif(incoming->>'email',''),nullif(incoming->>'phone',''),coalesce(incoming->>'name',''),coalesce(nullif(incoming->>'timezone',''),cfg->>'timezone','UTC'),coalesce((incoming->>'consent')::boolean,false),coalesce(incoming->>'consent_source',''))
 ON CONFLICT(contact_key) DO UPDATE SET name=CASE WHEN excluded.name<>'' THEN excluded.name ELSE grownic.contacts.name END,email=coalesce(grownic.contacts.email,excluded.email),phone=coalesce(grownic.contacts.phone,excluded.phone),timezone=coalesce(nullif(incoming->>'timezone',''),grownic.contacts.timezone),consent=CASE WHEN grownic.contacts.state='active' AND excluded.consent THEN true ELSE grownic.contacts.consent END,consent_source=CASE WHEN grownic.contacts.state='active' AND NOT grownic.contacts.consent AND excluded.consent THEN excluded.consent_source ELSE grownic.contacts.consent_source END,updated_at=now();END IF;
 SELECT * INTO c FROM grownic.contacts WHERE contact_key=k;
 SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]') INTO docs FROM(SELECT id,title,question,answer,source_url FROM grownic.knowledge WHERE approved AND(expires_at IS NULL OR expires_at>now()) ORDER BY ts_rank_cd(search,plainto_tsquery('english',coalesce(p->>'question',''))) DESC,updated_at DESC LIMIT 20)t;
 SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]') INTO related FROM(SELECT kind,object_key,data FROM grownic.objects WHERE contact_key=k AND kind IN('booking','quote') ORDER BY updated_at DESC LIMIT 20)t;
 RETURN jsonb_build_object('proceed',true,'request',p,'cfg',cfg,'contact',CASE WHEN c.contact_key IS NULL THEN incoming ELSE to_jsonb(c) END,'knowledge',docs,'related',related,'now',now());
END $$;
CREATE OR REPLACE FUNCTION grownic.commit_plan(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE cfg jsonb;e grownic.events;a jsonb;r jsonb;st text;n bigint;domains text[]:=ARRAY[]::text[];answer jsonb;
BEGIN
 SELECT * INTO e FROM grownic.events WHERE agent=p->>'agent' AND event_id=p->>'event_id' FOR UPDATE;IF e.agent IS NULL THEN RAISE EXCEPTION 'Event not claimed';END IF;IF e.status='completed' THEN RETURN e.result;END IF;
 SELECT config INTO cfg FROM grownic.settings WHERE id;
 IF jsonb_array_length(coalesce(p->'actions','[]'))>30 THEN RAISE EXCEPTION 'Action budget exceeded';END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(coalesce(p->'records','[]')) LOOP
 IF r->>'kind'='prospect' THEN INSERT INTO grownic.prospects(domain,email,company,data) VALUES(r->>'key',r->'data'->>'email',r->'data'->>'company',r->'data') ON CONFLICT DO NOTHING;IF NOT FOUND THEN CONTINUE;END IF;domains:=array_append(domains,r->>'key');END IF;
 INSERT INTO grownic.objects(kind,object_key,contact_key,data) VALUES(r->>'kind',r->>'key',p->>'contact_key',r->'data') ON CONFLICT(kind,object_key) DO UPDATE SET data=excluded.data,updated_at=now();END LOOP;
 FOR a IN SELECT * FROM jsonb_array_elements(coalesce(p->'actions','[]')) LOOP
 IF a->>'kind'='hubspot_contact' AND NOT(a->'metadata'->>'domain'=ANY(domains)) THEN CONTINUE;END IF;
 st:=CASE WHEN coalesce((a->>'review_required')::boolean,true) THEN 'needs_review' WHEN cfg->>'mode'='test' THEN 'simulated' ELSE 'ready' END;
 INSERT INTO grownic.outbox(action_key,agent,event_id,kind,contact_key,purpose,payload,payload_hash,status,metadata,due_at) VALUES(a->>'action_key',p->>'agent',p->>'event_id',a->>'kind',coalesce(a->>'contact_key',p->>'contact_key'),coalesce(a->>'purpose','transactional'),a->'payload',grownic.hash_payload(a->'payload'),st,coalesce(a->'metadata','{}'),coalesce((a->>'due_at')::timestamptz,now())) ON CONFLICT(action_key) DO NOTHING RETURNING id INTO n;
 IF n IS NOT NULL THEN INSERT INTO grownic.audit(action_id,kind,details) VALUES(n,'action_created',jsonb_build_object('status',st));END IF;END LOOP;
 IF p->'enroll' IS NOT NULL THEN INSERT INTO grownic.enrollments(contact_key,stage,service,channel,next_due) SELECT p->>'contact_key',p->'enroll'->>'stage',p->'enroll'->>'service',p->'enroll'->>'channel',now()+make_interval(days=>(cfg->'followup_days'->>0)::int) WHERE EXISTS(SELECT 1 FROM grownic.contacts WHERE contact_key=p->>'contact_key' AND consent AND state='active') ON CONFLICT DO NOTHING;END IF;
 IF p->>'agent'='follow-up' AND p->'result'->>'status'='contact_event' THEN PERFORM grownic.contact_event(jsonb_build_object('contact_key',p->>'contact_key','operation',p->'result'->>'operation','event_id',p->>'event_id'));END IF;
 answer:=coalesce(p->'result','{}')||jsonb_build_object('event_id',p->>'event_id','mode',cfg->>'mode','new_prospect_domains',to_jsonb(domains),'actions',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'kind',kind,'status',status,'payload_hash',payload_hash)) FROM grownic.outbox WHERE agent=p->>'agent' AND event_id=p->>'event_id'),'[]'));
 UPDATE grownic.events SET status='completed',result=answer,usage=coalesce(p->'usage','{}') WHERE agent=p->>'agent' AND event_id=p->>'event_id';RETURN answer;
END $$;
CREATE OR REPLACE FUNCTION grownic.review_action(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a grownic.outbox;cfg jsonb;st text;
BEGIN
 SELECT * INTO a FROM grownic.outbox WHERE id=(p->>'action_id')::bigint FOR UPDATE;
 IF a.id IS NULL OR a.status<>'needs_review' THEN RETURN jsonb_build_object('ok',false,'error','Action missing or already handled');END IF;
 IF a.payload_hash IS DISTINCT FROM p->>'expected_hash' OR a.payload_hash<>grownic.hash_payload(a.payload) THEN RETURN jsonb_build_object('ok',false,'error','Payload changed; refresh approval');END IF;
 IF p->>'decision' NOT IN('approve','reject') THEN RAISE EXCEPTION 'Invalid decision';END IF;
 SELECT config INTO cfg FROM grownic.settings WHERE id;st:=CASE WHEN p->>'decision'='reject' THEN 'rejected' WHEN cfg->>'mode'='test' THEN 'simulated' WHEN a.kind='manual' THEN 'accepted' ELSE 'ready' END;
 UPDATE grownic.outbox SET status=st,updated_at=now() WHERE id=a.id;
 IF st='rejected' AND a.purpose='followup' THEN UPDATE grownic.enrollments SET status='stopped' WHERE contact_key=a.contact_key;END IF;
 INSERT INTO grownic.audit(action_id,kind,actor,details) VALUES(a.id,'review_'||(p->>'decision'),'authenticated_owner',jsonb_build_object('comment',left(coalesce(p->>'comment',''),4000),'payload_hash',a.payload_hash));RETURN jsonb_build_object('ok',true,'status',st,'id',a.id);
END $$;
CREATE OR REPLACE FUNCTION grownic.allowed(a grownic.outbox,cfg jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE c grownic.contacts;local_now timestamp;
BEGIN
 IF cfg->>'mode'<>'live' OR NOT coalesce((cfg->>'outbound_enabled')::boolean,false) THEN RETURN 'Outbound paused';END IF;
 IF a.payload_hash<>grownic.hash_payload(a.payload) THEN RETURN 'Payload changed after approval';END IF;
 SELECT * INTO c FROM grownic.contacts WHERE contact_key=a.contact_key;
 IF a.kind IN('email','sms','cal_book') AND(c.contact_key IS NULL OR NOT c.consent OR c.state IN('opted_out','bounced')) THEN RETURN 'Consent/contact does not permit action';END IF;
 IF a.purpose='followup' AND(c.state<>'active' OR NOT EXISTS(SELECT 1 FROM grownic.enrollments WHERE contact_key=a.contact_key AND status='active')) THEN RETURN 'Follow-up stopped';END IF;
 IF a.kind='cal_book' AND(a.payload->>'start')::timestamptz<=now() THEN RETURN 'Appointment time has passed';END IF;
 IF a.kind IN('cal_cancel','cal_reschedule') AND NOT EXISTS(SELECT 1 FROM grownic.objects WHERE kind='booking' AND object_key=a.metadata->>'booking_uid' AND contact_key=a.contact_key AND data->>'status'='accepted') THEN RETURN 'Booking ownership/state changed';END IF;
 IF a.purpose='reminder' AND NOT EXISTS(SELECT 1 FROM grownic.objects WHERE kind='booking' AND object_key=a.metadata->>'booking_uid' AND data->>'status'='accepted' AND(data->>'start')::timestamptz>now()) THEN RETURN 'Booking changed or passed';END IF;
 IF a.kind IN('email','sms') THEN local_now:=now() AT TIME ZONE c.timezone;IF NOT(extract(isodow FROM local_now)::int IN(SELECT jsonb_array_elements_text(cfg->'send_window'->'weekdays')::int)) OR extract(hour FROM local_now)<(cfg->'send_window'->>'start_hour')::int OR extract(hour FROM local_now)>=(cfg->'send_window'->>'end_hour')::int THEN RETURN 'Outside send window';END IF;END IF;
 RETURN NULL;
END $$;
CREATE OR REPLACE FUNCTION grownic.claim_actions(p_limit int DEFAULT 1,p_agent text DEFAULT NULL,p_event text DEFAULT NULL) RETURNS SETOF jsonb LANGUAGE plpgsql AS $$
DECLARE cfg jsonb;a grownic.outbox;c grownic.contacts;why text;counted int:=0;cap int;
BEGIN
 SELECT config INTO cfg FROM grownic.settings WHERE id;IF cfg->>'mode'<>'live' OR NOT coalesce((cfg->>'outbound_enabled')::boolean,false) THEN RETURN;END IF;
 PERFORM pg_advisory_xact_lock(7140914);
 cap:=least(p_limit,greatest(0,(cfg->>'max_actions_per_day')::int-(SELECT count(*)::int FROM grownic.outbox WHERE first_attempt_at>=date_trunc('day',now()))),greatest(0,(cfg->>'max_actions_per_minute')::int-(SELECT count(*)::int FROM grownic.outbox WHERE updated_at>now()-interval '1 minute' AND status IN('sending','accepted','delivered','unknown'))));
 FOR a IN SELECT * FROM grownic.outbox WHERE status='ready' AND due_at<=now() AND kind<>'manual' AND(p_agent IS NULL OR agent=p_agent) AND(p_event IS NULL OR event_id=p_event) ORDER BY due_at,id FOR UPDATE SKIP LOCKED LIMIT 100 LOOP
 EXIT WHEN counted>=cap;why:=grownic.allowed(a,cfg);IF why='Outside send window' THEN CONTINUE;END IF;
 IF why IS NOT NULL THEN UPDATE grownic.outbox SET status='suppressed',last_error=why,updated_at=now() WHERE id=a.id;CONTINUE;END IF;
 UPDATE grownic.outbox SET status='sending',attempts=attempts+1,first_attempt_at=coalesce(first_attempt_at,now()),lease_token=md5(random()::text||clock_timestamp()::text||id),lease_until=now()+interval '2 minutes',updated_at=now() WHERE id=a.id RETURNING * INTO a;SELECT * INTO c FROM grownic.contacts WHERE contact_key=a.contact_key;counted:=counted+1;RETURN NEXT to_jsonb(a)||jsonb_build_object('cfg',cfg,'contact',to_jsonb(c));END LOOP;
END $$;
CREATE OR REPLACE FUNCTION grownic.preflight_action(p_id bigint,p_lease text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a grownic.outbox;cfg jsonb;c grownic.contacts;why text;
BEGIN
 SELECT * INTO a FROM grownic.outbox WHERE id=p_id FOR UPDATE;IF a.id IS NULL OR a.status<>'sending' OR a.lease_token IS DISTINCT FROM p_lease OR a.lease_until<=now() THEN RETURN jsonb_build_object('send',false,'reason','Lease not owned');END IF;
 SELECT config INTO cfg FROM grownic.settings WHERE id;why:=grownic.allowed(a,cfg);
 IF why IS NOT NULL THEN UPDATE grownic.outbox SET status=CASE WHEN why='Outside send window' THEN 'ready' ELSE 'suppressed' END,last_error=why,lease_until=NULL,updated_at=now() WHERE id=a.id;INSERT INTO grownic.audit(action_id,kind,details) VALUES(a.id,'preflight_held',jsonb_build_object('reason',why));RETURN jsonb_build_object('send',false,'reason',why);END IF;
 SELECT * INTO c FROM grownic.contacts WHERE contact_key=a.contact_key;RETURN to_jsonb(a)||jsonb_build_object('send',true,'cfg',cfg,'contact',to_jsonb(c));
END $$;
CREATE OR REPLACE FUNCTION grownic.finish_action(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a grownic.outbox;cfg jsonb;en grownic.enrollments;idx int;d jsonb;
BEGIN
 SELECT * INTO a FROM grownic.outbox WHERE id=(p->>'id')::bigint FOR UPDATE;IF a.id IS NULL OR a.status<>'sending' OR a.lease_token IS DISTINCT FROM p->>'lease_token' THEN RETURN jsonb_build_object('ok',false,'error','Lease no longer owned');END IF;
 IF p->>'status' NOT IN('accepted','ready','failed','unknown') THEN RAISE EXCEPTION 'Invalid outcome';END IF;
 UPDATE grownic.outbox SET status=p->>'status',provider_id=p->>'provider_id',response=coalesce(p->'response','{}'),last_error=p->>'error',lease_until=NULL,due_at=CASE WHEN p->>'status'='ready' THEN now()+make_interval(secs=>least(3600,30*power(2,least(attempts,7))::int)) ELSE due_at END,updated_at=now() WHERE id=a.id;
 INSERT INTO grownic.audit(action_id,kind,details) VALUES(a.id,'delivery_'||(p->>'status'),jsonb_build_object('provider_id',p->>'provider_id','error',p->>'error'));SELECT config INTO cfg FROM grownic.settings WHERE id;
 IF p->>'status'='accepted' AND a.kind IN('cal_book','cal_reschedule') THEN
   IF a.kind='cal_reschedule' THEN UPDATE grownic.objects SET data=data||'{"status":"rescheduled"}',updated_at=now() WHERE kind='booking' AND object_key=a.metadata->>'booking_uid';END IF;
   d:=jsonb_build_object('uid',p->>'provider_id','start',a.payload->>'start','status','accepted');INSERT INTO grownic.objects(kind,object_key,contact_key,data) VALUES('booking',p->>'provider_id',a.contact_key,d) ON CONFLICT(kind,object_key) DO UPDATE SET data=CASE WHEN grownic.objects.data->>'status' IN('cancelled','rescheduled') THEN grownic.objects.data ELSE excluded.data END,updated_at=now();
   PERFORM grownic.contact_event(jsonb_build_object('operation','booked','contact_key',a.contact_key,'event_id',a.event_id));
 END IF;
 IF p->>'status'='accepted' AND a.kind='cal_cancel' THEN UPDATE grownic.objects SET data=data||'{"status":"cancelled"}',updated_at=now() WHERE kind='booking' AND object_key=a.metadata->>'booking_uid';END IF;
 IF p->>'status'='accepted' AND a.purpose='followup' THEN SELECT * INTO en FROM grownic.enrollments WHERE contact_key=a.contact_key FOR UPDATE;idx:=en.next_touch+1;UPDATE grownic.enrollments SET next_touch=idx,status=CASE WHEN idx>=jsonb_array_length(cfg->'followup_days') THEN 'completed' ELSE status END,next_due=CASE WHEN idx<jsonb_array_length(cfg->'followup_days') THEN greatest(now()+interval '1 day',en.enrolled_at+make_interval(days=>(cfg->'followup_days'->>idx)::int)) ELSE next_due END WHERE contact_key=a.contact_key;END IF;
 RETURN jsonb_build_object('ok',true,'id',a.id,'status',p->>'status');
END $$;
CREATE OR REPLACE FUNCTION grownic.recover_leases() RETURNS int LANGUAGE plpgsql AS $$DECLARE n int;BEGIN UPDATE grownic.outbox SET status=CASE WHEN kind='email' AND first_attempt_at>now()-interval '23 hours' AND attempts<5 THEN 'ready' ELSE 'unknown' END,last_error='Expired lease; reconcile before retry',lease_until=NULL,updated_at=now() WHERE status='sending' AND lease_until<now();GET DIAGNOSTICS n=ROW_COUNT;UPDATE grownic.events SET status='failed',error='Processing lease expired' WHERE status='processing' AND lease_until<now();RETURN n;END $$;
CREATE OR REPLACE VIEW grownic.review_queue AS SELECT id,agent,kind,contact_key,payload,payload_hash,status,created_at FROM grownic.outbox WHERE status='needs_review';
CREATE OR REPLACE VIEW grownic.health AS SELECT status,count(*) AS actions,min(created_at) AS oldest FROM grownic.outbox GROUP BY status;
COMMIT;
