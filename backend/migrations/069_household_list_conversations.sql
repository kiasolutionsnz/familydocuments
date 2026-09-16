begin;
alter function fp.assert_conversation_action_v1(text,jsonb) rename to assert_conversation_action_before_069;
create function fp.assert_conversation_action_v1(action_type text,parameters jsonb) returns void
language plpgsql set search_path=pg_catalog,fp as $$
begin
  if action_type<>'add_household_list_item' then perform fp.assert_conversation_action_before_069(action_type,parameters);return;end if;
  if jsonb_typeof(parameters)<>'object' or exists(select 1 from jsonb_object_keys(parameters) k where k not in ('title','list_name'))
    or jsonb_typeof(parameters->'title') is distinct from 'string' or jsonb_typeof(parameters->'list_name') is distinct from 'string'
    or char_length(btrim(parameters->>'title')) not between 1 and 240 or char_length(btrim(parameters->>'list_name')) not between 1 and 120
  then raise exception 'invalid list action' using errcode='22023';end if;
end $$;
alter function fp.conversation_is_mutation(text) rename to conversation_is_mutation_before_069;
create function fp.conversation_is_mutation(action_type text) returns boolean language sql immutable set search_path=pg_catalog,fp as $$select action_type='add_household_list_item' or fp.conversation_is_mutation_before_069(action_type)$$;
alter function fp.conversation_requires_confirmation(text,jsonb,boolean) rename to conversation_requires_confirmation_before_069;
create function fp.conversation_requires_confirmation(action_type text,parameters jsonb,model_derived boolean) returns boolean language sql immutable set search_path=pg_catalog,fp as $$select action_type='add_household_list_item' or fp.conversation_requires_confirmation_before_069(action_type,parameters,model_derived)$$;

alter function fp.run_conversation_execution(uuid) rename to run_conversation_execution_before_069;
create function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.conversation_executions;hid uuid:=fp.active_family_id();uid uuid:=fp.current_user_id();lid uuid;matches integer;r jsonb;
begin
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.household_id<>hid or e.user_id<>uid then raise exception 'not authorised' using errcode='42501';end if;
  if e.action_type<>'add_household_list_item' then return fp.run_conversation_execution_before_069(execution);end if;
  perform fp.conversation_member(e.conversation_id);
  perform fp.assert_conversation_action_v1(e.action_type,e.action_parameters);
  select count(*) into matches from fp.household_lists where household_id=hid and lower(title)=lower(btrim(e.action_parameters->>'list_name'));
  if matches<>1 then raise exception 'Choose a unique existing list name in Lists and try again; no item was added' using errcode='22023';end if;
  select id into lid from fp.household_lists where household_id=hid and lower(title)=lower(btrim(e.action_parameters->>'list_name'));
  r:=fp.save_household_list_item(lid,e.id,0,jsonb_build_object('title',e.action_parameters->>'title'));
  return jsonb_build_object('message','Added '||(r->>'title')||' to '||(e.action_parameters->>'list_name')||'.','list_id',lid,'item_id',r->>'id');
end $$;

-- Use the existing durable confirmation/receipt machinery for web and Telegram.
alter function fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) rename to submit_conversation_action_before_069;
create function fp.submit_conversation_action(conversation uuid,action_id text,action_type text,action_version integer,parameters jsonb,request_key text,model_derived boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;confirmation_summary text;
begin
  if action_type='add_household_list_item' then
    perform fp.assert_conversation_action_v1(action_type,parameters);
    if (select count(*) from fp.household_lists where household_id=fp.active_family_id() and lower(title)=lower(btrim(parameters->>'list_name')))<>1 then
      return fp.submit_conversation_action_before_069(conversation,action_id,'request_clarification',action_version,jsonb_build_object('question','Which list? Open Lists and choose a unique list name, then say Add [item] to [name] list. Nothing has been added.','missing_parameter','list_name'),request_key,false);
    end if;
  end if;
  result:=fp.submit_conversation_action_before_069(conversation,action_id,action_type,action_version,parameters,request_key,model_derived);
  if action_type='add_household_list_item' and result->>'state'='awaiting_confirmation' then
    confirmation_summary:='Add '||(parameters->>'title')||' to shared list '||(parameters->>'list_name')||'?';
    update fp.conversation_execution_confirmations set summary=confirmation_summary,target_label=parameters->>'list_name' where execution_id=(result->>'execution_id')::uuid and state='pending';
    result:=jsonb_set(result,'{confirmation,summary}',to_jsonb(confirmation_summary));
  end if;
  return result;
end $$;
revoke all on function fp.run_conversation_execution(uuid),fp.run_conversation_execution_before_069(uuid),fp.submit_conversation_action_before_069(uuid,text,text,integer,jsonb,text,boolean),fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) to service_role;
commit;
