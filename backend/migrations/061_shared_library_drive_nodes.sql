begin;

-- App-owned folder nodes under the selected shared FamilyDocuments Drive root.
-- Human-readable labels are presentation only; node keys and Drive IDs make
-- retries/collisions deterministic. This table never grants Drive access.
create table if not exists fp.library_drive_nodes(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  node_key text not null check(node_key ~ '^[a-z][a-z0-9:_-]{0,180}$'),
  node_kind text not null check(node_kind in ('library','collection','rental','trip','bucket')),
  parent_folder_id text not null check(char_length(parent_folder_id) between 10 and 200),
  provider_folder_id text check(provider_folder_id is null or char_length(provider_folder_id) between 10 and 200),
  folder_name text not null check(char_length(folder_name) between 1 and 180),
  related_entity_id uuid,
  status text not null default 'provisioning' check(status in ('provisioning','active','missing','exception')),
  reservation_token uuid,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,node_key),
  unique(household_id,provider_folder_id)
);
create index if not exists library_drive_nodes_parent_idx on fp.library_drive_nodes(household_id,parent_folder_id,status);
alter table fp.library_drive_nodes enable row level security;
alter table fp.library_drive_nodes force row level security;
revoke all on fp.library_drive_nodes from public,anon,authenticated;

-- Returns only the selected root and already app-registered children for the
-- current active Family. The gateway uses this to reject arbitrary parent IDs.
create or replace function fp.authorize_library_drive_parent(parent_folder text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();root text;
begin
  select provider_folder_id into root from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if hid is null or root is null or not exists(select 1 from fp.google_drive_credentials where household_id=hid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  if parent_folder<>root and not exists(select 1 from fp.library_drive_nodes where household_id=hid and provider_folder_id=parent_folder and status='active') then raise exception 'unrecognised library folder' using errcode='42501';end if;
  return jsonb_build_object('household_id',hid,'root_folder_id',root,'parent_folder_id',parent_folder);
end$$;

-- Registration is idempotent by Family/node key. Gateway code must call this
-- only after Google Drive confirms creation under an authorised parent.
-- Reserve the node before contacting Google. This prevents concurrent retries
-- from making more than one folder for the same logical Library node.
create or replace function fp.reserve_library_drive_node(target_household uuid,actor uuid,node_key_value text,node_kind_value text,parent_folder text,display_name text,related_entity uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid:=target_household;root text;row fp.library_drive_nodes;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' or not exists(select 1 from fp.members where household_id=hid and user_id=actor and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  select provider_folder_id into root from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if root is null or (parent_folder<>root and not exists(select 1 from fp.library_drive_nodes where household_id=hid and provider_folder_id=parent_folder and status='active')) then raise exception 'unrecognised library folder' using errcode='42501';end if;
  if node_key_value !~ '^[a-z][a-z0-9:_-]{0,180}$' or node_kind_value not in ('library','collection','rental','trip','bucket') or char_length(trim(display_name)) not between 1 and 180 then raise exception 'invalid library folder node' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text||':'||node_key_value,0));
  select * into row from fp.library_drive_nodes where household_id=hid and node_key=node_key_value for update;
  if row.id is not null then
    if row.parent_folder_id<>parent_folder or row.node_kind<>node_kind_value then raise exception 'library node collision' using errcode='23505';end if;
    if row.status='active' then return jsonb_build_object('id',row.id,'provider_folder_id',row.provider_folder_id,'existing',true);end if;
    if row.status='provisioning' then return jsonb_build_object('id',row.id,'provisioning',true);end if;
    update fp.library_drive_nodes set status='provisioning',folder_name=trim(display_name),related_entity_id=related_entity,reservation_token=gen_random_uuid(),updated_at=now() where id=row.id returning * into row;
    return jsonb_build_object('id',row.id,'reservation_token',row.reservation_token,'existing',false);
  end if;
  insert into fp.library_drive_nodes(household_id,node_key,node_kind,parent_folder_id,folder_name,related_entity_id,created_by,reservation_token)
    values(hid,node_key_value,node_kind_value,parent_folder,trim(display_name),related_entity,actor,gen_random_uuid()) returning * into row;
  return jsonb_build_object('id',row.id,'reservation_token',row.reservation_token,'existing',false);
end$$;

-- Completes only a matching reservation. A failed/unknown Drive response is
-- deliberately left as provisioning rather than risking a duplicate folder.
create or replace function fp.complete_library_drive_node(target_household uuid,actor uuid,reservation uuid,provider_folder text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid:=target_household;row fp.library_drive_nodes;root text;
begin
  if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' or not exists(select 1 from fp.members where household_id=hid and user_id=actor and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  if char_length(provider_folder) not between 10 and 200 then raise exception 'invalid folder' using errcode='22023';end if;
  select provider_folder_id into root from fp.storage_connections where household_id=hid and provider='google_drive' and status='active';
  if provider_folder=root or exists(select 1 from fp.library_drive_nodes where household_id=hid and provider_folder_id=provider_folder) then raise exception 'folder already registered' using errcode='23505';end if;
  select * into row from fp.library_drive_nodes where household_id=hid and reservation_token=reservation for update;
  if row.id is null or row.status<>'provisioning' then raise exception 'library reservation unavailable' using errcode='42501';end if;
  update fp.library_drive_nodes set provider_folder_id=provider_folder,status='active',reservation_token=null,updated_at=now() where id=row.id returning * into row;
  return jsonb_build_object('id',row.id,'provider_folder_id',row.provider_folder_id,'existing',false);
end$$;

create or replace function fp.library_drive_node(node_key_value text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid:=fp.active_family_id();row fp.library_drive_nodes;
begin
  select * into row from fp.library_drive_nodes where household_id=hid and node_key=node_key_value and status='active';
  if row.id is null then return '{}'::jsonb;end if;
  return jsonb_build_object('id',row.id,'provider_folder_id',row.provider_folder_id,'parent_folder_id',row.parent_folder_id,'folder_name',row.folder_name,'node_kind',row.node_kind);
end$$;

revoke execute on function fp.authorize_library_drive_parent(text),fp.reserve_library_drive_node(uuid,uuid,text,text,text,text,uuid),fp.complete_library_drive_node(uuid,uuid,uuid,text),fp.library_drive_node(text) from public,anon;
grant execute on function fp.authorize_library_drive_parent(text),fp.library_drive_node(text) to authenticated;
grant execute on function fp.reserve_library_drive_node(uuid,uuid,text,text,text,text,uuid),fp.complete_library_drive_node(uuid,uuid,uuid,text) to service_role;

commit;
