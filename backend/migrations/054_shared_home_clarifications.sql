-- Forward migration after 053; independent of the uncommitted 052 draft.
begin;

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
    when 'request_clarification' then allowed:=array['question','missing_parameter','choices','choice_actions','attachment_id','tags','link_url','link_title','draft_title','draft_date','draft_time'];required:=array['question','missing_parameter'];
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
  if parameters?'draft_date' then perform (parameters->>'draft_date')::date;end if;
  if parameters?'draft_time' then perform (parameters->>'draft_time')::time;end if;
  if parameters?'draft_title' and (jsonb_typeof(parameters->'draft_title')<>'string' or char_length(parameters->>'draft_title')>160) then raise exception 'invalid reminder draft' using errcode='22023';end if;
  if parameters?'expected_updated_at' then perform (parameters->>'expected_updated_at')::timestamptz;end if;
end$$;

-- Build attachment choices once, from the authenticated conversation's Family.
-- Neither transport may supply category IDs or executable option payloads.
create or replace function fp.append_authoritative_conversation_message(
  current fp.conversations, client_id text, kind text, content text,
  data jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  execution fp.conversation_executions;
  options jsonb;
  item jsonb;
  labels jsonb:='[]'::jsonb;
  actions jsonb:='[]'::jsonb;
  attachment uuid;
  action jsonb;
begin
  if kind not in ('clarification','confirmation','progress','result','error','text')
    or char_length(trim(content)) not between 1 and 2000
    or jsonb_typeof(data)<>'object' or octet_length(data::text)>16384
  then raise exception 'invalid authoritative message' using errcode='22023';end if;
  if kind='clarification' and client_id ~ '^outcome-[0-9a-f-]{36}$' then
    select * into execution from fp.conversation_executions
      where id=substring(client_id from 9)::uuid and conversation_id=current.id
      and household_id=current.household_id and user_id=current.user_id
      and status='awaiting_clarification' for update;
    if execution.id is not null then
      data:=data||jsonb_build_object('clarification_id',execution.id);
      if execution.action_type='request_clarification'
        and execution.action_parameters->>'missing_parameter' in ('category_name','document_category')
        and execution.action_parameters?'attachment_id' then
        attachment:=(execution.action_parameters->>'attachment_id')::uuid;
        options:=fp.conversation_category_options(current.id,attachment,null);
        for item in select value from jsonb_array_elements(options->'categories') with ordinality
          as ranked(value,ordinal) where ordinal<=2 loop
          action:=jsonb_build_object('id','category-'||replace(execution.id::text,'-','')||'-'||replace(item->>'id','-',''),
            'type','save_document','version',1,'parameters',jsonb_build_object(
              'attachment_id',attachment,'category_name',item->>'name',
              'tags',coalesce(execution.action_parameters->'tags','[]'::jsonb)));
          labels:=labels||to_jsonb(item->>'name');
          actions:=actions||jsonb_build_array(action);
        end loop;
        labels:=labels||'"Read document"'::jsonb;
        actions:=actions||jsonb_build_array(jsonb_build_object(
          'id','read-'||replace(execution.id::text,'-',''),
          'type','request_document_ocr','version',1,
          'parameters',jsonb_build_object('attachment_id',attachment,'mode','document')));
        update fp.conversation_executions set
          action_parameters=action_parameters||jsonb_build_object(
            'choices',labels,'choice_actions',actions,'_trusted_transport_choices',true),
          result=result||jsonb_build_object('choices',labels,'choice_actions',actions),
          updated_at=clock_timestamp() where id=execution.id;
        data:=data||jsonb_build_object('choices',labels,'choice_actions',actions,
          'can_save',options->'can_save','show_more_categories',true);
        data:=jsonb_set(data,'{action,parameters}',
          (data#>'{action,parameters}')||jsonb_build_object('choices',labels,'choice_actions',actions));
      else
        data:=data||jsonb_build_object('choices',coalesce(execution.action_parameters->'choices','[]'::jsonb),
          'choice_actions',coalesce(execution.action_parameters->'choice_actions','[]'::jsonb));
      end if;
    end if;
  end if;
  insert into fp.conversation_messages(conversation_id,household_id,user_id,
    client_message_id,role,kind,content,message_data,created_at)
    values(current.id,current.household_id,current.user_id,client_id,'assistant',kind,trim(content),data,clock_timestamp())
    on conflict(conversation_id,client_message_id) do nothing;
  delete from fp.conversation_messages m where m.conversation_id=current.id
    and m.id not in(select id from fp.conversation_messages
      where conversation_id=current.id order by created_at desc,id desc limit 60);
  update fp.conversations set updated_at=clock_timestamp() where id=current.id;
end$$;

-- The caller receives the same prepared choices that restoration returns.
create or replace function fp.conversation_execution_public(input_row fp.conversation_executions)
returns jsonb language sql stable set search_path=pg_catalog,fp as $$
  select jsonb_build_object('execution_id',e.id,'state',e.status,
    'action_type',e.action_type,'result',e.result,'error_category',e.error_category,
    'confirmation',(select jsonb_build_object('id',c.id,'summary',c.summary,
      'target_label',c.target_label,'expires_at',c.expires_at)
      from fp.conversation_execution_confirmations c
      where c.execution_id=e.id and c.state='pending'))
  from fp.conversation_executions e where e.id=input_row.id
$$;

-- Resolved or superseded shared clarifications no longer restore as pending.
create or replace function fp.resolve_clarification_presentation() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if old.status='awaiting_clarification' and new.status<>'awaiting_clarification' then
    update fp.conversation_messages set message_data=message_data||'{"resolved":true}'::jsonb
      where conversation_id=new.conversation_id
        and message_data->>'clarification_id'=new.id::text;
  end if;
  return new;
end$$;
create trigger resolve_clarification_presentation after update of status
  on fp.conversation_executions for each row
  execute function fp.resolve_clarification_presentation();

-- Secondary-list and typed choices are resolved against live Family rows.
create or replace function fp.select_conversation_category(
  clarification uuid, category uuid
) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  execution fp.conversation_executions;
  current fp.conversations;
  chosen fp.categories;
  option_id text;
  action jsonb;
begin
  select * into execution from fp.conversation_executions
    where id=clarification and status='awaiting_clarification' for update;
  if execution.id is null or execution.action_type<>'request_clarification'
    or execution.action_parameters->>'missing_parameter' not in ('category_name','document_category')
    or not execution.action_parameters?'attachment_id'
  then raise exception 'clarification unavailable' using errcode='PT409';end if;
  select * into current from fp.conversation_member(execution.conversation_id);
  if current.id is null or current.user_id<>execution.user_id
    or current.household_id<>execution.household_id
  then raise exception 'not authorised' using errcode='42501';end if;
  perform fp.conversation_category_options(current.id,
    (execution.action_parameters->>'attachment_id')::uuid,null);
  select * into chosen from fp.categories where id=category
    and household_id=current.household_id;
  if chosen.id is null then raise exception 'category unavailable' using errcode='42501';end if;
  option_id:='category-'||replace(execution.id::text,'-','')||'-'||replace(chosen.id::text,'-','');
  action:=jsonb_build_object('id',option_id,'type','save_document','version',1,
    'parameters',jsonb_build_object(
      'attachment_id',execution.action_parameters->>'attachment_id',
      'category_name',chosen.name,
      'tags',coalesce(execution.action_parameters->'tags','[]'::jsonb)));
  if not exists(select 1 from jsonb_array_elements(
      coalesce(execution.action_parameters->'choice_actions','[]'::jsonb)) item
      where item->>'id'=option_id) then
    update fp.conversation_executions set action_parameters=action_parameters||
      jsonb_build_object('choice_actions',
        jsonb_build_array(action),
        'choices',jsonb_build_array(chosen.name))
      where id=execution.id;
  end if;
  return fp.decide_conversation_clarification(execution.id,'select',option_id);
end$$;

revoke execute on function fp.select_conversation_category(uuid,uuid) from public,anon;
grant execute on function fp.select_conversation_category(uuid,uuid) to authenticated,service_role;

revoke execute on function fp.resolve_clarification_presentation() from public,anon,authenticated;
commit;
