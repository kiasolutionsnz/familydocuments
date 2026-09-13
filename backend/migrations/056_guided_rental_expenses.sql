begin;

alter table fp.conversation_executions add column rental_request_digest text
  check(rental_request_digest is null or rental_request_digest ~ '^[0-9a-f]{64}$');

create function fp.conversation_rental_visible(property uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,fp as $$
 select exists(select 1 from fp.rental_properties p join fp.entities e on e.id=p.entity_id
 where p.entity_id=property and p.household_id=fp.active_family_id() and e.status='active'
 and (fp.is_household_admin(p.household_id) or p.created_by=fp.current_user_id() or exists(
 select 1 from fp.access_rules a where a.household_id=p.household_id and a.scope_type='entity'
 and a.entity_id=e.id and a.member_user_id=fp.current_user_id())))
$$;

-- A rental draft is not a mutation. Only a complete, confirmed expense executes.
alter function fp.assert_conversation_action_v1(text,jsonb) rename to assert_conversation_action_before_056;
create function fp.assert_conversation_action_v1(action_type text,parameters jsonb) returns void
language plpgsql immutable set search_path=pg_catalog,fp as $$
declare k text;v jsonb;
begin
  if action_type='request_clarification' and parameters?'proposed_action' then
    v:=parameters->'proposed_action';
    if jsonb_typeof(v)<>'object' or v->>'type'<>'record_rental_expense' or v->>'version'<>'1'
      or exists(select 1 from jsonb_object_keys(v) x where x not in ('id','type','version','parameters')) then
      raise exception 'invalid rental draft' using errcode='22023';end if;
    perform fp.assert_conversation_action_v1('record_rental_expense',v->'parameters');
    perform fp.assert_conversation_action_before_056(action_type,parameters-'proposed_action');return;
  end if;
  if action_type<>'record_rental_expense' then perform fp.assert_conversation_action_before_056(action_type,parameters);return;end if;
  if jsonb_typeof(parameters)<>'object' or octet_length(parameters::text)>4096 then raise exception 'invalid rental action' using errcode='22023';end if;
  for k,v in select * from jsonb_each(parameters) loop
    if k not in ('attachment_id','document_id','property_id','property_name','create_property','address','amount','currency','expected_updated_at','property_version') then raise exception 'unknown rental property' using errcode='22023';end if;
    if k='create_property' then
      if jsonb_typeof(v)<>'boolean' then raise exception 'invalid creation choice' using errcode='22023';end if;
    elsif jsonb_typeof(v)<>'string' or length(v#>>'{}') not between 1 and 240 then raise exception 'invalid rental value' using errcode='22023';end if;
    if k in ('attachment_id','document_id','property_id') and v#>>'{}' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then raise exception 'invalid rental reference' using errcode='22023';end if;
  end loop;
  if parameters?'attachment_id' and parameters?'document_id' then raise exception 'ambiguous document' using errcode='22023';end if;
  if parameters?'amount' and (parameters->>'amount' !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$') then raise exception 'invalid amount' using errcode='22023';end if;
  if parameters?'currency' and parameters->>'currency' !~ '^[A-Z]{3}$' then raise exception 'invalid currency' using errcode='22023';end if;
  if length(parameters->>'property_name')>100 or (parameters?'address' and length(trim(parameters->>'address'))<3) then raise exception 'invalid property details' using errcode='22023';end if;
  if parameters?'property_id' and coalesce((parameters->>'create_property')::boolean,false) then raise exception 'ambiguous property' using errcode='22023';end if;
end $$;

alter function fp.conversation_is_mutation(text) rename to conversation_is_mutation_before_056;
create function fp.conversation_is_mutation(action_type text) returns boolean language sql immutable set search_path=pg_catalog,fp as $$select action_type='record_rental_expense' or fp.conversation_is_mutation_before_056(action_type)$$;
alter function fp.conversation_requires_confirmation(text,jsonb,boolean) rename to conversation_requires_confirmation_before_056;
create function fp.conversation_requires_confirmation(action_type text,parameters jsonb,model_derived boolean) returns boolean language sql immutable set search_path=pg_catalog,fp as $$select action_type='record_rental_expense' or fp.conversation_requires_confirmation_before_056(action_type,parameters,model_derived)$$;

alter function fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) rename to submit_conversation_action_before_056;
do $$begin
  execute replace(pg_get_functiondef('fp.submit_conversation_action_before_056(uuid,text,text,integer,jsonb,text,boolean)'::regprocedure),
    'submit_conversation_action.request_key','submit_conversation_action_before_056.request_key');
end $$;
create function fp.submit_conversation_action(conversation uuid,action_id text,action_type text,action_version integer,parameters jsonb,request_key text,model_derived boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare c fp.conversations;e fp.conversation_executions;p jsonb:=parameters;r record;question text;missing text;
  labels jsonb:='[]';actions jsonb:='[]';a jsonb;outcome jsonb;matches integer;role text;request_digest text;
begin
  if action_type<>'record_rental_expense' then return fp.submit_conversation_action_before_056(conversation,action_id,action_type,action_version,parameters,request_key,model_derived);end if;
  c:=fp.conversation_member(conversation);
  perform 1 from fp.active_family_contexts where user_id=c.user_id for update;
  perform fp.assert_conversation_action_v1(action_type,p);
  request_digest:=fp.conversation_action_digest(action_type,action_version,parameters);
  -- Replay the original bound outcome before resolving mutable catalogue state.
  select * into e from fp.conversation_executions x where x.user_id=c.user_id and x.household_id=c.household_id and x.request_key=submit_conversation_action.request_key for update;
  if e.id is not null then
    if e.rental_request_digest is distinct from fp.conversation_action_digest(action_type,action_version,p) then raise exception 'request key reused' using errcode='PT409';end if;
    return fp.conversation_execution_public(e)||jsonb_build_object('duplicate',true);
  end if;
  select m.role into role from fp.members m where m.household_id=c.household_id and m.user_id=c.user_id and m.status='active' for share;
  if role not in ('owner','family_admin','adult_member','contributor') then
    outcome:=fp.submit_conversation_action_before_056(conversation,action_id,action_type,action_version,p,request_key,model_derived);
    update fp.conversation_executions set rental_request_digest=request_digest where id=(outcome->>'execution_id')::uuid returning * into e;
    return fp.conversation_execution_public(e);
  end if;
  if p?'document_id' then perform fp.authorized_source_document((p->>'document_id')::uuid);end if;
  if p?'attachment_id' and not exists(select 1 from fp.conversation_attachments x where x.id=(p->>'attachment_id')::uuid and x.conversation_id=c.id and x.household_id=c.household_id and x.user_id=c.user_id and x.expires_at>now()) then raise exception 'attachment unavailable' using errcode='42501';end if;
  if p?'property_id' then
    select x.updated_at::text version,n.name into r from fp.rental_properties x join fp.entities n on n.id=x.entity_id where x.entity_id=(p->>'property_id')::uuid and x.household_id=c.household_id and fp.conversation_rental_visible(x.entity_id);
    if not found then raise exception 'property unavailable' using errcode='42501';end if;
    p:=p||jsonb_build_object('property_version',r.version,'property_name',r.name);
  elsif not coalesce((p->>'create_property')::boolean,false) then
    select count(*) into matches from fp.rental_properties x join fp.entities n on n.id=x.entity_id where x.household_id=c.household_id and fp.conversation_rental_visible(x.entity_id) and lower(trim(n.name))=lower(trim(p->>'property_name'));
    if matches=1 then
      select x.entity_id,x.updated_at::text version,n.name into r from fp.rental_properties x join fp.entities n on n.id=x.entity_id where x.household_id=c.household_id and fp.conversation_rental_visible(x.entity_id) and lower(trim(n.name))=lower(trim(p->>'property_name'));
      p:=p||jsonb_build_object('property_id',r.entity_id,'property_version',r.version,'property_name',r.name);
    else
      missing:='rental_property';question:='Which rental is this for? Choose one, type its name, or choose Create rental.';
      if p?'property_name' and matches=0 then question:='I could not find that rental. Choose an existing rental, type another name, or choose Create rental.';end if;
      for r in select x.entity_id,n.name from fp.rental_properties x join fp.entities n on n.id=x.entity_id where x.household_id=c.household_id and fp.conversation_rental_visible(x.entity_id) order by n.name,x.entity_id limit 2 loop
        labels:=labels||to_jsonb(r.name);actions:=actions||jsonb_build_array(jsonb_build_object('id','rental-'||r.entity_id,'type',action_type,'version',1,'parameters',(p-'create_property')||jsonb_build_object('property_id',r.entity_id)));
      end loop;
      labels:=labels||'"Create rental"'::jsonb;actions:=actions||jsonb_build_array(jsonb_build_object('id','create-rental-'||gen_random_uuid(),'type',action_type,'version',1,'parameters',p||jsonb_build_object('create_property',true)));
    end if;
  end if;
  if missing is null then
    if not (p?'property_name') then missing:='rental_name';question:='What name should I use for the new rental?';
    elsif coalesce((p->>'create_property')::boolean,false) and not (p?'address') then missing:='rental_address';question:='What is the rental property address? I will ask you to confirm before creating it.';
    elsif not (p?'document_id' or p?'attachment_id') then missing:='rental_document';question:='Attach the expense document, or find and select the saved document first.';
    elsif not (p?'amount') then missing:='rental_amount';question:='What is the expense amount? Enter an amount such as NZD 125.00. Nothing has been created yet.';
    end if;
  end if;
  if missing is not null then
    a:=jsonb_build_object('question',question,'missing_parameter',missing,'proposed_action',jsonb_build_object('id',action_id,'type',action_type,'version',1,'parameters',p),'choices',labels,'choice_actions',actions);
    outcome:=fp.submit_conversation_action_before_056(conversation,action_id,'request_clarification',action_version,a,request_key,model_derived);
  else
    outcome:=fp.submit_conversation_action_before_056(conversation,action_id,action_type,action_version,p,request_key,model_derived);
    update fp.conversation_execution_confirmations set summary='Record '||coalesce(p->>'currency','NZD')||' '||(p->>'amount')||' as an expense (Other) for '||(p->>'property_name')||case when coalesce((p->>'create_property')::boolean,false) then ' and create this rental at '||(p->>'address') else '' end||'? No OCR or reminder will be started.',target_label=p->>'property_name' where execution_id=(outcome->>'execution_id')::uuid;
  end if;
  update fp.conversation_executions set rental_request_digest=request_digest where id=(outcome->>'execution_id')::uuid returning * into e;
  return fp.conversation_execution_public(e);
end $$;

alter function fp.run_conversation_execution(uuid) rename to run_conversation_execution_before_056;
create function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.conversation_executions;c fp.conversations;p jsonb;uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();role text;
  property uuid;doc fp.documents;cat text;outcome jsonb;existing fp.rental_bills;version text;
begin
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.user_id<>uid or e.household_id<>hid then raise exception 'not authorised' using errcode='42501';end if;
  if e.action_type<>'record_rental_expense' then return fp.run_conversation_execution_before_056(execution);end if;
  c:=fp.conversation_member(e.conversation_id);p:=e.action_parameters;
  select m.role into role from fp.members m where m.household_id=hid and m.user_id=uid and m.status='active' for share;
  if role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  perform fp.assert_conversation_action_v1(e.action_type,p);
  if not (p?'amount') then raise exception 'incomplete expense' using errcode='22023';end if;
  if p?'property_id' then
    select entity_id,updated_at::text into property,version from fp.rental_properties where entity_id=(p->>'property_id')::uuid and household_id=hid and fp.conversation_rental_visible(entity_id) for update;
    if property is null then raise exception 'property unavailable' using errcode='42501';end if;
    if version is distinct from p->>'property_version' then raise exception 'property changed' using errcode='PT409';end if;
  elsif coalesce((p->>'create_property')::boolean,false) and p?'address' and p?'property_name' then
    perform pg_advisory_xact_lock(hashtextextended(hid::text||':rental:'||lower(trim(p->>'property_name')),0));
    if exists(select 1 from fp.rental_properties x join fp.entities n on n.id=x.entity_id where x.household_id=hid and lower(trim(n.name))=lower(trim(p->>'property_name'))) then raise exception 'rental now exists' using errcode='PT409';end if;
    -- The legacy create_rental_property selects the first membership; bind explicitly here.
    insert into fp.entities(household_id,entity_type,name,created_by) values(hid,'property',trim(p->>'property_name'),uid) returning id into property;
    insert into fp.rental_properties(entity_id,household_id,address,created_by) values(property,hid,trim(p->>'address'),uid);
  else raise exception 'incomplete rental' using errcode='22023';end if;
  if p?'attachment_id' then
    select name into cat from fp.categories where household_id=hid and lower(name) in ('rentals','rental records') order by (lower(name)='rentals') desc limit 1;
    if cat is null then raise exception 'rental category unavailable' using errcode='22023';end if;
    outcome:=fp.submit_conversation_action(e.conversation_id,'rental-save-'||e.id,'save_document',1,jsonb_build_object('attachment_id',p->>'attachment_id','category_name',cat,'tags',jsonb_build_array('rental','expense')),'rental-save-'||e.id,false);
    if outcome->>'state'<>'succeeded' then raise exception 'document save failed' using errcode='22023';end if;
    select * into doc from fp.documents where id=(outcome#>>'{result,document_id}')::uuid;
  else
    doc:=fp.authorized_source_document((p->>'document_id')::uuid);
    if not (doc.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=doc.id and x.member_user_id=uid and x.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501';end if;
    if doc.updated_at::text is distinct from e.expected_target_version then raise exception 'document changed' using errcode='PT409';end if;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(property::text||':'||doc.id::text,0));
  select * into existing from fp.rental_bills where property_entity_id=property and document_id=doc.id;
  if existing.id is not null then
    if existing.amount is distinct from (p->>'amount')::numeric or existing.currency<>coalesce(p->>'currency','NZD') then raise exception 'expense already recorded with different values' using errcode='PT409';end if;
    outcome:=jsonb_build_object('id',existing.id);
  else outcome:=fp.create_rental_record(property,doc.id,'other','general_record',null,null,(p->>'amount')::numeric,coalesce(p->>'currency','NZD'),null);end if;
  return jsonb_build_object('message','Recorded '||coalesce(p->>'currency','NZD')||' '||(p->>'amount')||' for '||(p->>'property_name')||'. No reminder was created.','document_id',doc.id,'title',doc.title,'property_id',property,'expense_id',outcome->>'id');
end $$;

revoke all on function fp.assert_conversation_action_before_056(text,jsonb),fp.assert_conversation_action_v1(text,jsonb),fp.conversation_is_mutation_before_056(text),fp.conversation_is_mutation(text),fp.conversation_requires_confirmation_before_056(text,jsonb,boolean),fp.conversation_requires_confirmation(text,jsonb,boolean),fp.submit_conversation_action_before_056(uuid,text,text,integer,jsonb,text,boolean),fp.run_conversation_execution_before_056(uuid),fp.run_conversation_execution(uuid) from public,anon,authenticated;
revoke all on function fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) from public,anon,authenticated;
revoke all on function fp.conversation_rental_visible(uuid) from public,anon,authenticated;
grant execute on function fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean) to service_role;
commit;
