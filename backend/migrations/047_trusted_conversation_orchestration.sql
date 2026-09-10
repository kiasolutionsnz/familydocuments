begin;

-- Phase 2D hardening. Conversation actions are prepared and executed by the
-- database boundary so UI retries cannot duplicate mutations or invent an
-- authoritative outcome.

create or replace function fp.normalise_saved_link_url(input_url text) returns jsonb
language plpgsql immutable set search_path=pg_catalog,extensions as $$
declare raw text:=trim(input_url);authority text;host text;canonical text;
begin
  if char_length(raw) not between 9 and 2048 or raw !~ '^https://[^[:space:]]+$' or raw ~ '^https://[^/?#]*@' then raise exception 'invalid HTTPS link' using errcode='22023';end if;
  authority:=substring(raw from '^https://([^/?#]+)');host:=lower(split_part(authority,':',1));
  if host is null or host='' or host='localhost' or host like '%.localhost' or host like '%.local' or host like '%.internal' or host ~ '^\[' or host ~ '^[0-9]+(\.[0-9]+){3}$' or host !~ '^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$' or position('.' in host)=0 then raise exception 'invalid public hostname' using errcode='22023';end if;
  canonical:='https://'||lower(authority)||substring(raw from char_length('https://'||authority)+1);canonical:=regexp_replace(canonical,'#.*$','');canonical:=regexp_replace(canonical,'^https://([^/:]+):443(?=/|$)','https://\1');
  return jsonb_build_object('url',raw,'host',host,'canonical',canonical,'hash',encode(extensions.digest(canonical,'sha256'),'hex'));
end$$;

create table fp.active_family_contexts(
  user_id uuid primary key,
  household_id uuid not null references fp.households(id) on delete cascade,
  selected_at timestamptz not null default now()
);

create table fp.conversation_attachments(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  file_name text not null check(char_length(file_name) between 1 and 255),
  mime_type text not null check(mime_type in ('application/pdf','image/jpeg','image/png')),
  content bytea not null check(octet_length(content) between 1 and 5242880),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz not null default now()+interval '24 hours',
  created_at timestamptz not null default now(),
  unique(conversation_id,user_id,sha256)
);

create table fp.conversation_executions(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,100}$'),
  action_id text not null check(action_id ~ '^[A-Za-z0-9:_-]{8,100}$'),
  action_type text not null,
  action_version integer not null check(action_version=1),
  action_parameters jsonb not null check(jsonb_typeof(action_parameters)='object' and octet_length(action_parameters::text)<=8192),
  proposal_digest text not null check(proposal_digest ~ '^[0-9a-f]{64}$'),
  action_digest text not null check(action_digest ~ '^[0-9a-f]{64}$'),
  model_derived boolean not null default false,
  target_type text,
  target_id uuid,
  expected_target_version text,
  status text not null check(status in ('proposed','awaiting_clarification','awaiting_confirmation','executing','succeeded','failed_before_mutation','partially_completed','retryable','permanently_failed','cancelled','expired')),
  result jsonb not null default '{}'::jsonb check(jsonb_typeof(result)='object' and octet_length(result::text)<=8192),
  error_category text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,user_id,request_key),
  unique(conversation_id,action_id)
);

create table fp.conversation_execution_confirmations(
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null unique references fp.conversation_executions(id) on delete cascade,
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  action_digest text not null check(action_digest ~ '^[0-9a-f]{64}$'),
  target_type text,
  target_id uuid,
  expected_target_version text,
  idempotency_key text not null check(idempotency_key ~ '^[A-Za-z0-9:_-]{8,100}$'),
  state text not null default 'pending' check(state in ('pending','executing','succeeded','failed','cancelled','expired')),
  summary text not null check(char_length(summary) between 1 and 240),
  target_label text not null check(char_length(target_label) between 1 and 160),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check(expires_at>created_at)
);

create table fp.conversation_rate_limits(
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  bucket text not null check(bucket ~ '^[a-z0-9_-]{2,40}$'),
  window_started_at timestamptz not null,
  request_count integer not null check(request_count between 1 and 10000),
  primary key(household_id,user_id,bucket)
);

create table fp.conversation_security_receipts(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  conversation_id uuid not null,
  action_type text not null,
  action_digest text not null check(action_digest ~ '^[0-9a-f]{64}$'),
  status text not null check(status in ('succeeded','failed_before_mutation','partially_completed','retryable','permanently_failed','cancelled','expired')),
  created_at timestamptz not null default now()
);

alter table fp.active_family_contexts enable row level security;alter table fp.active_family_contexts force row level security;
alter table fp.conversation_attachments enable row level security;alter table fp.conversation_attachments force row level security;
alter table fp.conversation_executions enable row level security;alter table fp.conversation_executions force row level security;
alter table fp.conversation_execution_confirmations enable row level security;alter table fp.conversation_execution_confirmations force row level security;
alter table fp.conversation_rate_limits enable row level security;alter table fp.conversation_rate_limits force row level security;
alter table fp.conversation_security_receipts enable row level security;alter table fp.conversation_security_receipts force row level security;
revoke all on fp.active_family_contexts,fp.conversation_attachments,fp.conversation_executions,fp.conversation_execution_confirmations,fp.conversation_rate_limits,fp.conversation_security_receipts from public,anon,authenticated;

create or replace function fp.active_family_id(require_selected boolean default true) returns uuid
language plpgsql security definer stable set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();selected uuid;families uuid[];
begin
  select array_agg(household_id order by joined_at,household_id) into families from fp.members where user_id=uid and status='active';
  if coalesce(array_length(families,1),0)=0 then raise exception 'not authorised' using errcode='42501';end if;
  select c.household_id into selected from fp.active_family_contexts c join fp.members m on m.household_id=c.household_id and m.user_id=uid and m.status='active' where c.user_id=uid;
  if selected is not null then return selected;end if;
  if array_length(families,1)=1 then return families[1];end if;
  if require_selected then raise exception 'active Family selection required' using errcode='PT409';end if;
  return null;
end$$;

create or replace function fp.active_family_workspace() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();selected uuid;items jsonb;
begin
  selected:=fp.active_family_id(false);
  select coalesce(jsonb_agg(jsonb_build_object('id',m.household_id,'name',h.name,'role',m.role,'selected',m.household_id=selected) order by h.name),'[]'::jsonb)
    into items from fp.members m join fp.households h on h.id=m.household_id where m.user_id=uid and m.status='active';
  return jsonb_build_object('active_family_id',selected,'selection_required',selected is null and jsonb_array_length(items)>1,'families',items);
end$$;

create or replace function fp.select_active_family(family uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();name text;
begin
  select h.name into name from fp.members m join fp.households h on h.id=m.household_id where m.user_id=uid and m.household_id=family and m.status='active';
  if name is null then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.active_family_contexts(user_id,household_id) values(uid,family) on conflict(user_id) do update set household_id=excluded.household_id,selected_at=now();
  update fp.conversation_execution_confirmations p set state='cancelled',consumed_at=now()
    where p.user_id=uid and p.household_id<>family and p.state='pending';
  update fp.conversation_executions e set status='cancelled',updated_at=now()
    where e.user_id=uid and e.household_id<>family and e.status='awaiting_confirmation';
  return jsonb_build_object('id',family,'name',name);
end$$;

create or replace function fp.conversation_member(conversation uuid) returns fp.conversations
language sql security definer stable set search_path=pg_catalog,fp as $$
  select c from fp.conversations c join fp.members m on m.household_id=c.household_id and m.user_id=c.user_id and m.status='active'
  where c.id=conversation and c.user_id=fp.current_user_id() and c.household_id=fp.active_family_id()
$$;

create or replace function fp.start_conversation(request_id text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();existing fp.conversations;created fp.conversations;retained integer;
begin
  if request_id is null or request_id !~ '^[A-Za-z0-9:_-]{8,100}$' then raise exception 'invalid request id' using errcode='22023';end if;
  delete from fp.conversations where user_id=uid and status='archived' and updated_at<now()-interval '90 days';
  delete from fp.conversation_security_receipts where created_at<now()-interval '365 days';
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':conversation',0));
  select count(*) into retained from fp.conversations where household_id=hid and user_id=uid;
  if retained>=100 then raise exception 'conversation quota reached' using errcode='PT429';end if;
  select * into existing from fp.conversations c where c.household_id=hid and c.user_id=uid and c.request_id=start_conversation.request_id;
  if existing.id is not null then return jsonb_build_object('id',existing.id,'status',existing.status,'duplicate',true);end if;
  update fp.conversations set status='archived',updated_at=clock_timestamp() where household_id=hid and user_id=uid and status='active';
  insert into fp.conversations(household_id,user_id,request_id) values(hid,uid,request_id) returning * into created;
  return jsonb_build_object('id',created.id,'status',created.status,'duplicate',false,'family_id',hid);
end$$;

create or replace function fp.append_conversation_message(conversation uuid,client_message_id text,message_role text,message_kind text,message_content text,message_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;row fp.conversation_messages;affected bigint:=0;refs jsonb;
begin
  select * into current from fp.conversation_member(conversation);
  if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  if message_role<>'user' or message_kind not in ('text','attachment') then raise exception 'authoritative messages are server managed' using errcode='42501';end if;
  refs:=coalesce(message_data->'references','[]'::jsonb);
  if client_message_id is null or client_message_id !~ '^[A-Za-z0-9:_-]{8,100}$' or char_length(trim(message_content)) not between 1 and 2000
    or jsonb_typeof(coalesce(message_data,'{}'::jsonb))<>'object' or octet_length(coalesce(message_data,'{}'::jsonb)::text)>16384
    or jsonb_typeof(refs)<>'array' or jsonb_array_length(refs)>12 then raise exception 'invalid conversation message' using errcode='22023';end if;
  insert into fp.conversation_messages(conversation_id,household_id,user_id,client_message_id,role,kind,content,message_data)
    values(current.id,current.household_id,current.user_id,client_message_id,'user',message_kind,trim(message_content),coalesce(message_data,'{}'::jsonb))
    on conflict on constraint conversation_messages_conversation_id_client_message_id_key do nothing returning * into row;
  get diagnostics affected=row_count;
  if row.id is null then select * into row from fp.conversation_messages m where m.conversation_id=current.id and m.client_message_id=append_conversation_message.client_message_id;end if;
  delete from fp.conversation_messages m where m.conversation_id=current.id and m.id not in(select id from fp.conversation_messages where conversation_id=current.id order by created_at desc,id desc limit 60);
  update fp.conversations set updated_at=clock_timestamp() where id=current.id;
  return jsonb_build_object('id',row.id,'duplicate',affected=0);
end$$;

create or replace function fp.append_authoritative_conversation_message(current fp.conversations,client_id text,kind text,content text,data jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  if kind not in ('clarification','confirmation','progress','result','error','text') or char_length(trim(content)) not between 1 and 2000
    or jsonb_typeof(data)<>'object' or octet_length(data::text)>16384 then raise exception 'invalid authoritative message' using errcode='22023';end if;
  insert into fp.conversation_messages(conversation_id,household_id,user_id,client_message_id,role,kind,content,message_data)
    values(current.id,current.household_id,current.user_id,client_id,'assistant',kind,trim(content),data) on conflict(conversation_id,client_message_id) do nothing;
  delete from fp.conversation_messages m where m.conversation_id=current.id and m.id not in(select id from fp.conversation_messages where conversation_id=current.id order by created_at desc,id desc limit 60);
  update fp.conversations set updated_at=clock_timestamp() where id=current.id;
end$$;

create or replace function fp.stage_conversation_attachment(conversation uuid,file_name text,source_mime_type text,content_base64 text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare current fp.conversations;bytes bytea;digest text;row fp.conversation_attachments;
begin
  select * into current from fp.conversation_member(conversation);if current.id is null then raise exception 'conversation not available' using errcode='42501';end if;
  if file_name is null or char_length(trim(file_name)) not between 1 and 255 or source_mime_type not in ('application/pdf','image/jpeg','image/png') or octet_length(coalesce(content_base64,''))>7340032 then raise exception 'invalid attachment' using errcode='22023';end if;
  begin bytes:=decode(regexp_replace(content_base64,'\s','','g'),'base64');exception when others then raise exception 'invalid attachment' using errcode='22023';end;
  perform fp.validate_document_bytes(source_mime_type,bytes);digest:=encode(extensions.digest(bytes,'sha256'),'hex');
  delete from fp.conversation_attachments where expires_at<=now();
  insert into fp.conversation_attachments(conversation_id,household_id,user_id,file_name,mime_type,content,sha256)
    values(current.id,current.household_id,current.user_id,left(trim(file_name),255),source_mime_type,bytes,digest)
    on conflict(conversation_id,user_id,sha256) do update set expires_at=now()+interval '24 hours' returning * into row;
  return jsonb_build_object('id',row.id,'file_name',row.file_name,'mime_type',row.mime_type,'sha256',row.sha256,'expires_at',row.expires_at);
end$$;

create or replace function fp.conversation_action_digest(action_type text,action_version integer,parameters jsonb) returns text
language sql immutable set search_path=pg_catalog,extensions as $$select encode(extensions.digest(jsonb_build_object('type',action_type,'version',action_version,'parameters',parameters)::text,'sha256'),'hex')$$;

create or replace function fp.assert_conversation_action_v1(action_type text,parameters jsonb) returns void
language plpgsql immutable set search_path=pg_catalog,fp as $$
declare allowed text[];required text[];key text;value text;choice jsonb;
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
  foreach key in array array['attachment_id','document_id','reminder_id','inbox_id'] loop
    if parameters?key and parameters->>key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then raise exception 'malformed identifier' using errcode='22023';end if;
  end loop;
  if parameters?'tags' and (jsonb_typeof(parameters->'tags')<>'array' or jsonb_array_length(parameters->'tags')>12 or exists(select 1 from jsonb_array_elements_text(parameters->'tags') t where char_length(trim(t)) not between 1 and 40)) then raise exception 'invalid tags' using errcode='22023';end if;
  if parameters?'choices' and (jsonb_typeof(parameters->'choices')<>'array' or jsonb_array_length(parameters->'choices')>3 or exists(select 1 from jsonb_array_elements_text(parameters->'choices') t where char_length(trim(t)) not between 1 and 100)) then raise exception 'invalid choices' using errcode='22023';end if;
  if parameters?'choice_actions' and (jsonb_typeof(parameters->'choice_actions')<>'array' or jsonb_array_length(parameters->'choice_actions')>3) then raise exception 'invalid choice actions' using errcode='22023';end if;
  if parameters?'choice_actions' then
    for choice in select value from jsonb_array_elements(parameters->'choice_actions') loop
      if jsonb_typeof(choice)<>'object' or jsonb_object_length(choice)<>4 or not choice ?& array['id','parameters','type','version'] or (choice->>'version')::integer<>1 or choice->>'type' in ('request_clarification','request_confirmation') then raise exception 'invalid choice action' using errcode='22023';end if;
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

create or replace function fp.conversation_is_mutation(action_type text) returns boolean language sql immutable as $$select action_type in ('save_document','request_document_ocr','update_document_category','update_document_tags','create_reminder','update_reminder','save_link','mark_inbox_reviewed','dismiss_inbox_item')$$;

create or replace function fp.conversation_requires_confirmation(action_type text,parameters jsonb,model_derived boolean) returns boolean
language sql immutable set search_path=pg_catalog,fp as $$
  select (model_derived and fp.conversation_is_mutation(action_type))
    or action_type='save_link'
    or action_type in ('dismiss_inbox_item','update_reminder')
    or (action_type='update_document_tags' and parameters->>'operation'='remove')
    or (action_type='update_document_category' and coalesce((parameters->>'ambiguous')::boolean,false))
    or (action_type in ('save_document','save_link') and coalesce((parameters->>'create_category')::boolean,false))
$$;

create or replace function fp.conversation_execution_public(input_row fp.conversation_executions) returns jsonb
language sql stable set search_path=pg_catalog,fp as $$
  select jsonb_build_object('execution_id',input_row.id,'state',input_row.status,'action_type',input_row.action_type,'result',input_row.result,'error_category',input_row.error_category,
    'confirmation',(select jsonb_build_object('id',c.id,'summary',c.summary,'target_label',c.target_label,'expires_at',c.expires_at) from fp.conversation_execution_confirmations c where c.execution_id=input_row.id and c.state='pending'))
$$;

create or replace function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare e fp.conversation_executions;uid uuid;hid uuid;role text;p jsonb;answer jsonb;category_id uuid;category_name text;attachment fp.conversation_attachments;doc fp.documents;job fp.document_analysis_jobs;rem fp.reminders;email fp.inbound_emails;link_category fp.saved_link_categories;link fp.saved_links;parsed jsonb;tags jsonb;new_tags jsonb;title text;source fp.manual_document_sources;
begin
  select * into e from fp.conversation_executions where id=execution for update;if e.id is null then raise exception 'execution unavailable' using errcode='P0002';end if;
  uid:=fp.current_user_id();hid:=fp.active_family_id();if e.user_id<>uid or e.household_id<>hid then raise exception 'not authorised' using errcode='42501';end if;
  select m.role into role from fp.members m where m.user_id=uid and m.household_id=hid and m.status='active' for share;if role is null then raise exception 'not authorised' using errcode='42501';end if;p:=e.action_parameters;
  if fp.conversation_is_mutation(e.action_type) and role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if e.action_type='search_family_content' then
    answer:=jsonb_build_object('message','Matching authorised records are shown below.','results',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category',c.name,'match_type',case when lower(coalesce(d.extracted_text,'')) like '%'||lower(trim(p->>'query'))||'%' then 'ocr' else 'metadata' end) order by d.updated_at desc) from fp.documents d join fp.categories c on c.id=d.category_id where d.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid)) and lower(concat_ws(' ',d.title,c.name,d.tags::text,d.source_name,d.extracted_text)) like '%'||lower(trim(p->>'query'))||'%' limit 12),'[]'::jsonb));
    if jsonb_array_length(answer->'results')=0 then answer:=jsonb_set(answer,'{message}','"I couldn’t find that in your FamilyDocuments account."');end if;
  elsif e.action_type='open_app_destination' then answer:=jsonb_build_object('message','Opened '||initcap(p->>'destination')||'.','destination',p->>'destination');
  elsif e.action_type='request_clarification' then answer:=jsonb_build_object('message',p->>'question','choices',coalesce(p->'choices','[]'::jsonb));
  elsif e.action_type='unsupported_request' then
    answer:=jsonb_build_object('message','I can help organise and find information in your FamilyDocuments account.','suggestions',jsonb_build_array(
      jsonb_build_object('label','Find a document','action',jsonb_build_object('id','suggestion-find-'||e.id,'type','request_clarification','version',1,'parameters',jsonb_build_object('question','What document should I find?','missing_parameter','search_query'))),
      jsonb_build_object('label','Save a link','action',jsonb_build_object('id','suggestion-link-'||e.id,'type','request_clarification','version',1,'parameters',jsonb_build_object('question','Paste the link you would like to save.','missing_parameter','url'))),
      jsonb_build_object('label','Create a reminder','action',jsonb_build_object('id','suggestion-reminder-'||e.id,'type','request_clarification','version',1,'parameters',jsonb_build_object('question','What should I remind you about, and when?','missing_parameter','reminder')))));
  elsif e.action_type='save_document' then
    select * into attachment from fp.conversation_attachments a where a.id=(p->>'attachment_id')::uuid and a.conversation_id=e.conversation_id and a.household_id=hid and a.user_id=uid and a.expires_at>now() for update;
    if attachment.id is null then raise exception 'attachment unavailable' using errcode='P0002';end if;
    select id,name into category_id,category_name from fp.categories where household_id=hid and lower(name)=lower(trim(p->>'category_name'));
    if category_id is null and coalesce((p->>'create_category')::boolean,false) then if role not in ('owner','family_admin') then raise exception 'not authorised' using errcode='42501';end if;insert into fp.categories(household_id,name,created_by) values(hid,trim(p->>'category_name'),uid) returning id,name into category_id,category_name;end if;
    if category_id is null then raise exception 'category not found' using errcode='22023';end if;
    title:=left(regexp_replace(attachment.file_name,'\.[^.]+$',''),160);
    insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,confirmation_status,storage_provider,original_filename,file_size,source_status,tags)
      values(hid,category_id,title,uid,attachment.file_name,attachment.sha256,attachment.mime_type,'confirmed','home_server',attachment.file_name,octet_length(attachment.content),'available',coalesce(p->'tags','[]'::jsonb)) returning * into doc;
    insert into fp.manual_document_sources(household_id,document_id,file_name,mime_type,content,sha256,created_by) values(hid,doc.id,attachment.file_name,attachment.mime_type,attachment.content,attachment.sha256,uid);
    delete from fp.conversation_attachments where id=attachment.id;answer:=jsonb_build_object('message','Saved '||doc.title||' in '||category_name||'.','document_id',doc.id,'title',doc.title,'category',category_name,'tags',doc.tags);
  elsif e.action_type='request_document_ocr' then
    if p?'attachment_id' then select * into attachment from fp.conversation_attachments a where a.id=(p->>'attachment_id')::uuid and a.conversation_id=e.conversation_id and a.household_id=hid and a.user_id=uid and a.expires_at>now() for update;
    else select d.* into doc from fp.documents d where d.id=(p->>'document_id')::uuid and d.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid and x.access_level in ('contribute','manage')));if doc.id is null then raise exception 'not authorised' using errcode='42501';end if;select * into source from fp.manual_document_sources where document_id=doc.id;attachment.file_name:=source.file_name;attachment.mime_type:=source.mime_type;attachment.content:=source.content;attachment.sha256:=source.sha256;end if;
    if attachment.content is null then raise exception 'attachment unavailable' using errcode='P0002';end if;
    perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||(p->>'mode')||':'||attachment.sha256,0));
    select j.* into job from fp.document_analysis_jobs j join fp.documents d on d.id=j.document_id where j.household_id=hid and j.requested_by=uid and j.mode=p->>'mode' and d.source_sha256=attachment.sha256 and j.status<>'dismissed' order by j.created_at desc limit 1;
    if job.id is null then
      if doc.id is null then select id into category_id from fp.categories where household_id=hid order by (lower(name)='documents') desc,is_system desc,name limit 1;insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,confirmation_status,storage_provider,original_filename,file_size,source_status) values(hid,category_id,left(regexp_replace(attachment.file_name,'\.[^.]+$',''),120),uid,attachment.file_name,attachment.sha256,attachment.mime_type,'confirmed','home_server',attachment.file_name,octet_length(attachment.content),'available') returning * into doc;insert into fp.manual_document_sources(household_id,document_id,file_name,mime_type,content,sha256,created_by) values(hid,doc.id,attachment.file_name,attachment.mime_type,attachment.content,attachment.sha256,uid);end if;
      insert into fp.document_analysis_jobs(household_id,document_id,requested_by,mode,idempotency_key) values(hid,doc.id,uid,p->>'mode',e.request_key) returning * into job;
    end if;
    if p?'attachment_id' then delete from fp.conversation_attachments where id=attachment.id;end if;answer:=jsonb_build_object('message','Your document is queued for reading.','job_id',job.id,'document_id',job.document_id,'status',job.status);
  elsif e.action_type in ('update_document_category','update_document_tags') then
    select d.* into doc from fp.documents d where d.id=(p->>'document_id')::uuid and d.household_id=hid and d.lifecycle_status='active' and (d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid and x.access_level='manage')) for update;
    if doc.id is null then raise exception 'not authorised' using errcode='42501';end if;if e.expected_target_version is null or doc.updated_at::text<>e.expected_target_version then raise exception 'stale target' using errcode='PT409';end if;
    if e.action_type='update_document_category' then select id,name into category_id,category_name from fp.categories where household_id=hid and lower(name)=lower(trim(p->>'category_name'));if category_id is null then raise exception 'category not found' using errcode='22023';end if;update fp.documents set category_id=category_id,updated_at=clock_timestamp() where id=doc.id returning * into doc;answer:=jsonb_build_object('message','Changed '||doc.title||' to '||category_name||'.','document_id',doc.id,'category',category_name,'tags',doc.tags,'updated_at',doc.updated_at);
    else select coalesce(jsonb_agg(distinct lower(trim(value)) order by lower(trim(value))),'[]'::jsonb) into tags from jsonb_array_elements_text(p->'tags');if p->>'operation'='add' then select coalesce(jsonb_agg(distinct value order by value),'[]'::jsonb) into new_tags from (select lower(trim(value)) value from jsonb_array_elements_text(doc.tags) union select value from jsonb_array_elements_text(tags))x;else select coalesce(jsonb_agg(value order by value),'[]'::jsonb) into new_tags from (select distinct lower(trim(value)) value from jsonb_array_elements_text(doc.tags) where lower(trim(value)) not in(select value from jsonb_array_elements_text(tags)))x;end if;update fp.documents set tags=new_tags,updated_at=clock_timestamp() where id=doc.id returning * into doc;answer:=jsonb_build_object('message','Updated the tags on '||doc.title||'.','document_id',doc.id,'tags',doc.tags,'updated_at',doc.updated_at);end if;
  elsif e.action_type='create_reminder' then
    if p?'document_id' and not exists(select 1 from fp.documents d where d.id=(p->>'document_id')::uuid and d.household_id=hid and d.lifecycle_status<>'deleted' and (d.created_by=uid or fp.is_household_admin(hid) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid and x.access_level in ('contribute','manage')))) then raise exception 'not authorised' using errcode='42501';end if;
    perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||e.request_key,0));
    select * into rem from fp.reminders r where r.household_id=hid and r.created_by=uid and r.client_request_id=e.request_key;
    if rem.id is null then insert into fp.reminders(household_id,document_id,title,due_at,due_time,due_time_zone,created_by,client_request_id) values(hid,case when p?'document_id' then (p->>'document_id')::uuid else null end,left(trim(p->>'title'),160),(p->>'due_date')::date,case when p?'due_time' then (p->>'due_time')::time else null end,'Pacific/Auckland',uid,e.request_key) returning * into rem;end if;
    answer:=jsonb_build_object('message','Reminder added: '||rem.title||'.','reminder_id',rem.id,'title',rem.title,'due_at',rem.due_at,'due_time',rem.due_time,'due_time_zone',rem.due_time_zone);
  elsif e.action_type='update_reminder' then
    select * into rem from fp.reminders r where r.id=(p->>'reminder_id')::uuid and r.household_id=hid for update;
    if rem.id is null or not fp.can_manage_reminder(rem) then raise exception 'not authorised' using errcode='42501';end if;
    if e.expected_target_version is null or rem.updated_at::text<>e.expected_target_version or rem.due_at is distinct from (p->>'expected_due_date')::date or rem.status<>'upcoming' then raise exception 'stale target' using errcode='PT409';end if;
    if p->>'operation'<>'one_week_before' or rem.due_at-7<=(now() at time zone 'Pacific/Auckland')::date then raise exception 'invalid reminder change' using errcode='22023';end if;
    update fp.reminders set original_due_at=coalesce(original_due_at,due_at),due_at=due_at-7,updated_at=clock_timestamp() where id=rem.id returning * into rem;
    answer:=jsonb_build_object('message','Updated '||rem.title||'.','reminder_id',rem.id,'title',rem.title,'due_at',rem.due_at,'due_time',rem.due_time,'due_time_zone',rem.due_time_zone,'updated_at',rem.updated_at);
  elsif e.action_type='save_link' then
    parsed:=fp.normalise_saved_link_url(p->>'url');perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||uid::text||':'||(parsed->>'hash'),0));select * into link_category from fp.saved_link_categories c where c.household_id=hid and c.owner_user_id=uid and c.status='active' and lower(c.name)=lower(trim(p->>'category_name'));
    if link_category.id is null and coalesce((p->>'create_category')::boolean,false) then insert into fp.saved_link_categories(household_id,owner_user_id,name) values(hid,uid,trim(p->>'category_name')) returning * into link_category;end if;if link_category.id is null then raise exception 'category not found' using errcode='22023';end if;
    select * into link from fp.saved_links where household_id=hid and owner_user_id=uid and normalized_url_hash=parsed->>'hash' and status='active' order by created_at limit 1;
    if link.id is null then insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title,note) values(hid,uid,link_category.id,parsed->>'url',parsed->>'hash',parsed->>'host',left(coalesce(nullif(trim(p->>'title'),''),parsed->>'host'),160),null) returning * into link;insert into fp.saved_link_security_events(household_id,owner_user_id,actor_user_id,link_id,event_type) values(hid,uid,uid,link.id,'created');end if;
    answer:=jsonb_build_object('message','Saved '||link.title||' in '||link_category.name||'.','link_id',link.id,'title',link.title,'category',link_category.name,'domain',link.source_host,'duplicate',link.created_at<e.created_at);
  elsif e.action_type in ('mark_inbox_reviewed','dismiss_inbox_item') then
    select * into email from fp.inbound_emails i where i.id=(p->>'inbox_id')::uuid and i.household_id=hid and i.deleted_at is null for update;if email.id is null or not fp.inbox_can_edit(role) then raise exception 'not authorised' using errcode='42501';end if;if e.expected_target_version is null or email.review_updated_at::text<>e.expected_target_version then raise exception 'stale target' using errcode='PT409';end if;update fp.inbound_emails set review_state=case when e.action_type='dismiss_inbox_item' then 'dismissed' else 'reviewed' end,reviewed_at=case when e.action_type='mark_inbox_reviewed' then now() else null end,reviewed_by=case when e.action_type='mark_inbox_reviewed' then uid else null end,review_updated_at=clock_timestamp() where id=email.id returning * into email;answer:=jsonb_build_object('message',case when e.action_type='dismiss_inbox_item' then 'Dismissed the Inbox item.' else 'Marked the Inbox item as reviewed.' end,'inbox_id',email.id,'review_state',email.review_state,'updated_at',email.review_updated_at);
  else raise exception 'unsupported execution' using errcode='22023';end if;
  return answer;
end$$;

create or replace function fp.submit_conversation_action(conversation uuid,action_id text,action_type text,action_version integer,parameters jsonb,request_key text,model_derived boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare current fp.conversations;e fp.conversation_executions;proposal_digest text;digest text;requires_confirmation boolean;target_type text;target_id uuid;expected text;summary text;label text;answer jsonb;parsed jsonb;role text;category_exists boolean;stage text:='execute_mutation';uid uuid:=fp.current_user_id();
begin
  perform 1 from fp.active_family_contexts a where a.user_id=uid for update;
  select * into current from fp.conversation_member(conversation);if current.id is null or current.status<>'active' then raise exception 'conversation not available' using errcode='42501';end if;
  select m.role into role from fp.members m where m.user_id=uid and m.household_id=current.household_id and m.status='active' for share;
  if action_version<>1 or action_id !~ '^[A-Za-z0-9:_-]{8,100}$' or request_key !~ '^[A-Za-z0-9:_-]{8,100}$' then raise exception 'invalid action envelope' using errcode='22023';end if;
  perform fp.assert_conversation_action_v1(action_type,parameters);proposal_digest:=fp.conversation_action_digest(action_type,action_version,parameters);
  select * into e from fp.conversation_executions x where x.household_id=current.household_id and x.user_id=current.user_id and x.request_key=submit_conversation_action.request_key for update;
  if e.id is not null then if e.proposal_digest<>proposal_digest then raise exception 'idempotency key reused for different action' using errcode='PT409';end if;return fp.conversation_execution_public(e)||jsonb_build_object('duplicate',true);end if;
  if parameters?'document_id' then target_type:='document';target_id:=(parameters->>'document_id')::uuid;select d.updated_at::text,d.title into expected,label from fp.documents d where d.id=target_id and d.household_id=current.household_id and d.lifecycle_status<>'deleted';
  elsif parameters?'reminder_id' then target_type:='reminder';target_id:=(parameters->>'reminder_id')::uuid;select r.updated_at::text,r.title into expected,label from fp.reminders r where r.id=target_id and r.household_id=current.household_id;
  elsif parameters?'inbox_id' then target_type:='inbox';target_id:=(parameters->>'inbox_id')::uuid;select i.review_updated_at::text,i.subject into expected,label from fp.inbound_emails i where i.id=target_id and i.household_id=current.household_id and i.deleted_at is null;end if;
  if target_id is not null and expected is null then raise exception 'target unavailable' using errcode='42501';end if;
  parameters:=parameters- 'expected_updated_at';if target_type in ('document','inbox') then parameters:=parameters||jsonb_build_object('expected_updated_at',expected);end if;digest:=fp.conversation_action_digest(action_type,action_version,parameters);
  if action_type='save_link' then parsed:=fp.normalise_saved_link_url(parameters->>'url');label:=parsed->>'host';end if;
  if fp.conversation_is_mutation(action_type) and role not in ('owner','family_admin','adult_member','contributor') then
    answer:=jsonb_build_object('message','You do not have permission to make that change.');
    insert into fp.conversation_executions(conversation_id,household_id,user_id,request_key,action_id,action_type,action_version,action_parameters,proposal_digest,action_digest,model_derived,target_type,target_id,expected_target_version,status,result,error_category)
      values(current.id,current.household_id,current.user_id,request_key,action_id,action_type,action_version,parameters,proposal_digest,digest,model_derived,target_type,target_id,expected,'failed_before_mutation',answer,'permission_denied') returning * into e;
    insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status) values(current.household_id,current.user_id,current.id,action_type,digest,'failed_before_mutation');
    perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'error',answer->>'message',jsonb_build_object('execution_id',e.id,'error_category','permission_denied'));
    return fp.conversation_execution_public(e);
  end if;
  if action_type='save_link' and not coalesce((parameters->>'create_category')::boolean,false) then
    select exists(select 1 from fp.saved_link_categories c where c.household_id=current.household_id and c.owner_user_id=current.user_id and c.status='active' and lower(c.name)=lower(trim(parameters->>'category_name'))) into category_exists;
    if not category_exists then
      answer:=jsonb_build_object('message','Your Family doesn’t have a '||trim(parameters->>'category_name')||' link category yet.','suggestions',jsonb_build_array(jsonb_build_object('label','Create and save','action',jsonb_build_object('id','suggestion-create-'||gen_random_uuid(),'type','save_link','version',1,'parameters',parameters||jsonb_build_object('create_category',true)))));
      insert into fp.conversation_executions(conversation_id,household_id,user_id,request_key,action_id,action_type,action_version,action_parameters,proposal_digest,action_digest,model_derived,status,result)
        values(current.id,current.household_id,current.user_id,request_key,action_id,action_type,action_version,parameters,proposal_digest,digest,model_derived,'awaiting_clarification',answer) returning * into e;
      perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'clarification',answer->>'message',jsonb_build_object('action',jsonb_build_object('id',action_id,'type',action_type,'version',action_version,'parameters',parameters),'suggestions',answer->'suggestions'));
      return fp.conversation_execution_public(e);
    end if;
  end if;
  requires_confirmation:=fp.conversation_requires_confirmation(action_type,parameters,model_derived);
  insert into fp.conversation_executions(conversation_id,household_id,user_id,request_key,action_id,action_type,action_version,action_parameters,proposal_digest,action_digest,model_derived,target_type,target_id,expected_target_version,status)
    values(current.id,current.household_id,current.user_id,request_key,action_id,action_type,action_version,parameters,proposal_digest,digest,model_derived,target_type,target_id,expected,case when action_type='request_clarification' then 'awaiting_clarification' when requires_confirmation then 'awaiting_confirmation' else 'executing' end) returning * into e;
  if action_type='request_clarification' then
    answer:=jsonb_build_object('message',parameters->>'question','choices',coalesce(parameters->'choices','[]'::jsonb));
    update fp.conversation_executions set result=answer,updated_at=clock_timestamp() where id=e.id returning * into e;
    perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'clarification',parameters->>'question',jsonb_build_object('action',jsonb_build_object('id',action_id,'type',action_type,'version',action_version,'parameters',parameters),'choices',coalesce(parameters->'choices','[]'::jsonb)));
    return fp.conversation_execution_public(e);
  end if;
  if requires_confirmation then
    if (select count(*) from fp.conversation_execution_confirmations p where p.household_id=current.household_id and p.user_id=current.user_id and p.state='pending' and p.expires_at>now())>=10 then raise exception 'pending confirmation quota reached' using errcode='PT429';end if;
    summary:=case action_type when 'dismiss_inbox_item' then 'Dismiss this Inbox item?' when 'update_reminder' then 'Update this reminder as requested?' when 'update_document_tags' then 'Remove the selected tags?' when 'update_document_category' then 'Change this document’s category?' when 'save_document' then 'Create the category and save this document?' when 'save_link' then 'Save this link to '||label||'?' else 'Confirm this change?' end;
    insert into fp.conversation_execution_confirmations(execution_id,conversation_id,household_id,user_id,action_digest,target_type,target_id,expected_target_version,idempotency_key,summary,target_label,expires_at)
      values(e.id,current.id,current.household_id,current.user_id,digest,target_type,target_id,expected,request_key,summary,coalesce(nullif(label,''),'Selected item'),now()+interval '10 minutes');
    perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'confirmation',summary,jsonb_build_object('execution_id',e.id));return fp.conversation_execution_public(e);
  end if;
  begin
    stage:='execute_mutation';answer:=fp.run_conversation_execution(e.id);stage:='persist_execution';update fp.conversation_executions set status='succeeded',result=answer,updated_at=clock_timestamp() where id=e.id returning * into e;
    stage:='persist_security_receipt';
    insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status) values(current.household_id,current.user_id,current.id,action_type,digest,'succeeded');
    stage:='persist_transcript';perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'result',coalesce(answer->>'message','Completed.'),answer-'message');
  exception when others then
    update fp.conversation_executions set status=case when sqlstate in ('40001','PT409') then 'retryable' else 'failed_before_mutation' end,error_category=case when sqlstate='42501' then 'permission_denied' when sqlstate in ('40001','PT409') then 'stale_target' when sqlstate='P0002' then 'not_found' when stage<>'execute_mutation' then stage else 'action_rejected' end,result=jsonb_build_object('message',case when sqlstate in ('40001','PT409') then 'This item changed. Review it before trying again.' when sqlstate='42501' then 'You no longer have permission to change that item.' else 'That action could not be completed.' end),updated_at=clock_timestamp() where id=e.id returning * into e;
    insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status) values(current.household_id,current.user_id,current.id,action_type,digest,e.status);
    perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'error',e.result->>'message',jsonb_build_object('execution_id',e.id,'error_category',e.error_category));
  end;
  return fp.conversation_execution_public(e);
end$$;

create or replace function fp.decide_conversation_confirmation(confirmation uuid,decision text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare c fp.conversation_execution_confirmations;e fp.conversation_executions;current fp.conversations;answer jsonb;actual text;uid uuid:=fp.current_user_id();
begin
  select * into c from fp.conversation_execution_confirmations x where x.id=confirmation for update;if c.id is null then raise exception 'confirmation unavailable' using errcode='PT404';end if;
  perform 1 from fp.active_family_contexts a where a.user_id=uid for update;
  select * into current from fp.conversation_member(c.conversation_id);if current.id is null or current.user_id<>c.user_id or current.household_id<>c.household_id then raise exception 'not authorised' using errcode='42501';end if;
  select * into e from fp.conversation_executions where id=c.execution_id for update;
  if c.state in ('succeeded','failed','cancelled','expired') then return fp.conversation_execution_public(e)||jsonb_build_object('duplicate',true);end if;
  if c.expires_at<=now() then update fp.conversation_execution_confirmations set state='expired',consumed_at=now() where id=c.id;update fp.conversation_executions set status='expired',result='{"message":"That confirmation expired. Please review the action again."}',updated_at=now() where id=e.id returning * into e;return fp.conversation_execution_public(e);end if;
  if decision='cancel' then update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where id=c.id;update fp.conversation_executions set status='cancelled',result='{"message":"Okay, I didn’t make that change."}',updated_at=now() where id=e.id returning * into e;perform fp.append_authoritative_conversation_message(current,'decision-'||c.id,'result',e.result->>'message','{}');return fp.conversation_execution_public(e);end if;
  if decision<>'confirm' then raise exception 'invalid decision' using errcode='22023';end if;
  if fp.conversation_action_digest(e.action_type,e.action_version,e.action_parameters)<>c.action_digest or e.action_digest<>c.action_digest then raise exception 'confirmation binding failed' using errcode='PT409';end if;
  if c.target_type='document' then select updated_at::text into actual from fp.documents where id=c.target_id and household_id=c.household_id and lifecycle_status<>'deleted';elsif c.target_type='inbox' then select review_updated_at::text into actual from fp.inbound_emails where id=c.target_id and household_id=c.household_id and deleted_at is null;elsif c.target_type='reminder' then select updated_at::text into actual from fp.reminders where id=c.target_id and household_id=c.household_id;end if;
  if c.target_id is not null and actual is distinct from c.expected_target_version then update fp.conversation_execution_confirmations set state='failed',consumed_at=now() where id=c.id;update fp.conversation_executions set status='retryable',error_category='stale_target',result='{"message":"This item changed. Review it before trying again."}',updated_at=now() where id=e.id returning * into e;return fp.conversation_execution_public(e);end if;
  update fp.conversation_execution_confirmations set state='executing' where id=c.id;update fp.conversation_executions set status='executing',updated_at=now() where id=e.id;
  begin
    answer:=fp.run_conversation_execution(e.id);update fp.conversation_executions set status='succeeded',result=answer,updated_at=clock_timestamp() where id=e.id returning * into e;update fp.conversation_execution_confirmations set state='succeeded',consumed_at=now() where id=c.id;
    insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status) values(e.household_id,e.user_id,e.conversation_id,e.action_type,e.action_digest,'succeeded');
    perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'result',coalesce(answer->>'message','Completed.'),answer-'message');
  exception when others then
    update fp.conversation_execution_confirmations set state='failed',consumed_at=now() where id=c.id;update fp.conversation_executions set status=case when sqlstate in ('40001','PT409') then 'retryable' else 'failed_before_mutation' end,error_category=case when sqlstate='42501' then 'permission_denied' when sqlstate in ('40001','PT409') then 'stale_target' else 'action_rejected' end,result=jsonb_build_object('message',case when sqlstate in ('40001','PT409') then 'This item changed. Review it before trying again.' when sqlstate='42501' then 'You no longer have permission to change that item.' else 'That action could not be completed.' end),updated_at=clock_timestamp() where id=e.id returning * into e;insert into fp.conversation_security_receipts(household_id,user_id,conversation_id,action_type,action_digest,status) values(e.household_id,e.user_id,e.conversation_id,e.action_type,e.action_digest,e.status);perform fp.append_authoritative_conversation_message(current,'outcome-'||e.id,'error',e.result->>'message',jsonb_build_object('error_category',e.error_category));
  end;
  return fp.conversation_execution_public(e);
end$$;

create or replace function fp.record_conversation_job_transition(conversation uuid,job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare current fp.conversations;j fp.document_analysis_jobs;d fp.documents;status_text text;correlation text;prior text;content text;data jsonb;
begin
  select * into current from fp.conversation_member(conversation);select x.* into j from fp.document_analysis_jobs x where x.id=job and x.household_id=current.household_id and x.requested_by=current.user_id;select doc.* into d from fp.documents doc where doc.id=j.document_id and doc.household_id=current.household_id;if j.id is null or d.id is null then raise exception 'job unavailable' using errcode='42501';end if;
  status_text:=case when j.status='succeeded' then 'finished' when j.status in ('failed','permanent_failed') then 'failed' else j.status end;correlation:='ocr:'||j.id;
  select message_data->>'status' into prior from fp.conversation_messages where conversation_id=current.id and message_data->>'correlation_id'=correlation order by created_at desc limit 1;
  if prior=status_text then return jsonb_build_object('changed',false,'status',status_text);end if;
  content:=case when status_text='finished' then 'Finished reading your document.' when status_text='failed' then 'I couldn’t read that document.' when status_text='queued' then 'Your document is queued for reading.' else 'Reading your document…' end;
  data:=jsonb_strip_nulls(jsonb_build_object('correlation_id',correlation,'status',status_text,'job_id',j.id,'document_id',j.document_id,'category',j.result->>'category','tags',j.result->'tags'));
  perform fp.append_authoritative_conversation_message(current,'progress-'||j.id||'-'||status_text,case when status_text='finished' then 'result' when status_text='failed' then 'error' else 'progress' end,content,data);
  return jsonb_build_object('changed',true,'status',status_text,'message',content,'data',data);
end$$;

create or replace function fp.consume_conversation_rate_limit(bucket_name text,request_limit integer default 10,window_seconds integer default 60) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();row fp.conversation_rate_limits;now_at timestamptz:=clock_timestamp();
begin
  if bucket_name !~ '^[a-z0-9_-]{2,40}$' or request_limit not between 1 and 100 or window_seconds not between 10 and 3600 then raise exception 'invalid rate limit' using errcode='22023';end if;
  insert into fp.conversation_rate_limits(household_id,user_id,bucket,window_started_at,request_count) values(hid,uid,bucket_name,now_at,1)
    on conflict(household_id,user_id,bucket) do update set window_started_at=case when fp.conversation_rate_limits.window_started_at<=now_at-make_interval(secs=>window_seconds) then now_at else fp.conversation_rate_limits.window_started_at end,request_count=case when fp.conversation_rate_limits.window_started_at<=now_at-make_interval(secs=>window_seconds) then 1 else fp.conversation_rate_limits.request_count+1 end returning * into row;
  return jsonb_build_object('allowed',row.request_count<=request_limit,'remaining',greatest(request_limit-row.request_count,0),'family_id',hid);
end$$;

create or replace function fp.delete_conversation(conversation uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$declare current fp.conversations;begin select * into current from fp.conversation_member(conversation);if current.id is null then raise exception 'conversation unavailable' using errcode='42501';end if;update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where conversation_id=current.id and state in ('pending','executing');delete from fp.conversations where id=current.id;delete from fp.conversation_security_receipts where created_at<now()-interval '365 days';return jsonb_build_object('deleted',true);end$$;

create or replace function fp.conversation_workspace(conversation uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;selected fp.conversations;
begin
  hid:=fp.active_family_id(false);
  if hid is null then return jsonb_build_object('conversation',null,'messages','[]'::jsonb,'pending_confirmation',null,'family_selection_required',true);end if;
  if conversation is null then select * into selected from fp.conversations c where c.household_id=hid and c.user_id=uid and c.status='active' order by c.updated_at desc limit 1;
  else select * into selected from fp.conversations c where c.id=conversation and c.household_id=hid and c.user_id=uid;end if;
  if selected.id is null then return jsonb_build_object('conversation',null,'messages','[]'::jsonb,'pending_confirmation',null,'family_selection_required',false);end if;
  return jsonb_build_object(
    'conversation',jsonb_build_object('id',selected.id,'status',selected.status,'created_at',selected.created_at,'updated_at',selected.updated_at,'family_id',selected.household_id),
    'messages',coalesce((select jsonb_agg(value order by created_at,id) from(select m.created_at,m.id,jsonb_build_object('id',m.id,'client_message_id',m.client_message_id,'role',m.role,'kind',m.kind,'content',m.content,'data',m.message_data,'created_at',m.created_at) value from fp.conversation_messages m where m.conversation_id=selected.id order by m.created_at desc,m.id desc limit 60) recent),'[]'::jsonb),
    'pending_confirmation',(select jsonb_build_object('id',p.id,'summary',p.summary,'target_label',p.target_label,'expires_at',p.expires_at) from fp.conversation_execution_confirmations p where p.conversation_id=selected.id and p.state='pending' and p.expires_at>now() order by p.created_at desc limit 1),
    'family_selection_required',false
  );
end$$;

revoke execute on function fp.append_authoritative_conversation_message(fp.conversations,text,text,text,jsonb),fp.conversation_action_digest(text,integer,jsonb),fp.assert_conversation_action_v1(text,jsonb),fp.conversation_is_mutation(text),fp.conversation_requires_confirmation(text,jsonb,boolean),fp.conversation_execution_public(fp.conversation_executions),fp.run_conversation_execution(uuid) from public,anon,authenticated;
revoke execute on function fp.set_conversation_confirmation(uuid,text,text,integer,jsonb,text,text,timestamptz),fp.consume_conversation_confirmation(uuid,text,boolean),fp.record_conversation_action(uuid,text,text,text,text,uuid,jsonb) from authenticated;
revoke execute on function fp.active_family_id(boolean),fp.active_family_workspace(),fp.select_active_family(uuid),fp.stage_conversation_attachment(uuid,text,text,text),fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean),fp.decide_conversation_confirmation(uuid,text),fp.record_conversation_job_transition(uuid,uuid),fp.consume_conversation_rate_limit(text,integer,integer),fp.delete_conversation(uuid) from public,anon,authenticated;
grant execute on function fp.active_family_workspace(),fp.select_active_family(uuid),fp.record_conversation_job_transition(uuid,uuid),fp.delete_conversation(uuid) to authenticated;
grant execute on function fp.consume_conversation_rate_limit(text,integer,integer) to service_role;
grant execute on function fp.stage_conversation_attachment(uuid,text,text,text),fp.submit_conversation_action(uuid,text,text,integer,jsonb,text,boolean),fp.decide_conversation_confirmation(uuid,text) to service_role;

comment on table fp.conversations is 'User conversations: at most 100 retained per user/Family; inactive transcripts are eligible for deletion after 90 days.';
comment on table fp.conversation_messages is 'Bounded conversation transcript. The trusted API retains at most 60 messages per active conversation.';
comment on table fp.conversation_action_receipts is 'Legacy Phase 2D receipts. Authenticated client writes are revoked by migration 047.';
comment on table fp.conversation_security_receipts is 'Minimized security receipts retained independently of transcripts for up to 365 days.';

commit;
