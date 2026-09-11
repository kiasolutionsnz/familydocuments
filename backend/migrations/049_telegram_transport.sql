begin;

create table fp.external_identity_links(
  id uuid primary key default gen_random_uuid(),
  provider text not null check(provider='telegram'),
  provider_tenant text not null check(char_length(provider_tenant) between 1 and 80),
  provider_user_id text not null check(provider_user_id ~ '^[1-9][0-9]{0,19}$'),
  private_chat_id text not null check(private_chat_id ~ '^-?[0-9]{1,20}$'),
  user_id uuid not null,
  household_id uuid not null references fp.households(id) on delete cascade,
  display_metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(display_metadata)='object' and octet_length(display_metadata::text)<=2048),
  connected_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(provider,provider_tenant,provider_user_id)
);
create index external_identity_links_member on fp.external_identity_links(user_id,household_id) where revoked_at is null;

create table fp.external_link_tokens(
  id uuid primary key default gen_random_uuid(),
  provider text not null check(provider='telegram'),
  provider_tenant text not null,
  token_hash text not null unique check(token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null,
  household_id uuid not null references fp.households(id) on delete cascade,
  purpose text not null check(purpose='connect'),
  expires_at timestamptz not null,
  attempts integer not null default 0 check(attempts between 0 and 5),
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check(expires_at>created_at and expires_at<=created_at+interval '10 minutes')
);

create table fp.transport_updates(
  id uuid primary key default gen_random_uuid(),
  provider text not null check(provider='telegram'),
  provider_tenant text not null,
  provider_update_id bigint not null,
  provider_user_id text,
  private_chat_id text,
  update_kind text not null check(update_kind in ('message','callback_query')),
  envelope jsonb not null check(jsonb_typeof(envelope)='object' and octet_length(envelope::text)<=65536),
  state text not null default 'received' check(state in ('received','processing','retryable','completed','dead_letter','rejected')),
  attempt integer not null default 0 check(attempt between 0 and 10),
  available_at timestamptz not null default now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  last_outcome text check(last_outcome is null or last_outcome in ('handled','unlinked','unsupported','invalid_attachment','service_unavailable','permission_denied')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(provider,provider_tenant,provider_update_id)
);
create index transport_updates_claim on fp.transport_updates(available_at,created_at) where state in ('received','retryable','processing');

create table fp.transport_attachments(
  id uuid primary key default gen_random_uuid(),
  update_id uuid not null references fp.transport_updates(id) on delete cascade,
  provider_file_id text not null check(char_length(provider_file_id) between 1 and 300),
  file_name text not null check(char_length(file_name) between 1 and 255),
  declared_mime_type text,
  declared_size bigint check(declared_size between 0 and 5242880),
  sha256 text check(sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  document_id uuid references fp.documents(id),
  created_at timestamptz not null default now(),
  unique(update_id,provider_file_id)
);

create table fp.transport_conversation_bindings(
  identity_link_id uuid primary key references fp.external_identity_links(id) on delete cascade,
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  updated_at timestamptz not null default now()
);

create table fp.transport_callbacks(
  id uuid primary key default gen_random_uuid(),
  nonce_hash text not null unique check(nonce_hash ~ '^[0-9a-f]{64}$'),
  identity_link_id uuid not null references fp.external_identity_links(id) on delete cascade,
  conversation_id uuid not null references fp.conversations(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  callback_type text not null check(callback_type in ('clarification','confirmation','cancel','family','disconnect')),
  bound_reference uuid,
  bound_value text check(bound_value is null or char_length(bound_value)<=100),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check(expires_at>created_at and expires_at<=created_at+interval '15 minutes')
);

create table fp.transport_outbox(
  id uuid primary key default gen_random_uuid(),
  provider text not null check(provider='telegram'),
  provider_tenant text not null,
  private_chat_id text not null,
  request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,100}$'),
  presentation jsonb not null check(jsonb_typeof(presentation)='object' and octet_length(presentation::text)<=8192),
  state text not null default 'pending' check(state in ('pending','sending','retryable','sent','dead_letter')),
  attempt integer not null default 0 check(attempt between 0 and 10),
  available_at timestamptz not null default now(),
  lease_token uuid,
  lease_expires_at timestamptz,
  provider_message_id text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  unique(provider,provider_tenant,request_key)
);
create index transport_outbox_claim on fp.transport_outbox(available_at,created_at) where state in ('pending','retryable','sending');

alter table fp.external_identity_links enable row level security; alter table fp.external_identity_links force row level security;
alter table fp.external_link_tokens enable row level security; alter table fp.external_link_tokens force row level security;
alter table fp.transport_updates enable row level security; alter table fp.transport_updates force row level security;
alter table fp.transport_attachments enable row level security; alter table fp.transport_attachments force row level security;
alter table fp.transport_conversation_bindings enable row level security; alter table fp.transport_conversation_bindings force row level security;
alter table fp.transport_callbacks enable row level security; alter table fp.transport_callbacks force row level security;
alter table fp.transport_outbox enable row level security; alter table fp.transport_outbox force row level security;
revoke all on fp.external_identity_links,fp.external_link_tokens,fp.transport_updates,fp.transport_attachments,fp.transport_conversation_bindings,fp.transport_callbacks,fp.transport_outbox from public,anon,authenticated;

-- A signed request-scoped Family claim lets a trusted transport bind an event
-- without changing the user's browser-selected Family. Ordinary access tokens
-- do not contain this claim and retain the Phase 2D selection behaviour.
create or replace function fp.active_family_id(require_selected boolean default true) returns uuid
language plpgsql security definer stable set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();selected uuid;families uuid[];claimed text:=nullif(current_setting('request.jwt.claims',true)::jsonb->>'family_id','');
begin
  select array_agg(household_id order by joined_at,household_id) into families from fp.members where user_id=uid and status='active';
  if coalesce(array_length(families,1),0)=0 then raise exception 'not authorised' using errcode='42501';end if;
  if claimed is not null then
    if claimed !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' or not exists(select 1 from fp.members where user_id=uid and household_id=claimed::uuid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
    return claimed::uuid;
  end if;
  select c.household_id into selected from fp.active_family_contexts c join fp.members m on m.household_id=c.household_id and m.user_id=uid and m.status='active' where c.user_id=uid;
  if selected is not null then return selected;end if;
  if array_length(families,1)=1 then return families[1];end if;
  if require_selected then raise exception 'active Family selection required' using errcode='PT409';end if;
  return null;
end$$;

create or replace function fp.telegram_connection_status() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid:=fp.active_family_id(false); link fp.external_identity_links;
begin
  if hid is null then return jsonb_build_object('selection_required',true,'connected',false);end if;
  select * into link from fp.external_identity_links l where l.provider='telegram' and l.user_id=uid and l.household_id=hid and l.revoked_at is null order by l.connected_at desc limit 1;
  return jsonb_build_object('selection_required',false,'family_id',hid,'family_name',(select name from fp.households where id=hid),'connected',link.id is not null,
    'display_name',case when link.id is null then null else link.display_metadata->>'display_name' end,'username',case when link.id is null then null else link.display_metadata->>'username' end,
    'connected_at',link.connected_at);
end$$;

create or replace function fp.create_telegram_link_token(family uuid,bot_identity text,link_hash text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); row fp.external_link_tokens;
begin
  if family<>fp.active_family_id() or not exists(select 1 from fp.members where user_id=uid and household_id=family and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  if bot_identity is null or char_length(bot_identity) not between 1 and 80 or link_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid link request' using errcode='22023';end if;
  update fp.external_link_tokens set revoked_at=now() where provider='telegram' and provider_tenant=bot_identity and user_id=uid and consumed_at is null and revoked_at is null;
  insert into fp.external_link_tokens(provider,provider_tenant,token_hash,user_id,household_id,purpose,expires_at) values('telegram',bot_identity,link_hash,uid,family,'connect',now()+interval '10 minutes') returning * into row;
  return jsonb_build_object('link_id',row.id,'expires_at',row.expires_at);
end$$;

create or replace function fp.disconnect_telegram(family uuid,bot_identity text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); changed integer;
begin
  if family<>fp.active_family_id() then raise exception 'not authorised' using errcode='42501';end if;
  update fp.external_identity_links set revoked_at=now() where provider='telegram' and provider_tenant=bot_identity and user_id=uid and household_id=family and revoked_at is null; get diagnostics changed=row_count;
  update fp.external_link_tokens set revoked_at=now() where provider='telegram' and provider_tenant=bot_identity and user_id=uid and household_id=family and consumed_at is null and revoked_at is null;
  update fp.transport_callbacks c set consumed_at=now() from fp.external_identity_links l where c.identity_link_id=l.id and l.user_id=uid and l.household_id=family and c.consumed_at is null;
  update fp.conversation_execution_confirmations set state='cancelled',consumed_at=now() where user_id=uid and household_id=family and state='pending';
  return jsonb_build_object('disconnected',changed>0);
end$$;

create or replace function fp.consume_telegram_link_token(bot_identity text,link_hash text,telegram_user text,telegram_chat text,metadata jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.external_link_tokens; member_active boolean; linked fp.external_identity_links;
begin
  if link_hash !~ '^[0-9a-f]{64}$' or telegram_user !~ '^[1-9][0-9]{0,19}$' or telegram_chat !~ '^-?[0-9]{1,20}$' or jsonb_typeof(metadata)<>'object' or octet_length(metadata::text)>2048 then raise exception 'invalid link token' using errcode='22023';end if;
  select * into row from fp.external_link_tokens t where t.provider='telegram' and t.provider_tenant=bot_identity and t.token_hash=link_hash for update;
  if row.id is null then raise exception 'invalid link token' using errcode='PT404';end if;
  update fp.external_link_tokens set attempts=least(attempts+1,5) where id=row.id;
  select exists(select 1 from fp.members where user_id=row.user_id and household_id=row.household_id and status='active') into member_active;
  if row.consumed_at is not null or row.revoked_at is not null or row.expires_at<=now() or row.attempts>=5 or not member_active then raise exception 'link token unavailable' using errcode='PT410';end if;
  update fp.external_identity_links set revoked_at=now() where provider='telegram' and provider_tenant=bot_identity and (provider_user_id=telegram_user or user_id=row.user_id) and revoked_at is null;
  insert into fp.external_identity_links(provider,provider_tenant,provider_user_id,private_chat_id,user_id,household_id,display_metadata) values('telegram',bot_identity,telegram_user,telegram_chat,row.user_id,row.household_id,metadata) returning * into linked;
  update fp.external_link_tokens set consumed_at=now() where id=row.id;
  return jsonb_build_object('linked',true,'identity_link_id',linked.id,'user_id',linked.user_id,'family_id',linked.household_id);
end$$;

create or replace function fp.ingest_telegram_update(bot_identity text,telegram_update_id bigint,telegram_user text,telegram_chat text,kind text,envelope jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.transport_updates; inserted boolean:=true;
begin
  if bot_identity is null or char_length(bot_identity) not between 1 and 80 or telegram_update_id<0 or kind not in ('message','callback_query') or jsonb_typeof(envelope)<>'object' or octet_length(envelope::text)>65536 then raise exception 'invalid update' using errcode='22023';end if;
  insert into fp.transport_updates(provider,provider_tenant,provider_update_id,provider_user_id,private_chat_id,update_kind,envelope) values('telegram',bot_identity,telegram_update_id,telegram_user,telegram_chat,kind,envelope)
    on conflict(provider,provider_tenant,provider_update_id) do nothing returning * into row;
  if row.id is null then inserted:=false; select * into row from fp.transport_updates where provider='telegram' and provider_tenant=bot_identity and provider_update_id=telegram_update_id;end if;
  return jsonb_build_object('id',row.id,'accepted',inserted,'duplicate',not inserted);
end$$;

create or replace function fp.telegram_transport_context(bot_identity text,telegram_user text,telegram_chat text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare link fp.external_identity_links; binding fp.transport_conversation_bindings;
begin
  select l.* into link from fp.external_identity_links l join fp.members m on m.user_id=l.user_id and m.household_id=l.household_id and m.status='active'
    where l.provider='telegram' and l.provider_tenant=bot_identity and l.provider_user_id=telegram_user and l.private_chat_id=telegram_chat and l.revoked_at is null;
  if link.id is null then return jsonb_build_object('linked',false);end if;
  select * into binding from fp.transport_conversation_bindings where identity_link_id=link.id;
  return jsonb_build_object('linked',true,'identity_link_id',link.id,'user_id',link.user_id,'family_id',link.household_id,'conversation_id',binding.conversation_id,
    'family_name',(select name from fp.households where id=link.household_id));
end$$;

create or replace function fp.bind_telegram_conversation(bot_identity text,telegram_user text,telegram_chat text,conversation uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare link fp.external_identity_links;c fp.conversations;
begin
  select l.* into link from fp.external_identity_links l join fp.members m on m.user_id=l.user_id and m.household_id=l.household_id and m.status='active'
    where l.provider='telegram' and l.provider_tenant=bot_identity and l.provider_user_id=telegram_user and l.private_chat_id=telegram_chat and l.revoked_at is null;
  select * into c from fp.conversations where id=conversation and user_id=link.user_id and household_id=link.household_id and status='active';
  if link.id is null or c.id is null then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.transport_conversation_bindings(identity_link_id,conversation_id,household_id) values(link.id,c.id,link.household_id)
    on conflict(identity_link_id) do update set conversation_id=excluded.conversation_id,household_id=excluded.household_id,updated_at=now();
  return jsonb_build_object('conversation_id',c.id);
end$$;

create or replace function fp.create_telegram_callback(identity_link uuid,conversation uuid,callback_kind text,reference uuid,value text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare link fp.external_identity_links;raw text;row fp.transport_callbacks;
begin
  select l.* into link from fp.external_identity_links l join fp.members m on m.user_id=l.user_id and m.household_id=l.household_id and m.status='active' where l.id=identity_link and l.revoked_at is null;
  if link.id is null or not exists(select 1 from fp.conversations c where c.id=conversation and c.user_id=link.user_id and c.household_id=link.household_id and c.status='active') or callback_kind not in ('clarification','confirmation','cancel','family','disconnect') then raise exception 'not authorised' using errcode='42501';end if;
  raw:=encode(gen_random_bytes(18),'hex');
  insert into fp.transport_callbacks(nonce_hash,identity_link_id,conversation_id,household_id,callback_type,bound_reference,bound_value,expires_at)
    values(encode(digest(raw,'sha256'),'hex'),link.id,conversation,link.household_id,callback_kind,reference,value,now()+interval '15 minutes') returning * into row;
  return jsonb_build_object('nonce',raw,'expires_at',row.expires_at);
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
  return jsonb_build_object('type',row.callback_type,'reference_id',row.bound_reference,'value',row.bound_value,'conversation_id',row.conversation_id,'user_id',link.user_id,'family_id',link.household_id);
end$$;

create or replace function fp.claim_telegram_updates(bot_identity text,batch_size integer default 4) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare lease uuid:=gen_random_uuid(); result jsonb;
begin
  if batch_size not between 1 and 8 then raise exception 'invalid batch size' using errcode='22023';end if;
  with candidates as (select id from fp.transport_updates where provider='telegram' and provider_tenant=bot_identity and available_at<=now() and (state in ('received','retryable') or state='processing' and lease_expires_at<now()) order by available_at,provider_update_id for update skip locked limit batch_size),
  claimed as (update fp.transport_updates u set state='processing',attempt=attempt+1,lease_token=lease,lease_expires_at=now()+interval '90 seconds' from candidates c where u.id=c.id returning u.*)
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'update_id',provider_update_id,'provider_user_id',provider_user_id,'private_chat_id',private_chat_id,'kind',update_kind,'envelope',envelope,'lease_token',lease_token,'attempt',attempt) order by provider_update_id),'[]'::jsonb) into result from claimed;
  return result;
end$$;

create or replace function fp.complete_telegram_update(update_record uuid,worker_lease uuid,outcome text,responses jsonb default '[]'::jsonb) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.transport_updates; item jsonb; n integer:=0;
begin
  if outcome not in ('handled','unlinked','unsupported','invalid_attachment','service_unavailable','permission_denied') or jsonb_typeof(responses)<>'array' or jsonb_array_length(responses)>6 then raise exception 'invalid outcome' using errcode='22023';end if;
  select * into row from fp.transport_updates where id=update_record for update;
  if row.id is null or row.state<>'processing' or row.lease_token<>worker_lease or row.lease_expires_at<=now() then raise exception 'lease unavailable' using errcode='40001';end if;
  for item in select value from jsonb_array_elements(responses) loop
    if jsonb_typeof(item)<>'object' or octet_length(item::text)>8192 or item->>'request_key' !~ '^[A-Za-z0-9:_-]{8,100}$' then raise exception 'invalid response' using errcode='22023';end if;
    insert into fp.transport_outbox(provider,provider_tenant,private_chat_id,request_key,presentation) values('telegram',row.provider_tenant,row.private_chat_id,item->>'request_key',item-'request_key') on conflict do nothing;n:=n+1;
  end loop;
  update fp.transport_updates set state='completed',last_outcome=outcome,completed_at=now(),lease_token=null,lease_expires_at=null,envelope='{}'::jsonb where id=row.id;
  return jsonb_build_object('completed',true,'responses',n);
end$$;

create or replace function fp.fail_telegram_update(update_record uuid,worker_lease uuid,retryable boolean,outcome text) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.transport_updates;
begin
  select * into row from fp.transport_updates where id=update_record for update;
  if row.id is null or row.state<>'processing' or row.lease_token<>worker_lease then return false;end if;
  update fp.transport_updates set state=case when retryable and attempt<6 then 'retryable' else 'dead_letter' end,last_outcome=outcome,available_at=now()+(least(300,power(2,attempt)::integer)+floor(random()*4))*interval '1 second',lease_token=null,lease_expires_at=null where id=row.id;
  return true;
end$$;

create or replace function fp.claim_telegram_outbox(bot_identity text,batch_size integer default 4) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$
declare lease uuid:=gen_random_uuid(); result jsonb;
begin
  with candidates as (select id from fp.transport_outbox where provider='telegram' and provider_tenant=bot_identity and available_at<=now() and (state in ('pending','retryable') or state='sending' and lease_expires_at<now()) order by available_at,created_at for update skip locked limit greatest(1,least(batch_size,8))),
  claimed as (update fp.transport_outbox o set state='sending',attempt=attempt+1,lease_token=lease,lease_expires_at=now()+interval '60 seconds' from candidates c where o.id=c.id returning o.*)
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'chat_id',private_chat_id,'presentation',presentation,'lease_token',lease_token,'attempt',attempt)),'[]'::jsonb) into result from claimed;return result;
end$$;

create or replace function fp.complete_telegram_outbox(outbox_record uuid,worker_lease uuid,provider_message text) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  update fp.transport_outbox set state='sent',sent_at=now(),provider_message_id=left(provider_message,100),lease_token=null,lease_expires_at=null where id=outbox_record and state='sending' and lease_token=worker_lease and lease_expires_at>now();return found;
end$$;

create or replace function fp.fail_telegram_outbox(outbox_record uuid,worker_lease uuid,retryable boolean) returns boolean language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  update fp.transport_outbox set state=case when retryable and attempt<6 then 'retryable' else 'dead_letter' end,available_at=now()+(least(300,power(2,attempt)::integer)+floor(random()*4))*interval '1 second',lease_token=null,lease_expires_at=null where id=outbox_record and state='sending' and lease_token=worker_lease;return found;
end$$;

revoke execute on function fp.telegram_connection_status(),fp.create_telegram_link_token(uuid,text,text),fp.disconnect_telegram(uuid,text),fp.consume_telegram_link_token(text,text,text,text,jsonb),fp.ingest_telegram_update(text,bigint,text,text,text,jsonb),fp.telegram_transport_context(text,text,text),fp.bind_telegram_conversation(text,text,text,uuid),fp.create_telegram_callback(uuid,uuid,text,uuid,text),fp.consume_telegram_callback(text,text,text,text),fp.claim_telegram_updates(text,integer),fp.complete_telegram_update(uuid,uuid,text,jsonb),fp.fail_telegram_update(uuid,uuid,boolean,text),fp.claim_telegram_outbox(text,integer),fp.complete_telegram_outbox(uuid,uuid,text),fp.fail_telegram_outbox(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function fp.telegram_connection_status(),fp.create_telegram_link_token(uuid,text,text),fp.disconnect_telegram(uuid,text) to authenticated;
grant execute on function fp.telegram_connection_status(),fp.create_telegram_link_token(uuid,text,text),fp.disconnect_telegram(uuid,text) to service_role;
grant execute on function fp.consume_telegram_link_token(text,text,text,text,jsonb),fp.ingest_telegram_update(text,bigint,text,text,text,jsonb),fp.telegram_transport_context(text,text,text),fp.bind_telegram_conversation(text,text,text,uuid),fp.create_telegram_callback(uuid,uuid,text,uuid,text),fp.consume_telegram_callback(text,text,text,text),fp.claim_telegram_updates(text,integer),fp.complete_telegram_update(uuid,uuid,text,jsonb),fp.fail_telegram_update(uuid,uuid,boolean,text),fp.claim_telegram_outbox(text,integer),fp.complete_telegram_outbox(uuid,uuid,text),fp.fail_telegram_outbox(uuid,uuid,boolean) to service_role;

commit;
