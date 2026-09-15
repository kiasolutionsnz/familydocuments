begin;

-- Keep the server's explicit-intent check aligned with the client. A dash is
-- a common alternative to a colon in a typed "Feedback - ..." request.
create or replace function fp.feedback_request(operation text,request_key text default null,message text default null,ticket text default null,conversation uuid default null,app_version text default 'unknown') returns jsonb
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
     if message !~* '^(feedback[[:space:]]*[:-]|add (this|that) to (the )?backlog\y|.*\ycreate (a )?feedback ticket\y)' then raise exception 'explicit feedback request required' using errcode='22023';end if;
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
     values(uid,hid,c.id,request_key,left(trim(regexp_replace(body,'(?i)^feedback[[:space:]]*[:-][[:space:]]*','')),120),body,left(expected,1000),left(observed,1000),left(regexp_replace(coalesce(app_version,'unknown'),'[^A-Za-z0-9._+-]','','g'),80),ref,case when question='' then 'New' else 'Needs clarification' end,question) returning * into t;
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
     update fp.conversation_messages set content='FD-'||t.id||': '||t.title||E'\n'||t.status||case when t.question<>'' then E'\n'||t.question else '' end,
       message_data=jsonb_build_object('feedback_ticket',result),created_at=created_at
       where conversation_id=c.id and client_message_id='feedback-'||t.id;
     if not found then perform fp.append_authoritative_conversation_message(c,'feedback-'||t.id,'result','Created FD-'||t.id||': '||t.title||case when t.question<>'' then E'\n'||t.question else '' end,jsonb_build_object('feedback_ticket',result));end if;
   end if;
 end if;
 return result;
end $$;

revoke all on function fp.feedback_request(text,text,text,text,uuid,text) from public,anon,authenticated;
grant execute on function fp.feedback_request(text,text,text,text,uuid,text) to service_role;
commit;
