begin;

create table fp.feedback_tickets (
 id bigint generated always as identity primary key,
 reporter_id uuid not null,
 household_id uuid references fp.households(id),
 conversation_id uuid references fp.conversations(id) on delete set null,
 request_key text not null,
 title text not null check(length(title) between 1 and 120),
 original_feedback text not null check(length(original_feedback) between 1 and 2000),
 requirements text not null default '' check(length(requirements)<=4000),
 expected_behavior text not null default '' check(length(expected_behavior)<=1000),
 observed_behavior text not null default '' check(length(observed_behavior)<=1000),
 app_version text not null default 'unknown' check(length(app_version)<=80),
 diagnostic_reference uuid,
 status text not null default 'Needs clarification' check(status in ('New','Needs clarification','Ready','In progress','Testing','Ready for release','Released','Blocked','Withdrawn')),
 question text not null default '' check(length(question)<=500),
 latest_update text not null default 'Feedback recorded.' check(length(latest_update)<=1000),
 implementation_branch text, implementation_commit text, validation_reference text, release_reference text,
 attempts integer not null default 0 check(attempts between 0 and 3),
 lease_token uuid, lease_until timestamptz, started_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(reporter_id,request_key)
);
create table fp.feedback_replies (
 id bigint generated always as identity primary key,
 ticket_id bigint not null references fp.feedback_tickets(id),
 request_key text not null,
 body text not null check(length(body) between 1 and 2000),
 created_at timestamptz not null default now(),unique(ticket_id,request_key)
);
alter table fp.feedback_tickets enable row level security;
alter table fp.feedback_tickets force row level security;
alter table fp.feedback_replies enable row level security;
alter table fp.feedback_replies force row level security;
revoke all on fp.feedback_tickets,fp.feedback_replies from public,anon,authenticated;
create index feedback_reporter_recent on fp.feedback_tickets(reporter_id,updated_at desc);
create index feedback_queue on fp.feedback_tickets(status,created_at);

create function fp.feedback_redact(value text) returns text language sql immutable as $$
 select regexp_replace(regexp_replace(left(coalesce(value,''),4000),
 '(?i)(bearer[[:space:]]+|(?:password|token|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*)[^[:space:],;]+','\1[redacted]','g'),
 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+','[redacted token]','g')
$$;

create function fp.feedback_public(t fp.feedback_tickets) returns jsonb language sql stable set search_path=pg_catalog,fp as $$
 select jsonb_build_object('id',t.id::text,'reference','FD-'||t.id,'title',t.title,
 'original_feedback',t.original_feedback,'requirements',t.requirements,'expected_behavior',t.expected_behavior,
 'observed_behavior',t.observed_behavior,'status',t.status,'question',t.question,'latest_update',t.latest_update,
 'created_at',t.created_at,'updated_at',t.updated_at,'can_withdraw',t.started_at is null and t.status not in ('Withdrawn','Released'),
 'implementation_branch',t.implementation_branch,'implementation_commit',t.implementation_commit,
 'validation_reference',t.validation_reference,'release_reference',t.release_reference,
 'replies',coalesce((select jsonb_agg(jsonb_build_object('body',r.body,'created_at',r.created_at) order by r.id) from fp.feedback_replies r where r.ticket_id=t.id),'[]'::jsonb))
$$;

-- Reporter identity comes from the verified gateway JWT, never from request fields.
create function fp.feedback_request(operation text,request_key text default null,message text default null,ticket text default null,conversation uuid default null,app_version text default 'unknown') returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();t fp.feedback_tickets;c fp.conversations;body text;expected text;observed text;question text;hid uuid;ref uuid;result jsonb;
begin
 if uid is null then raise exception 'authentication required' using errcode='42501';end if;
 if operation not in ('create','reply','list','detail','withdraw') then raise exception 'invalid operation' using errcode='22023';end if;
 if operation='list' then return jsonb_build_object('tickets',coalesce((select jsonb_agg(jsonb_build_object('id',x.id::text,'reference','FD-'||x.id,'title',x.title,'status',x.status,'latest_update',left(x.latest_update,120),'updated_at',x.updated_at) order by x.updated_at desc,x.id desc) from (select * from fp.feedback_tickets where reporter_id=uid order by updated_at desc,id desc limit 100)x),'[]'::jsonb));end if;
 if ticket is not null and ticket !~ '^[1-9][0-9]{0,14}$' then raise exception 'invalid ticket' using errcode='22023';end if;
 if operation<>'create' then
   select * into t from fp.feedback_tickets where id=ticket::bigint and reporter_id=uid for update;
   if t.id is null then raise exception 'feedback unavailable' using errcode='PT404';end if;
 end if;
 if operation='detail' then return fp.feedback_public(t);end if;
 if operation='withdraw' then
   if t.started_at is not null or t.status='Released' then raise exception 'feedback already started' using errcode='PT409';end if;
   update fp.feedback_tickets set status='Withdrawn',question='',latest_update='Withdrawn by you.',updated_at=clock_timestamp() where id=t.id returning * into t;
 elsif operation in ('create','reply') then
   if request_key is null or request_key !~ '^[A-Za-z0-9:_-]{8,100}$' or message is null or length(trim(message)) not between 1 and 2000 then raise exception 'invalid feedback' using errcode='22023';end if;
   perform pg_advisory_xact_lock(hashtextextended('feedback:'||uid::text,0));
   body:=fp.feedback_redact(trim(message));
   if operation='create' then
     if message !~* '^(feedback[[:space:]]*:|add (this|that) to (the )?backlog\y|.*\ycreate (a )?feedback ticket\y)' then raise exception 'explicit feedback request required' using errcode='22023';end if;
     select * into t from fp.feedback_tickets x where x.reporter_id=uid and x.request_key=feedback_request.request_key;
     if t.id is not null then return fp.feedback_public(t);end if;
     if (select count(*) from fp.feedback_tickets where reporter_id=uid and created_at>now()-interval '1 day')>=20 then raise exception 'feedback limit reached' using errcode='PT429';end if;
     if conversation is not null then
       select * into c from fp.conversations x where x.id=conversation and x.user_id=uid;
       if c.id is null then raise exception 'conversation unavailable' using errcode='42501';end if;
       hid:=c.household_id;
       select id into ref from fp.conversation_executions where conversation_id=c.id and user_id=uid order by created_at desc limit 1;
     else select household_id into hid from fp.active_family_contexts where user_id=uid;end if;
     if hid is not null and not exists(select 1 from fp.members where user_id=uid and household_id=hid and status='active') then hid:=null;end if;
     expected:=coalesce(substring(body from '(?i)expected:[[:space:]]*([^\n]+)'),'');
     observed:=coalesce(substring(body from '(?i)observed:[[:space:]]*([^\n]+)'),'');
     question:=case when body ~* 'easier to open' then 'Should tapping the document card open it, or would you prefer an Open button?'
       when expected='' then 'What should happen instead, and on which screen?'
       when observed='' then 'What happens now? Please describe the steps to reproduce it.' else '' end;
     insert into fp.feedback_tickets(reporter_id,household_id,conversation_id,request_key,title,original_feedback,expected_behavior,observed_behavior,app_version,diagnostic_reference,status,question)
     values(uid,hid,c.id,request_key,left(trim(regexp_replace(body,'(?i)^feedback[[:space:]]*:[[:space:]]*','')),120),body,left(expected,1000),left(observed,1000),left(regexp_replace(coalesce(app_version,'unknown'),'[^A-Za-z0-9._+-]','','g'),80),ref,case when question='' then 'New' else 'Needs clarification' end,question) returning * into t;
   else
     if exists(select 1 from fp.feedback_replies r where r.ticket_id=t.id and r.request_key=feedback_request.request_key) then return fp.feedback_public(t);end if;
     if t.status not in ('Needs clarification','New') then raise exception 'feedback not awaiting a reply' using errcode='PT409';end if;
     if (select count(*) from fp.feedback_replies where ticket_id=t.id)>=20 then raise exception 'reply limit reached' using errcode='PT429';end if;
     insert into fp.feedback_replies(ticket_id,request_key,body) values(t.id,request_key,body);
     update fp.feedback_tickets set requirements=right(concat_ws(E'\n',nullif(requirements,''),body),4000),status='New',question='',latest_update='Reply received. Awaiting scope and clarity review.',updated_at=clock_timestamp() where id=t.id returning * into t;
   end if;
 end if;
 result:=fp.feedback_public(t);
 if t.conversation_id is not null then
   select * into c from fp.conversations where id=t.conversation_id and user_id=uid;
   if c.id is not null then
     -- Replace the same card. Never append identical progress messages.
     update fp.conversation_messages set content='FD-'||t.id||': '||t.title||E'\n'||t.status||case when t.question<>'' then E'\n'||t.question else '' end,
       message_data=jsonb_build_object('feedback_ticket',result),created_at=created_at
       where conversation_id=c.id and client_message_id='feedback-'||t.id;
     if not found then perform fp.append_authoritative_conversation_message(c,'feedback-'||t.id,'result','Created FD-'||t.id||': '||t.title||case when t.question<>'' then E'\n'||t.question else '' end,jsonb_build_object('feedback_ticket',result));end if;
   end if;
 end if;
 return result;
end $$;

-- Dedicated DB role: no document, identity, deployment or arbitrary SQL authority.
do $$begin if not exists(select 1 from pg_roles where rolname='feedback_runner') then create role feedback_runner nologin;end if;end$$;
grant usage on schema fp to feedback_runner;
grant feedback_runner to authenticator;

create function fp.feedback_claim(worker text,lease_seconds integer default 900) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare t fp.feedback_tickets;
begin
 if worker !~ '^[a-zA-Z0-9_-]{3,80}$' or lease_seconds not between 60 and 1800 then raise exception 'invalid worker' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('feedback-single-runner',0));
 update fp.feedback_tickets set status=case when attempts>=3 then 'Blocked' else 'New' end,lease_token=null,lease_until=null,latest_update='Previous worker stopped. Awaiting a bounded retry.',updated_at=clock_timestamp()
 where lease_until<now() and status in ('In progress','Testing');
 if exists(select 1 from fp.feedback_tickets where lease_until>now()) then return null;end if;
 select * into t from fp.feedback_tickets where status in ('New','Ready') and attempts<3 order by created_at,id for update skip locked limit 1;
 if t.id is null then return null;end if;
 update fp.feedback_tickets set lease_token=gen_random_uuid(),lease_until=now()+make_interval(secs=>lease_seconds),attempts=attempts+1,started_at=coalesce(started_at,now()),status='In progress',latest_update='Checking requirements and scope.',updated_at=clock_timestamp() where id=t.id returning * into t;
 return jsonb_build_object('ticket',fp.feedback_public(t),'lease_token',t.lease_token,'lease_until',t.lease_until);
end $$;
create function fp.feedback_has_work() returns boolean language sql stable security definer set search_path=pg_catalog,fp as $$select exists(select 1 from fp.feedback_tickets where (status in ('New','Ready') and attempts<3) or (lease_until<now() and status in ('In progress','Testing'))) and not exists(select 1 from fp.feedback_tickets where lease_until>now())$$;

create function fp.feedback_worker_result(ticket bigint,lease uuid,new_status text,summary text,question text default '',branch text default null,commit_sha text default null,validation text default null) returns void
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare t fp.feedback_tickets;
begin
 select * into t from fp.feedback_tickets where id=ticket for update;
 if t.id is null or t.lease_token is distinct from lease or t.lease_until<=now() then raise exception 'stale lease' using errcode='PT409';end if;
 if new_status not in ('Needs clarification','Testing','Ready for release','Blocked') or length(summary) not between 1 and 1000 or length(question)>500 then raise exception 'invalid result' using errcode='22023';end if;
 if new_status='Needs clarification' and length(trim(question))<5 then raise exception 'question required' using errcode='22023';end if;
 if new_status='Ready for release' and (commit_sha is null or commit_sha !~ '^[0-9a-f]{40}$' or branch is null or branch !~ '^feedback/FD-[0-9]+-[a-z0-9-]+$' or validation is null or length(validation)<10) then raise exception 'verified evidence required' using errcode='22023';end if;
 update fp.feedback_tickets set status=new_status,latest_update=fp.feedback_redact(summary),question=fp.feedback_redact(feedback_worker_result.question),implementation_branch=branch,implementation_commit=commit_sha,validation_reference=left(fp.feedback_redact(validation),1000),updated_at=clock_timestamp(),lease_token=case when new_status='Testing' then lease_token else null end,lease_until=case when new_status='Testing' then lease_until else null end where id=t.id returning * into t;
 update fp.conversation_messages set content='FD-'||t.id||': '||t.title||E'\n'||t.status||case when t.question<>'' then E'\n'||t.question else '' end,message_data=jsonb_build_object('feedback_ticket',fp.feedback_public(t)) where conversation_id=t.conversation_id and client_message_id='feedback-'||t.id and user_id=t.reporter_id;
end $$;
revoke all on function fp.feedback_redact(text),fp.feedback_public(fp.feedback_tickets),fp.feedback_request(text,text,text,text,uuid,text),fp.feedback_claim(text,integer),fp.feedback_has_work(),fp.feedback_worker_result(bigint,uuid,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function fp.feedback_request(text,text,text,text,uuid,text) to service_role;
grant execute on function fp.feedback_claim(text,integer),fp.feedback_has_work(),fp.feedback_worker_result(bigint,uuid,text,text,text,text,text,text) to feedback_runner;
comment on table fp.feedback_tickets is 'Private reporter feedback; coding runner cannot mark Released. No automatic deployment. Retention: review closed tickets after 180 days; no automatic purge yet.';
commit;
