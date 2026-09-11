begin;

-- Recompile the strict validator without the legacy PL/pgSQL `value` variable,
-- which conflicted with jsonb_array_elements' output when choices were used.
create or replace function fp.assert_conversation_action_v1(action_type text,parameters jsonb) returns void
language plpgsql immutable set search_path=pg_catalog,fp as $$
declare allowed text[];required text[];key text;choice jsonb;
begin
  if jsonb_typeof(parameters)<>'object' or octet_length(parameters::text)>8192 then raise exception 'invalid action parameters' using errcode='22023';end if;
  case action_type
    when 'search_family_content' then allowed:=array['query'];required:=allowed;
    when 'save_document' then allowed:=array['attachment_id','category_name','tags','create_category'];required:=array['attachment_id','category_name'];
    when 'request_document_ocr' then allowed:=array['attachment_id','document_id','mode'];required:=array['mode'];
    when 'update_document_category' then allowed:=array['document_id','category_name','expected_updated_at','ambiguous'];required:=array['document_id','category_name'];
    when 'update_document_tags' then allowed:=array['document_id','tags','operation','expected_updated_at'];required:=array['document_id','tags','operation'];
    when 'create_reminder' then allowed:=array['title','due_date','due_time','document_id'];required:=array['title','due_date'];
    when 'update_reminder' then allowed:=array['reminder_id','operation','expected_due_date','due_date','due_time','recurrence'];required:=array['reminder_id','operation','expected_due_date'];
    when 'save_link' then allowed:=array['url','title','category_name','create_category'];required:=array['url','category_name'];
    when 'mark_inbox_reviewed','dismiss_inbox_item' then allowed:=array['inbox_id','expected_updated_at'];required:=array['inbox_id'];
    when 'open_app_destination' then allowed:=array['destination','result_index'];required:=array['destination'];
    when 'request_clarification' then allowed:=array['question','missing_parameter','choices','choice_actions','attachment_id','tags','link_url','link_title'];required:=array['question','missing_parameter'];
    when 'unsupported_request' then allowed:=array['reason'];required:=array[]::text[];
    else raise exception 'unknown conversation action' using errcode='22023';
  end case;
  for key in select jsonb_object_keys(parameters) loop if not key=any(allowed) then raise exception 'unknown action property' using errcode='22023';end if;end loop;
  foreach key in array required loop if not parameters?key or jsonb_typeof(parameters->key)='null' or (jsonb_typeof(parameters->key)='string' and trim(parameters->>key)='') then raise exception 'missing action property: %',key using errcode='22023';end if;end loop;
  foreach key in array array['attachment_id','document_id','reminder_id','inbox_id'] loop if parameters?key and parameters->>key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then raise exception 'malformed identifier' using errcode='22023';end if;end loop;
  if parameters?'tags' and (jsonb_typeof(parameters->'tags')<>'array' or jsonb_array_length(parameters->'tags')>12 or exists(select 1 from jsonb_array_elements_text(parameters->'tags') t where char_length(trim(t)) not between 1 and 40)) then raise exception 'invalid tags' using errcode='22023';end if;
  if parameters?'choices' and (jsonb_typeof(parameters->'choices')<>'array' or jsonb_array_length(parameters->'choices')>3 or exists(select 1 from jsonb_array_elements_text(parameters->'choices') t where char_length(trim(t)) not between 1 and 100)) then raise exception 'invalid choices' using errcode='22023';end if;
  if parameters?'choice_actions' and (jsonb_typeof(parameters->'choice_actions')<>'array' or jsonb_array_length(parameters->'choice_actions')>3) then raise exception 'invalid choice actions' using errcode='22023';end if;
  if parameters?'choice_actions' then
    for choice in select element from jsonb_array_elements(parameters->'choice_actions') as choices(element) loop
      if jsonb_typeof(choice)<>'object' or (select count(*) from jsonb_object_keys(choice))<>4 or not choice ?& array['id','parameters','type','version'] or (choice->>'version')::integer<>1 or choice->>'type' in ('request_clarification','request_confirmation') then raise exception 'invalid choice action' using errcode='22023';end if;
      perform fp.assert_conversation_action_v1(choice->>'type',choice->'parameters');
    end loop;
  end if;
  if action_type='request_document_ocr' and not(parameters?'attachment_id' or parameters?'document_id') then raise exception 'reading target required' using errcode='22023';end if;
  if action_type='request_document_ocr' and parameters->>'mode' not in ('document','invoice') then raise exception 'invalid reading mode' using errcode='22023';end if;
  if action_type='update_document_tags' and parameters->>'operation' not in ('add','remove') then raise exception 'invalid tag operation' using errcode='22023';end if;
  if action_type='update_reminder' and parameters->>'operation'<>'one_week_before' then raise exception 'invalid reminder operation' using errcode='22023';end if;
  if action_type='open_app_destination' and parameters->>'destination' not in ('home','timeline','library','inbox','reminders') then raise exception 'invalid destination' using errcode='22023';end if;
  if action_type='save_link' then perform fp.normalise_saved_link_url(parameters->>'url');end if;
  if parameters?'due_date' then perform (parameters->>'due_date')::date;end if;
  if parameters?'expected_due_date' then perform (parameters->>'expected_due_date')::date;end if;
  if parameters?'due_time' then perform (parameters->>'due_time')::time;end if;
  if parameters?'expected_updated_at' then perform (parameters->>'expected_updated_at')::timestamptz;end if;
end$$;

create or replace function fp.enrich_conversation_clarification_message() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare execution fp.conversation_executions;
begin
  if new.role='assistant' and new.kind='clarification' and new.message_data->'action'->>'id' is not null then
    select * into execution from fp.conversation_executions e
      where e.conversation_id=new.conversation_id and e.action_id=new.message_data->'action'->>'id'
      order by e.created_at desc limit 1;
    if execution.id is not null then
      new.message_data:=new.message_data||jsonb_build_object(
        'clarification_id',execution.id,
        'choices',coalesce(execution.action_parameters->'choices','[]'::jsonb),
        'choice_actions',coalesce(execution.action_parameters->'choice_actions','[]'::jsonb)
      );
    end if;
  end if;
  return new;
end$$;

drop trigger if exists enrich_conversation_clarification_message on fp.conversation_messages;
create trigger enrich_conversation_clarification_message before insert on fp.conversation_messages
for each row execute function fp.enrich_conversation_clarification_message();

create or replace function fp.submit_conversation_reminder_query(
  conversation uuid,
  action_id text,
  action_version integer,
  parameters jsonb,
  request_key text
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  current fp.conversations;
  existing fp.conversation_executions;
  execution fp.conversation_executions;
  uid uuid:=fp.current_user_id();
  hid uuid;
  local_today date:=(now() at time zone 'Pacific/Auckland')::date;
  scope text;
  requested_date date;
  results jsonb;
  answer jsonb;
  digest text;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  hid:=current.household_id;
  if action_version<>1 or action_id !~ '^[A-Za-z0-9:_-]{8,100}$' or request_key !~ '^[A-Za-z0-9:_-]{8,100}$'
    or jsonb_typeof(parameters)<>'object' or exists(select 1 from jsonb_object_keys(parameters) key where key not in ('scope','date'))
    or not parameters?'scope' then raise exception 'invalid reminder query' using errcode='22023';end if;
  scope:=parameters->>'scope';
  if scope not in ('today','tomorrow','upcoming','overdue','date') then raise exception 'invalid reminder scope' using errcode='22023';end if;
  if scope='date' then
    if not parameters?'date' then raise exception 'date is required' using errcode='22023';end if;
    requested_date:=(parameters->>'date')::date;
  elsif parameters?'date' then raise exception 'unexpected reminder date' using errcode='22023';
  end if;
  digest:=fp.conversation_action_digest('query_reminders',action_version,parameters);
  select * into existing from fp.conversation_executions e where e.household_id=hid and e.user_id=uid and e.request_key=submit_conversation_reminder_query.request_key for update;
  if existing.id is not null then
    if existing.action_digest<>digest then raise exception 'idempotency key reused for different action' using errcode='PT409';end if;
    return fp.conversation_execution_public(existing)||jsonb_build_object('duplicate',true);
  end if;
  select coalesce(jsonb_agg(item order by overdue_order desc nulls last,due_order,due_time_order nulls last),'[]'::jsonb) into results
  from (
    select jsonb_strip_nulls(jsonb_build_object(
      'id',r.id,'type','reminder','title',r.title,'due_date',r.due_at,'due_time',r.due_time,
      'due_time_zone',r.due_time_zone,'status',r.status,'document_title',d.title,'category',c.name
    )) item,
    case when scope='overdue' then r.due_at end overdue_order,
    case when scope<>'overdue' then r.due_at end due_order,
    r.due_time due_time_order
    from fp.reminders r
    left join fp.documents d on d.id=r.document_id and d.household_id=hid
    left join fp.categories c on c.id=d.category_id and c.household_id=hid
    where r.household_id=hid and r.status='upcoming'
      and (r.document_id is null or (d.id is not null and d.lifecycle_status<>'deleted' and (
        d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid)
      )))
      and (r.document_id is not null or (r.audience='family' or r.created_by=uid))
      and case scope
        when 'today' then r.due_at=local_today
        when 'tomorrow' then r.due_at=local_today+1
        when 'upcoming' then r.due_at>=local_today
        when 'overdue' then r.due_at<local_today
        when 'date' then r.due_at=requested_date
      end
    limit 25
  ) authorised;
  answer:=jsonb_build_object(
    'message',case
      when jsonb_array_length(results)=0 and scope='today' then 'You have no reminders for today.'
      when jsonb_array_length(results)=0 and scope='tomorrow' then 'You have no reminders for tomorrow.'
      when jsonb_array_length(results)=0 and scope='overdue' then 'You have no overdue reminders.'
      when jsonb_array_length(results)=0 then 'No reminders matched that date.'
      when scope='today' then 'Here are your reminders for today.'
      when scope='tomorrow' then 'Here are your reminders for tomorrow.'
      when scope='overdue' then 'Here are your overdue reminders.'
      else 'Here are your upcoming reminders.'
    end,
    'results',results,
    'references',(select coalesce(jsonb_agg(jsonb_build_object(
      'type','reminder','id',value->>'id','label',value->>'title',
      'metadata',jsonb_strip_nulls(jsonb_build_object('due_date',value->>'due_date','due_time',value->>'due_time'))
    )),'[]'::jsonb) from jsonb_array_elements(results)),
    'scope',scope,
    'local_date',local_today
  );
  insert into fp.conversation_executions(conversation_id,household_id,user_id,request_key,action_id,action_type,action_version,action_parameters,proposal_digest,action_digest,model_derived,status,result)
    values(current.id,hid,uid,request_key,action_id,'query_reminders',action_version,parameters,digest,digest,false,'succeeded',answer) returning * into execution;
  perform fp.append_authoritative_conversation_message(current,'outcome-'||execution.id,'result',answer->>'message',answer-'message');
  return fp.conversation_execution_public(execution);
end$$;

create or replace function fp.decide_conversation_clarification(
  clarification uuid,
  decision text,
  option_id text default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  execution fp.conversation_executions;
  current fp.conversations;
  chosen jsonb;
  answer jsonb;
begin
  select * into execution from fp.conversation_executions e where e.id=clarification for update;
  if execution.id is null or execution.action_type<>'request_clarification' then raise exception 'clarification unavailable' using errcode='PT404';end if;
  select * into current from fp.conversation_member(execution.conversation_id);
  if current.id is null or current.user_id<>execution.user_id or current.household_id<>execution.household_id then raise exception 'not authorised' using errcode='42501';end if;
  if decision='redisplay' then
    if execution.status<>'awaiting_clarification' then raise exception 'clarification unavailable' using errcode='PT409';end if;
    perform fp.append_authoritative_conversation_message(current,'redisplay-'||execution.id,'clarification',execution.action_parameters->>'question',jsonb_build_object(
      'clarification_id',execution.id,'action',jsonb_build_object('id',execution.action_id,'type',execution.action_type,'version',execution.action_version,'parameters',execution.action_parameters),
      'choices',coalesce(execution.action_parameters->'choices','[]'::jsonb),'choice_actions',coalesce(execution.action_parameters->'choice_actions','[]'::jsonb)
    ));
    return fp.conversation_execution_public(execution);
  end if;
  if decision in ('cancel','supersede') then
    if execution.status='awaiting_clarification' then update fp.conversation_executions set status='cancelled',result=jsonb_build_object('message',case when decision='cancel' then 'Okay, cancelled.' else 'Superseded by your new request.' end),updated_at=clock_timestamp() where id=execution.id returning * into execution;end if;
    if decision='cancel' then perform fp.append_authoritative_conversation_message(current,'cancel-'||execution.id,'result','Okay, cancelled.','{}'::jsonb);end if;
    return fp.conversation_execution_public(execution);
  end if;
  if decision<>'select' or option_id is null or option_id !~ '^[A-Za-z0-9:_-]{8,100}$' or execution.status<>'awaiting_clarification' then raise exception 'invalid clarification decision' using errcode='22023';end if;
  select value into chosen from jsonb_array_elements(coalesce(execution.action_parameters->'choice_actions','[]'::jsonb)) where value->>'id'=option_id;
  if chosen is null then raise exception 'clarification option unavailable' using errcode='PT404';end if;
  update fp.conversation_executions set status='succeeded',result=jsonb_build_object('message','Selection received.'),updated_at=clock_timestamp() where id=execution.id;
  return fp.submit_conversation_action(current.id,chosen->>'id',chosen->>'type',(chosen->>'version')::integer,chosen->'parameters','clarification-'||execution.id||'-'||option_id,execution.model_derived);
end$$;

revoke execute on function fp.submit_conversation_reminder_query(uuid,text,integer,jsonb,text),fp.decide_conversation_clarification(uuid,text,text) from public,anon,authenticated;
grant execute on function fp.submit_conversation_reminder_query(uuid,text,integer,jsonb,text),fp.decide_conversation_clarification(uuid,text,text) to service_role;
revoke execute on function fp.enrich_conversation_clarification_message() from public,anon,authenticated;

commit;
