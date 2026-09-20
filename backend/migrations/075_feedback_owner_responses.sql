begin;

-- PB-07: close the feedback loop without adding a cross-reporter app screen.
-- Only the local, NOLOGIN reviewer role can record owner decisions. Reporters
-- continue to read only their own tickets through feedback_request.

alter table fp.feedback_tickets drop constraint if exists feedback_tickets_status_check;
alter table fp.feedback_tickets add constraint feedback_tickets_status_check check(status in (
  'New','Needs clarification','Accepted','Deferred','Declined','Ready','In progress',
  'Testing','Ready for release','Released','Blocked','Withdrawn'
));

alter table fp.feedback_tickets
  add column if not exists status_changed_at timestamptz not null default now(),
  add column if not exists reporter_seen_at timestamptz not null default now();

create table if not exists fp.feedback_updates (
  id bigint generated always as identity primary key,
  ticket_id bigint not null references fp.feedback_tickets(id) on delete cascade,
  status text not null,
  public_message text not null check(length(public_message) between 1 and 1000),
  release_reference text check(release_reference is null or length(release_reference) between 10 and 1000),
  created_at timestamptz not null default now()
);
alter table fp.feedback_updates enable row level security;
alter table fp.feedback_updates force row level security;
revoke all on fp.feedback_updates from public,anon,authenticated;
create index if not exists feedback_updates_ticket_recent on fp.feedback_updates(ticket_id,created_at desc,id desc);

insert into fp.feedback_updates(ticket_id,status,public_message,created_at)
select id,status,latest_update,updated_at from fp.feedback_tickets t
where not exists(select 1 from fp.feedback_updates u where u.ticket_id=t.id);

create function fp.feedback_public_v2(t fp.feedback_tickets) returns jsonb language sql stable set search_path=pg_catalog,fp as $$
 select jsonb_build_object('id',t.id::text,'reference','FD-'||t.id,'title',t.title,
 'original_feedback',t.original_feedback,'requirements',t.requirements,'expected_behavior',t.expected_behavior,
 'observed_behavior',t.observed_behavior,'status',t.status,'question',t.question,'latest_update',t.latest_update,
 'created_at',t.created_at,'updated_at',t.updated_at,'status_changed_at',t.status_changed_at,
 'unread',t.status_changed_at>t.reporter_seen_at,
 'can_withdraw',t.started_at is null and t.status not in ('Withdrawn','Released','Declined'),
 'implementation_branch',t.implementation_branch,'implementation_commit',t.implementation_commit,
 'validation_reference',t.validation_reference,'release_reference',t.release_reference,
 'updates',coalesce((select jsonb_agg(jsonb_build_object('status',u.status,'message',u.public_message,
   'release_reference',u.release_reference,'created_at',u.created_at) order by u.id)
   from fp.feedback_updates u where u.ticket_id=t.id),'[]'::jsonb),
 'replies',coalesce((select jsonb_agg(jsonb_build_object('body',r.body,'created_at',r.created_at) order by r.id)
   from fp.feedback_replies r where r.ticket_id=t.id),'[]'::jsonb))
$$;

do $$begin
  if not exists(select 1 from pg_roles where rolname='feedback_reviewer') then
    create role feedback_reviewer nologin;
  end if;
end$$;
grant usage on schema fp to feedback_reviewer;

create or replace function fp.feedback_review_list(item_limit integer default 30) returns jsonb
language sql stable security definer set search_path=pg_catalog,fp as $$
 select coalesce(jsonb_agg(fp.feedback_public_v2(t) order by t.created_at,t.id),'[]'::jsonb)
 from (select * from fp.feedback_tickets where status<>'Withdrawn' order by created_at,id limit least(greatest(item_limit,1),100)) t
$$;

create or replace function fp.feedback_record_owner_decision(
  ticket bigint,new_status text,public_message text,release_evidence text default null
) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare t fp.feedback_tickets; clean_message text; clean_release text;
begin
  if new_status not in ('Needs clarification','Accepted','Deferred','Declined','In progress','Testing','Ready for release','Released','Blocked') then
    raise exception 'invalid owner decision' using errcode='22023';
  end if;
  clean_message:=trim(fp.feedback_redact(public_message));
  clean_release:=nullif(trim(fp.feedback_redact(release_evidence)), '');
  if length(clean_message) not between 1 and 1000 then raise exception 'public response required' using errcode='22023';end if;
  if new_status='Needs clarification' and length(clean_message)<5 then raise exception 'clarification question required' using errcode='22023';end if;
  if new_status='Released' and (clean_release is null or length(clean_release)<10) then
    raise exception 'release evidence required' using errcode='22023';
  end if;
  select * into t from fp.feedback_tickets where id=ticket for update;
  if t.id is null then raise exception 'feedback unavailable' using errcode='PT404';end if;
  if t.status='Withdrawn' then raise exception 'feedback withdrawn' using errcode='PT409';end if;
  if t.status='Released' and new_status<>'Released' then raise exception 'released feedback is final' using errcode='PT409';end if;
  update fp.feedback_tickets set status=new_status,question=case when new_status='Needs clarification' then clean_message else '' end,
    latest_update=clean_message,release_reference=case when new_status='Released' then clean_release else release_reference end,
    status_changed_at=clock_timestamp(),updated_at=clock_timestamp(),
    started_at=case when new_status in ('In progress','Testing','Ready for release','Released') then coalesce(started_at,now()) else started_at end,
    lease_token=null,lease_until=null where id=t.id returning * into t;
  insert into fp.feedback_updates(ticket_id,status,public_message,release_reference)
    values(t.id,t.status,clean_message,case when t.status='Released' then clean_release else null end);
  update fp.conversation_messages set content='FD-'||t.id||': '||t.title||E'\n'||t.status||E'\n'||clean_message,
    message_data=jsonb_build_object('feedback_ticket',fp.feedback_public_v2(t))
    where conversation_id=t.conversation_id and client_message_id='feedback-'||t.id and user_id=t.reporter_id;
  return fp.feedback_public_v2(t);
end$$;

revoke all on function fp.feedback_review_list(integer),fp.feedback_record_owner_decision(bigint,text,text,text)
  from public,anon,authenticated;
grant execute on function fp.feedback_review_list(integer),fp.feedback_record_owner_decision(bigint,text,text,text)
  to feedback_reviewer;

create function fp.feedback_request_v2(operation text,request_key text default null,message text default null,ticket text default null,conversation uuid default null,app_version text default 'unknown') returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();t fp.feedback_tickets;c fp.conversations;body text;expected text;observed text;question text;hid uuid;ref uuid;result jsonb;
begin
 if uid is null then raise exception 'authentication required' using errcode='42501';end if;
 if operation not in ('create','reply','list','detail','mark_read','withdraw') then raise exception 'invalid operation' using errcode='22023';end if;
 if operation='list' then return jsonb_build_object('tickets',coalesce((select jsonb_agg(jsonb_build_object(
   'id',x.id::text,'reference','FD-'||x.id,'title',x.title,'status',x.status,'latest_update',left(x.latest_update,120),
   'updated_at',x.updated_at,'unread',x.status_changed_at>x.reporter_seen_at) order by x.updated_at desc,x.id desc)
   from (select * from fp.feedback_tickets where reporter_id=uid order by updated_at desc,id desc limit 100)x),'[]'::jsonb));end if;
 if ticket is not null and ticket !~ '^[1-9][0-9]{0,14}$' then raise exception 'invalid ticket' using errcode='22023';end if;
 if operation<>'create' then
   select * into t from fp.feedback_tickets where id=ticket::bigint and reporter_id=uid for update;
   if t.id is null then raise exception 'feedback unavailable' using errcode='PT404';end if;
 end if;
 if operation='detail' then return fp.feedback_public_v2(t);end if;
 if operation='mark_read' then
   update fp.feedback_tickets set reporter_seen_at=greatest(reporter_seen_at,status_changed_at) where id=t.id returning * into t;
   return fp.feedback_public_v2(t);
 end if;
 if operation='withdraw' then
   if t.started_at is not null or t.status in ('Released','Declined') then raise exception 'feedback already started' using errcode='PT409';end if;
   update fp.feedback_tickets set status='Withdrawn',question='',latest_update='Withdrawn by you.',status_changed_at=clock_timestamp(),updated_at=clock_timestamp() where id=t.id returning * into t;
   insert into fp.feedback_updates(ticket_id,status,public_message) values(t.id,t.status,t.latest_update);
 elsif operation in ('create','reply') then
   if request_key is null or request_key !~ '^[A-Za-z0-9:_-]{8,100}$' or message is null or length(trim(message)) not between 1 and 2000 then raise exception 'invalid feedback' using errcode='22023';end if;
   perform pg_advisory_xact_lock(hashtextextended('feedback:'||uid::text,0));
   body:=fp.feedback_redact(trim(message));
   if operation='create' then
     if message !~* '^(feedback\y|add (this|that) to (the )?backlog\y|.*\ycreate (a )?feedback ticket\y)' then raise exception 'explicit feedback request required' using errcode='22023';end if;
     select * into t from fp.feedback_tickets x where x.reporter_id=uid and x.request_key=feedback_request_v2.request_key;
     if t.id is not null then return fp.feedback_public_v2(t);end if;
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
     values(uid,hid,c.id,request_key,left(trim(regexp_replace(body,'(?i)^feedback\y[[:space:]]*[:-]?[[:space:]]*','')),120),body,left(expected,1000),left(observed,1000),left(regexp_replace(coalesce(app_version,'unknown'),'[^A-Za-z0-9._+-]','','g'),80),ref,case when question='' then 'New' else 'Needs clarification' end,question) returning * into t;
     insert into fp.feedback_updates(ticket_id,status,public_message,created_at) values(t.id,t.status,t.latest_update,t.updated_at);
   else
     if exists(select 1 from fp.feedback_replies r where r.ticket_id=t.id and r.request_key=feedback_request_v2.request_key) then return fp.feedback_public_v2(t);end if;
     if t.status not in ('Needs clarification','New') then raise exception 'feedback not awaiting a reply' using errcode='PT409';end if;
     if (select count(*) from fp.feedback_replies where ticket_id=t.id)>=20 then raise exception 'reply limit reached' using errcode='PT429';end if;
     insert into fp.feedback_replies(ticket_id,request_key,body) values(t.id,request_key,body);
     update fp.feedback_tickets set requirements=right(concat_ws(E'\n',nullif(requirements,''),body),4000),status='New',question='',latest_update='Reply received. Awaiting scope and clarity review.',status_changed_at=clock_timestamp(),updated_at=clock_timestamp() where id=t.id returning * into t;
     insert into fp.feedback_updates(ticket_id,status,public_message) values(t.id,t.status,t.latest_update);
   end if;
 end if;
 result:=fp.feedback_public_v2(t);
 if t.conversation_id is not null then
   select * into c from fp.conversations where id=t.conversation_id and user_id=uid;
   if c.id is not null then
     update fp.conversation_messages set content='FD-'||t.id||': '||t.title||E'\n'||t.status||case when t.question<>'' then E'\n'||t.question else '' end,
       message_data=jsonb_build_object('feedback_ticket',result),created_at=created_at where conversation_id=c.id and client_message_id='feedback-'||t.id;
     if not found then perform fp.append_authoritative_conversation_message(c,'feedback-'||t.id,'result','Created FD-'||t.id||': '||t.title||case when t.question<>'' then E'\n'||t.question else '' end,jsonb_build_object('feedback_ticket',result));end if;
   end if;
 end if;
 return result;
end$$;

revoke all on function fp.feedback_public_v2(fp.feedback_tickets),fp.feedback_request_v2(text,text,text,text,uuid,text)
  from public,anon,authenticated;
grant execute on function fp.feedback_request_v2(text,text,text,text,uuid,text) to service_role;

comment on function fp.feedback_record_owner_decision(bigint,text,text,text) is
  'Manual owner decision writer. Released requires deployment evidence; ticket text cannot invoke it.';

commit;
