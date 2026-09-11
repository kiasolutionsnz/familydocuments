begin;

alter table fp.transport_attachments
  add column provider_file_unique_id text,
  add column verified_mime_type text,
  add column verified_size bigint,
  add column actor_user_id uuid,
  add column household_id uuid references fp.households(id) on delete cascade,
  add column state text not null default 'pending',
  add column attempt integer not null default 0,
  add column lease_token uuid,
  add column lease_expires_at timestamptz,
  add column failure_category text,
  add column staging_key text,
  add column conversation_attachment_id uuid,
  add column downloaded_at timestamptz,
  add column completed_at timestamptz,
  add column expires_at timestamptz not null default (now()+interval '24 hours'),
  add column cleaned_at timestamptz;

alter table fp.transport_attachments drop constraint if exists transport_attachments_declared_size_check;
alter table fp.transport_attachments add constraint transport_attachments_declared_size_check check(declared_size between 0 and 20971520);

alter table fp.transport_attachments
  add constraint transport_attachment_unique_id_safe check(provider_file_unique_id is null or char_length(provider_file_unique_id) between 1 and 300),
  add constraint transport_attachment_verified_type check(verified_mime_type is null or verified_mime_type in ('application/pdf','image/jpeg','image/png')),
  add constraint transport_attachment_verified_size check(verified_size is null or verified_size between 1 and 5242880),
  add constraint transport_attachment_state check(state in ('pending','downloading','staged','accepted','terminal_failure','completed','expired')),
  add constraint transport_attachment_attempt check(attempt between 0 and 10),
  add constraint transport_attachment_failure check(failure_category is null or failure_category in ('too_large','download_failed','truncated','unsupported_type','mime_mismatch','permission_denied','expired')),
  add constraint transport_attachment_staging_key check(staging_key is null or staging_key ~ '^[0-9a-f-]{36}\.(pdf|png|jpg)$');
create index transport_attachments_cleanup on fp.transport_attachments(expires_at) where cleaned_at is null;

create table fp.transport_inbox_items(
  id uuid primary key default gen_random_uuid(),
  update_id uuid not null unique references fp.transport_updates(id) on delete cascade,
  attachment_id uuid references fp.transport_attachments(id) on delete set null,
  actor_user_id uuid not null,
  household_id uuid not null references fp.households(id) on delete cascade,
  source text not null default 'Telegram' check(source='Telegram'),
  safe_sender text not null check(char_length(safe_sender) between 1 and 160),
  safe_subject text not null check(char_length(safe_subject) between 1 and 200),
  safe_preview text not null default '' check(char_length(safe_preview)<=220),
  review_state text not null default 'unreviewed' check(review_state in ('unreviewed','reviewed','dismissed')),
  reason text not null check(reason in ('attachment_needs_decision','action_failed','clarification_deferred')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table fp.transport_inbox_items enable row level security;
alter table fp.transport_inbox_items force row level security;
revoke all on fp.transport_inbox_items from public,anon,authenticated;
create index transport_inbox_family_state on fp.transport_inbox_items(household_id,review_state,created_at desc);

create table fp.transport_job_notifications(
  identity_link_id uuid not null references fp.external_identity_links(id) on delete cascade,
  job_id uuid not null references fp.document_analysis_jobs(id) on delete cascade,
  job_state text not null check(job_state in ('processing','finished','failed')),
  created_at timestamptz not null default now(),
  primary key(identity_link_id,job_id,job_state)
);
alter table fp.transport_job_notifications enable row level security;
alter table fp.transport_job_notifications force row level security;
revoke all on fp.transport_job_notifications from public,anon,authenticated;

create or replace function fp.ingest_telegram_update(bot_identity text,telegram_update_id bigint,telegram_user text,telegram_chat text,kind text,envelope jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.transport_updates; inserted boolean:=true; file jsonb; photo jsonb;
begin
  if bot_identity is null or char_length(bot_identity) not between 1 and 80 or telegram_update_id<0 or kind not in ('message','callback_query') or jsonb_typeof(envelope)<>'object' or octet_length(envelope::text)>65536 then raise exception 'invalid update' using errcode='22023';end if;
  insert into fp.transport_updates(provider,provider_tenant,provider_update_id,provider_user_id,private_chat_id,update_kind,envelope) values('telegram',bot_identity,telegram_update_id,telegram_user,telegram_chat,kind,envelope)
    on conflict(provider,provider_tenant,provider_update_id) do nothing returning * into row;
  if row.id is null then inserted:=false; select * into row from fp.transport_updates where provider='telegram' and provider_tenant=bot_identity and provider_update_id=telegram_update_id;end if;
  if inserted and kind='message' then
    file:=envelope->'message'->'document';
    if file is null and jsonb_array_length(coalesce(envelope->'message'->'photo','[]'::jsonb))>0 then select value into photo from jsonb_array_elements(envelope->'message'->'photo') order by coalesce((value->>'file_size')::bigint,0) desc limit 1;file:=photo;end if;
    if file is not null and nullif(file->>'file_id','') is not null then
      insert into fp.transport_attachments(update_id,provider_file_id,provider_file_unique_id,file_name,declared_mime_type,declared_size)
      values(row.id,left(file->>'file_id',300),left(nullif(file->>'file_unique_id',''),300),left(coalesce(nullif(file->>'file_name',''),'Telegram attachment'),255),nullif(file->>'mime_type',''),case when file->>'file_size' ~ '^[0-9]+$' then (file->>'file_size')::bigint end)
      on conflict(update_id,provider_file_id) do nothing;
    end if;
  end if;
  return jsonb_build_object('id',row.id,'accepted',inserted,'duplicate',not inserted);
end$$;

create or replace function fp.claim_telegram_attachment(update_record uuid,worker_lease uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare a fp.transport_attachments;u fp.transport_updates;l fp.external_identity_links;
begin
  select * into u from fp.transport_updates where id=update_record and state='processing' and lease_token=worker_lease and lease_expires_at>now() for update;
  if u.id is null then raise exception 'lease unavailable' using errcode='40001';end if;
  select * into a from fp.transport_attachments where update_id=u.id for update;
  if a.id is null then return null;end if;
  select * into l from fp.external_identity_links where provider='telegram' and provider_tenant=u.provider_tenant and provider_user_id=u.provider_user_id and private_chat_id=u.private_chat_id and revoked_at is null;
  if l.id is null or not exists(select 1 from fp.members where user_id=l.user_id and household_id=l.household_id and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  update fp.transport_attachments set actor_user_id=l.user_id,household_id=l.household_id,state='downloading',attempt=attempt+1,lease_token=worker_lease,lease_expires_at=now()+interval '90 seconds' where id=a.id returning * into a;
  return jsonb_build_object('id',a.id,'file_id',a.provider_file_id,'file_unique_id',a.provider_file_unique_id,'file_name',a.file_name,'declared_mime_type',a.declared_mime_type,'declared_size',a.declared_size,'state',a.state,'staging_key',a.staging_key,'checksum',a.sha256,'verified_mime_type',a.verified_mime_type,'verified_size',a.verified_size);
end$$;

create or replace function fp.consume_telegram_callback(bot_identity text,telegram_user text,telegram_chat text,nonce text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare row fp.transport_callbacks;link fp.external_identity_links;
begin
  if nonce !~ '^[0-9a-f]{36}$' then raise exception 'invalid callback' using errcode='22023';end if;
  select c.* into row from fp.transport_callbacks c where c.nonce_hash=encode(digest(nonce,'sha256'),'hex') for update;
  select l.* into link from fp.external_identity_links l join fp.members m on m.user_id=l.user_id and m.household_id=l.household_id and m.status='active'
    where l.id=row.identity_link_id and l.provider_tenant=bot_identity and l.provider_user_id=telegram_user and l.private_chat_id=telegram_chat and l.revoked_at is null;
  if row.id is null or link.id is null or row.consumed_at is not null or row.expires_at<=now() then raise exception 'callback unavailable' using errcode='PT410';end if;
  update fp.transport_callbacks set consumed_at=now() where id=row.id;
  return jsonb_build_object('type',row.callback_type,'identity_link_id',link.id,'reference_id',row.bound_reference,'value',row.bound_value,'conversation_id',row.conversation_id,'user_id',link.user_id,'family_id',link.household_id);
end$$;

create or replace function fp.stage_telegram_attachment(attachment uuid,worker_lease uuid,verified_type text,byte_size bigint,file_checksum text,stage_key text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare a fp.transport_attachments;
begin
  update fp.transport_attachments set state='staged',verified_mime_type=verified_type,verified_size=byte_size,sha256=file_checksum,staging_key=stage_key,downloaded_at=now(),lease_expires_at=now()+interval '15 minutes'
  where id=attachment and state='downloading' and lease_token=worker_lease and lease_expires_at>now() and verified_type in ('application/pdf','image/jpeg','image/png') and byte_size between 1 and 5242880 and file_checksum ~ '^[0-9a-f]{64}$' and stage_key ~ '^[0-9a-f-]{36}\.(pdf|png|jpg)$' returning * into a;
  if a.id is null then raise exception 'attachment lease unavailable' using errcode='40001';end if;
  return jsonb_build_object('id',a.id,'staging_key',a.staging_key,'checksum',a.sha256);
end$$;

create or replace function fp.finish_telegram_attachment(attachment uuid,worker_lease uuid,staged_attachment uuid default null) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  update fp.transport_attachments set state='completed',conversation_attachment_id=coalesce(staged_attachment,conversation_attachment_id),completed_at=now(),lease_token=null,lease_expires_at=null,cleaned_at=case when staging_key is null then cleaned_at else now() end,staging_key=null where id=attachment and state in ('staged','accepted') and lease_token=worker_lease;return found;
end$$;

create or replace function fp.fail_telegram_attachment(attachment uuid,worker_lease uuid,category text,terminal boolean) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  update fp.transport_attachments set state=case when terminal then 'terminal_failure' else 'pending' end,failure_category=category,lease_token=null,lease_expires_at=null,cleaned_at=case when terminal and staging_key is not null then now() else cleaned_at end,staging_key=case when terminal then null else staging_key end where id=attachment and lease_token=worker_lease;return found;
end$$;

create or replace function fp.telegram_cancel_pending(bot_identity text,telegram_user text,telegram_chat text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare l fp.external_identity_links;b fp.transport_conversation_bindings;changed integer:=0;
begin
  select * into l from fp.external_identity_links where provider='telegram' and provider_tenant=bot_identity and provider_user_id=telegram_user and private_chat_id=telegram_chat and revoked_at is null for update;
  if l.id is null then return jsonb_build_object('linked',false,'cancelled',false);end if;
  if not exists(select 1 from fp.members where user_id=l.user_id and household_id=l.household_id and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  select * into b from fp.transport_conversation_bindings where identity_link_id=l.id;
  update fp.conversation_executions set status='cancelled',result='{"message":"Okay, cancelled."}'::jsonb,updated_at=now() where conversation_id=b.conversation_id and status in ('awaiting_clarification','awaiting_confirmation');get diagnostics changed=row_count;
  update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where conversation_id=b.conversation_id and state='pending';
  update fp.transport_callbacks set consumed_at=now() where identity_link_id=l.id and consumed_at is null;
  return jsonb_build_object('linked',true,'cancelled',changed>0);
end$$;

create or replace function fp.prepare_telegram_category_clarification(identity_link uuid,clarification uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare l fp.external_identity_links;e fp.conversation_executions;choices jsonb:='[]'::jsonb;actions jsonb:='[]'::jsonb;item record;parameters jsonb;action jsonb;prefix text;
begin
  select * into l from fp.external_identity_links where id=identity_link and revoked_at is null;
  select * into e from fp.conversation_executions where id=clarification and conversation_id in(select conversation_id from fp.transport_conversation_bindings where identity_link_id=l.id) and household_id=l.household_id and user_id=l.user_id and status='awaiting_clarification' for update;
  if l.id is null or e.id is null or not exists(select 1 from fp.members where user_id=l.user_id and household_id=l.household_id and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  parameters:=e.action_parameters;
  if parameters->>'missing_parameter'<>'category_name' then return jsonb_build_object('choices',coalesce(parameters->'choices','[]'::jsonb),'choice_actions',coalesce(parameters->'choice_actions','[]'::jsonb));end if;
  if parameters->>'attachment_id' is not null then
    prefix:='telegram-doc-category-';
    for item in select c.id,c.name from fp.categories c where c.household_id=l.household_id order by c.is_system desc,c.name limit 8 loop
      action:=jsonb_build_object('id',prefix||replace(item.id::text,'-',''),'type','save_document','version',1,'parameters',jsonb_build_object('attachment_id',parameters->>'attachment_id','category_name',item.name,'tags',coalesce(parameters->'tags','[]'::jsonb)));
      choices:=choices||to_jsonb(item.name);actions:=actions||jsonb_build_array(action);
    end loop;
  elsif parameters->>'link_url' is not null then
    prefix:='telegram-link-category-';
    for item in select c.id,c.name from fp.saved_link_categories c where c.household_id=l.household_id and c.owner_user_id=l.user_id and c.status='active' order by c.name limit 8 loop
      action:=jsonb_build_object('id',prefix||replace(item.id::text,'-',''),'type','save_link','version',1,'parameters',jsonb_build_object('url',parameters->>'link_url','title',coalesce(nullif(parameters->>'link_title',''),parameters->>'link_url'),'category_name',item.name));
      choices:=choices||to_jsonb(item.name);actions:=actions||jsonb_build_array(action);
    end loop;
  end if;
  update fp.conversation_executions set action_parameters=action_parameters||jsonb_build_object('choices',choices,'choice_actions',actions,'_trusted_transport_choices',true),updated_at=now() where id=e.id;
  update fp.conversation_messages set message_data=message_data||jsonb_build_object('choices',choices,'choice_actions',actions) where conversation_id=e.conversation_id and message_data->>'clarification_id'=e.id::text;
  return jsonb_build_object('choices',choices,'choice_actions',actions);
end$$;

create or replace function fp.telegram_pending_clarification(identity_link uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare l fp.external_identity_links;b fp.transport_conversation_bindings;e fp.conversation_executions;
begin
  select * into l from fp.external_identity_links where id=identity_link and revoked_at is null;select * into b from fp.transport_conversation_bindings where identity_link_id=l.id;
  if l.id is null or b.conversation_id is null or not exists(select 1 from fp.members where user_id=l.user_id and household_id=l.household_id and status='active') then return null;end if;
  select * into e from fp.conversation_executions where conversation_id=b.conversation_id and user_id=l.user_id and household_id=l.household_id and status='awaiting_clarification' order by created_at desc limit 1;
  if e.id is null then return null;end if;
  return jsonb_build_object('kind','clarification','data',jsonb_build_object('clarification_id',e.id,'action',jsonb_build_object('id',e.action_id,'type',e.action_type,'version',e.action_version,'parameters',e.action_parameters),'choices',coalesce(e.action_parameters->'choices','[]'::jsonb),'choice_actions',coalesce(e.action_parameters->'choice_actions','[]'::jsonb)));
end$$;

-- Keep the derived idempotency key inside the canonical 100-character action
-- envelope even when a transport option uses a descriptive action identifier.
create or replace function fp.decide_conversation_clarification(clarification uuid,decision text,option_id text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare execution fp.conversation_executions;current fp.conversations;chosen jsonb;
begin
  select * into execution from fp.conversation_executions e where e.id=clarification for update;
  if execution.id is null or execution.action_type<>'request_clarification' then raise exception 'clarification unavailable' using errcode='PT404';end if;
  select * into current from fp.conversation_member(execution.conversation_id);
  if current.id is null or current.user_id<>execution.user_id or current.household_id<>execution.household_id then raise exception 'not authorised' using errcode='42501';end if;
  if decision='redisplay' then
    if execution.status<>'awaiting_clarification' then raise exception 'clarification unavailable' using errcode='PT409';end if;
    perform fp.append_authoritative_conversation_message(current,'redisplay-'||execution.id,'clarification',execution.action_parameters->>'question',jsonb_build_object('clarification_id',execution.id,'action',jsonb_build_object('id',execution.action_id,'type',execution.action_type,'version',execution.action_version,'parameters',execution.action_parameters),'choices',coalesce(execution.action_parameters->'choices','[]'::jsonb),'choice_actions',coalesce(execution.action_parameters->'choice_actions','[]'::jsonb)));
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
  return fp.submit_conversation_action(current.id,chosen->>'id',chosen->>'type',(chosen->>'version')::integer,chosen->'parameters','clarify-'||encode(digest(execution.id::text||':'||option_id,'sha256'),'hex'),execution.model_derived and not coalesce((execution.action_parameters->>'_trusted_transport_choices')::boolean,false));
end$$;

create or replace function fp.telegram_family_choices(bot_identity text,telegram_user text,telegram_chat text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare l fp.external_identity_links;item record;raw text;choices jsonb:='[]'::jsonb;
begin
  select * into l from fp.external_identity_links where provider='telegram' and provider_tenant=bot_identity and provider_user_id=telegram_user and private_chat_id=telegram_chat and revoked_at is null;
  if l.id is null then return jsonb_build_object('linked',false);end if;
  for item in select h.id,h.name,h.id=l.household_id as current from fp.members m join fp.households h on h.id=m.household_id where m.user_id=l.user_id and m.status='active' order by h.name loop
    raw:=encode(gen_random_bytes(18),'hex');
    insert into fp.transport_callbacks(nonce_hash,identity_link_id,conversation_id,household_id,callback_type,bound_value,expires_at)
      select encode(digest(raw,'sha256'),'hex'),l.id,b.conversation_id,l.household_id,'family',item.id::text,now()+interval '15 minutes' from fp.transport_conversation_bindings b where b.identity_link_id=l.id;
    choices:=choices||jsonb_build_array(jsonb_build_object('label',case when item.current then item.name||' (current)' else item.name end,'nonce',raw));
  end loop;
  return jsonb_build_object('linked',true,'current_family',(select name from fp.households where id=l.household_id),'choices',choices,'only_one',jsonb_array_length(choices)=1);
end$$;

create or replace function fp.apply_telegram_control_callback(bot_identity text,telegram_user text,telegram_chat text,nonce text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare c fp.transport_callbacks;l fp.external_identity_links;target uuid;
begin
  if nonce !~ '^[0-9a-f]{36}$' then raise exception 'callback unavailable' using errcode='PT410';end if;
  select * into c from fp.transport_callbacks where nonce_hash=encode(digest(nonce,'sha256'),'hex') for update;
  select * into l from fp.external_identity_links where id=c.identity_link_id and provider_tenant=bot_identity and provider_user_id=telegram_user and private_chat_id=telegram_chat and revoked_at is null for update;
  if c.id is null or l.id is null or c.consumed_at is not null or c.expires_at<=now() then raise exception 'callback unavailable' using errcode='PT410';end if;
  if c.callback_type='family' then
    target:=c.bound_value::uuid;
    if not exists(select 1 from fp.members where user_id=l.user_id and household_id=target and status='active') then raise exception 'not authorised' using errcode='42501';end if;
    update fp.transport_callbacks set consumed_at=now() where identity_link_id=l.id and consumed_at is null;
    update fp.conversation_executions set status='cancelled',result='{"message":"Family changed."}'::jsonb,updated_at=now() where conversation_id=c.conversation_id and status in ('awaiting_clarification','awaiting_confirmation');
    update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where conversation_id=c.conversation_id and state='pending';
    update fp.external_identity_links set household_id=target where id=l.id;
    delete from fp.transport_conversation_bindings where identity_link_id=l.id;
    return jsonb_build_object('type','family','switched',true,'user_id',l.user_id,'family_id',target,'family_name',(select name from fp.households where id=target));
  elsif c.callback_type='disconnect' then
    update fp.transport_callbacks set consumed_at=now() where identity_link_id=l.id and consumed_at is null;
    update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where conversation_id=c.conversation_id and state='pending';
    update fp.external_identity_links set revoked_at=now() where id=l.id;
    return jsonb_build_object('type','disconnect','disconnected',true);
  elsif c.callback_type='cancel' then
    update fp.transport_callbacks set consumed_at=now() where identity_link_id=l.id and consumed_at is null;
    return jsonb_build_object('type','cancel','cancelled',true,'user_id',l.user_id,'family_id',l.household_id,'conversation_id',c.conversation_id);
  end if;
  raise exception 'callback type not handled' using errcode='22023';
end$$;

create or replace function fp.create_telegram_review(update_record uuid,attachment uuid,reason_value text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare u fp.transport_updates;a fp.transport_attachments;r fp.transport_inbox_items;
begin
  select * into u from fp.transport_updates where id=update_record;select * into a from fp.transport_attachments where id=attachment and update_id=u.id;
  if u.id is null or a.id is null or a.actor_user_id is null or reason_value not in ('attachment_needs_decision','action_failed','clarification_deferred') then raise exception 'invalid review item' using errcode='22023';end if;
  insert into fp.transport_inbox_items(update_id,attachment_id,actor_user_id,household_id,safe_sender,safe_subject,safe_preview,reason)
  values(u.id,a.id,a.actor_user_id,a.household_id,'Telegram','Telegram attachment',left(a.file_name,220),reason_value) on conflict(update_id) do update set updated_at=now() returning * into r;
  return jsonb_build_object('id',r.id);
end$$;

create or replace function fp.resolve_telegram_review(identity_link uuid,conversation_attachment uuid) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
declare l fp.external_identity_links;transport_attachment uuid;changed integer;
begin
  select * into l from fp.external_identity_links where id=identity_link and revoked_at is null;
  if l.id is null or not exists(select 1 from fp.members where user_id=l.user_id and household_id=l.household_id and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  select a.id into transport_attachment from fp.transport_attachments a where a.conversation_attachment_id=$2 and a.actor_user_id=l.user_id and a.household_id=l.household_id;
  update fp.transport_inbox_items set review_state='reviewed',updated_at=clock_timestamp() where attachment_id=transport_attachment and household_id=l.household_id and review_state='unreviewed';
  get diagnostics changed=row_count;return changed>0;
end$$;

create or replace function fp.telegram_inbox_workspace(search_query text default null,state_filter text default 'all',result_limit integer default 30,result_offset integer default 0) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;normalized text:=lower(regexp_replace(trim(coalesce(search_query,'')),'[[:space:]]+',' ','g'));
begin
  select role into member_role from fp.members where user_id=uid and household_id=hid and status='active';
  if state_filter not in ('all','unreviewed','attachments','reviewed') or result_limit not between 1 and 60 or result_offset not between 0 and 10000 then raise exception 'invalid inbox filter' using errcode='22023';end if;
  return jsonb_build_object('can_edit',fp.inbox_can_edit(member_role),'total',(select count(*) from fp.transport_inbox_items i where i.household_id=hid and (state_filter='all' or state_filter='attachments' and i.attachment_id is not null or i.review_state=state_filter) and (normalized='' or lower(i.safe_subject||' '||i.safe_preview||' '||i.safe_sender) like '%'||normalized||'%')),
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'sender',i.safe_sender,'subject',i.safe_subject,'received_at',i.created_at,'source','Telegram','preview',i.safe_preview,'attachment_count',case when i.attachment_id is null then 0 else 1 end,'link_count',0,'review_state',i.review_state,'updated_at',i.updated_at,'actions','[]'::jsonb) order by i.created_at desc,i.id desc) from (select * from fp.transport_inbox_items x where x.household_id=hid and (state_filter='all' or state_filter='attachments' and x.attachment_id is not null or x.review_state=state_filter) and (normalized='' or lower(x.safe_subject||' '||x.safe_preview||' '||x.safe_sender) like '%'||normalized||'%') order by x.created_at desc,x.id desc limit result_limit offset result_offset)i),'[]'::jsonb));
end$$;

create or replace function fp.telegram_inbox_message_detail(message uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;i fp.transport_inbox_items;a fp.transport_attachments;
begin
  select role into member_role from fp.members where user_id=uid and household_id=hid and status='active';select * into i from fp.transport_inbox_items where id=message and household_id=hid;select * into a from fp.transport_attachments where id=i.attachment_id and household_id=hid;
  if i.id is null then raise exception 'message unavailable' using errcode='PT404';end if;
  return jsonb_build_object('id',i.id,'sender',i.safe_sender,'recipients','[]'::jsonb,'subject',i.safe_subject,'received_at',i.created_at,'source','Telegram','body_text',i.safe_preview,'review_state',i.review_state,'updated_at',i.updated_at,'can_edit',fp.inbox_can_edit(member_role),'attachments',case when a.id is null then '[]'::jsonb else jsonb_build_array(jsonb_build_object('id',a.id,'file_name',a.file_name,'mime_type',coalesce(a.verified_mime_type,a.declared_mime_type,'application/octet-stream'),'size_bytes',coalesce(a.verified_size,a.declared_size,0),'status',case when a.state in ('staged','accepted','completed') then 'clean' when a.state='terminal_failure' then 'failed' else 'pending' end))end,'links','[]'::jsonb,'actions','[]'::jsonb);
end$$;

create or replace function fp.set_telegram_inbox_review_state(message uuid,new_state text,expected_updated_at timestamptz default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();member_role text;i fp.transport_inbox_items;
begin
  select role into member_role from fp.members where user_id=uid and household_id=hid and status='active';if not fp.inbox_can_edit(member_role) or new_state not in ('reviewed','dismissed') then raise exception 'not authorised' using errcode='42501';end if;
  update fp.transport_inbox_items set review_state=new_state,updated_at=clock_timestamp() where id=message and household_id=hid and (expected_updated_at is null or updated_at=expected_updated_at) returning * into i;if i.id is null then raise exception 'message changed' using errcode='PT409';end if;return jsonb_build_object('id',i.id,'review_state',i.review_state,'updated_at',i.updated_at);
end$$;

create or replace function fp.enqueue_telegram_job_updates(bot_identity text) returns integer language plpgsql security definer set search_path=pg_catalog,fp as $$
declare item record;normalized text;message_text text;inserted integer:=0;conversation fp.conversations;data jsonb;
begin
  for item in
    select distinct l.id identity_link_id,l.private_chat_id,b.conversation_id,j.id job_id,j.document_id,j.status,j.result
    from fp.external_identity_links l join fp.transport_conversation_bindings b on b.identity_link_id=l.id
    join fp.conversation_executions e on e.conversation_id=b.conversation_id
    join fp.document_analysis_jobs j on j.id=(e.result->>'job_id')::uuid and j.household_id=l.household_id and j.requested_by=l.user_id
    join fp.members m on m.user_id=l.user_id and m.household_id=l.household_id and m.status='active'
    where l.provider='telegram' and l.provider_tenant=bot_identity and l.revoked_at is null and e.result->>'job_id' is not null and j.status in ('processing','succeeded','failed','permanent_failed')
  loop
    normalized:=case when item.status='succeeded' then 'finished' when item.status in ('failed','permanent_failed') then 'failed' else 'processing' end;
    insert into fp.transport_job_notifications(identity_link_id,job_id,job_state) values(item.identity_link_id,item.job_id,normalized) on conflict do nothing;
    if found then
      message_text:=case when normalized='finished' then 'Finished reading your document.' when normalized='failed' then 'I couldn''t read that document.' else 'Reading your document...' end;
      data:=jsonb_strip_nulls(jsonb_build_object('correlation_id','ocr:'||item.job_id,'status',normalized,'job_id',item.job_id,'document_id',item.document_id,'category',item.result->>'category','tags',item.result->'tags'));
      select * into conversation from fp.conversations where id=item.conversation_id;
      perform fp.append_authoritative_conversation_message(conversation,'telegram-progress-'||item.job_id||'-'||normalized,case when normalized='finished' then 'result' when normalized='failed' then 'error' else 'progress' end,message_text,data);
      insert into fp.transport_outbox(provider,provider_tenant,private_chat_id,request_key,presentation) values('telegram',bot_identity,item.private_chat_id,'telegram:job:'||item.job_id||':'||normalized,jsonb_build_object('text',message_text)) on conflict do nothing;
      inserted:=inserted+1;
    end if;
  end loop;
  return inserted;
end$$;

revoke execute on function fp.claim_telegram_attachment(uuid,uuid),fp.stage_telegram_attachment(uuid,uuid,text,bigint,text,text),fp.finish_telegram_attachment(uuid,uuid,uuid),fp.fail_telegram_attachment(uuid,uuid,text,boolean),fp.telegram_cancel_pending(text,text,text),fp.prepare_telegram_category_clarification(uuid,uuid),fp.telegram_pending_clarification(uuid),fp.telegram_family_choices(text,text,text),fp.apply_telegram_control_callback(text,text,text,text),fp.create_telegram_review(uuid,uuid,text),fp.resolve_telegram_review(uuid,uuid) from public,anon,authenticated;
grant execute on function fp.claim_telegram_attachment(uuid,uuid),fp.stage_telegram_attachment(uuid,uuid,text,bigint,text,text),fp.finish_telegram_attachment(uuid,uuid,uuid),fp.fail_telegram_attachment(uuid,uuid,text,boolean),fp.telegram_cancel_pending(text,text,text),fp.prepare_telegram_category_clarification(uuid,uuid),fp.telegram_pending_clarification(uuid),fp.telegram_family_choices(text,text,text),fp.apply_telegram_control_callback(text,text,text,text),fp.create_telegram_review(uuid,uuid,text),fp.resolve_telegram_review(uuid,uuid) to service_role;
revoke execute on function fp.telegram_inbox_workspace(text,text,integer,integer),fp.telegram_inbox_message_detail(uuid),fp.set_telegram_inbox_review_state(uuid,text,timestamptz) from public,anon;
grant execute on function fp.telegram_inbox_workspace(text,text,integer,integer),fp.telegram_inbox_message_detail(uuid),fp.set_telegram_inbox_review_state(uuid,text,timestamptz) to authenticated,service_role;
revoke execute on function fp.enqueue_telegram_job_updates(text) from public,anon,authenticated;
grant execute on function fp.enqueue_telegram_job_updates(text) to service_role;

commit;
