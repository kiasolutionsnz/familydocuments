begin;

create table if not exists fp.entities (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  entity_type text not null check(entity_type in ('person','property','vehicle','pet','custom')),
  custom_type_name text check(custom_type_name is null or char_length(custom_type_name) between 2 and 40),
  name text not null check(char_length(name) between 1 and 100),
  status text not null default 'active' check(status in ('active','archived')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  archived_at timestamptz,
  unique(household_id,entity_type,name)
);
create table if not exists fp.document_entities (
  document_id uuid not null references fp.documents(id) on delete cascade,
  entity_id uuid not null references fp.entities(id) on delete cascade,
  relationship text not null default 'related' check(relationship in ('primary','related')),
  linked_by uuid not null,
  linked_at timestamptz not null default now(),
  primary key(document_id,entity_id)
);
create unique index if not exists one_primary_entity_per_type on fp.document_entities(document_id,entity_id) where relationship='primary';
alter table fp.entities enable row level security; alter table fp.entities force row level security;
alter table fp.document_entities enable row level security; alter table fp.document_entities force row level security;
drop policy if exists entity_authorised_read on fp.entities;
create policy entity_authorised_read on fp.entities for select using(fp.is_household_admin(household_id) or created_by=fp.current_user_id() or exists(select 1 from fp.document_entities de join fp.documents d on d.id=de.document_id where de.entity_id=entities.id and d.lifecycle_status<>'deleted' and (d.created_by=fp.current_user_id() or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));
drop policy if exists document_entity_authorised_read on fp.document_entities;
create policy document_entity_authorised_read on fp.document_entities for select using(exists(select 1 from fp.documents d where d.id=document_id and d.lifecycle_status<>'deleted' and (d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));

create or replace function fp.create_entity(kind text,entity_name text,custom_kind text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; member_role text; row fp.entities;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501'; end if;
  if kind not in ('person','property','vehicle','pet','custom') or char_length(trim(entity_name)) not between 1 and 100 or (kind='custom' and char_length(trim(coalesce(custom_kind,''))) not between 2 and 40) then raise exception 'invalid entity' using errcode='22023'; end if;
  insert into fp.entities(household_id,entity_type,custom_type_name,name,created_by) values(hid,kind,case when kind='custom' then trim(custom_kind) else null end,trim(entity_name),uid) returning * into row;
  return jsonb_build_object('id',row.id,'entity_type',row.entity_type,'custom_type_name',row.custom_type_name,'name',row.name,'status',row.status);
end $$;

create or replace function fp.entity_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return '[]'::jsonb; end if; admin:=fp.is_household_admin(hid);
  return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'entity_type',e.entity_type,'custom_type_name',e.custom_type_name,'name',e.name,'status',e.status,'created_by',e.created_by,'document_ids',coalesce((select jsonb_agg(de.document_id order by de.linked_at) from fp.document_entities de join fp.documents d on d.id=de.document_id where de.entity_id=e.id and d.lifecycle_status<>'deleted' and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb)) order by e.entity_type,e.name) from fp.entities e where e.household_id=hid and (admin or e.created_by=uid or exists(select 1 from fp.document_entities de join fp.documents d on d.id=de.document_id where de.entity_id=e.id and d.lifecycle_status<>'deleted' and (d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))))),'[]'::jsonb);
end $$;

create or replace function fp.link_document_entity(document uuid,entity uuid,link_action text default 'link') returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); d fp.documents; e fp.entities; allowed boolean;
begin
  select * into d from fp.documents where id=document; select * into e from fp.entities where id=entity;
  if d.id is null or e.id is null or d.household_id<>e.household_id or d.lifecycle_status='deleted' or e.status<>'active' then raise exception 'invalid relationship' using errcode='22023'; end if;
  allowed:=d.created_by=uid or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid and p.access_level='manage');
  if not allowed then raise exception 'not authorised' using errcode='42501'; end if;
  if link_action='link' then insert into fp.document_entities(document_id,entity_id,linked_by) values(d.id,e.id,uid) on conflict do nothing;
  elsif link_action='unlink' then delete from fp.document_entities where document_id=d.id and entity_id=e.id;
  else raise exception 'invalid link action' using errcode='22023'; end if;
  return jsonb_build_object('document_id',d.id,'entity_id',e.id,'linked',link_action='link');
end $$;

create or replace function fp.archive_entity(entity uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.entities; uid uuid:=fp.current_user_id();
begin
  select * into row from fp.entities where id=entity for update;
  if row.id is null or not fp.is_household_admin(row.household_id) then raise exception 'not authorised' using errcode='42501'; end if;
  update fp.entities set status='archived',archived_at=now() where id=row.id;
  return jsonb_build_object('id',row.id,'status','archived');
end $$;

revoke all on fp.entities,fp.document_entities from public,anon,authenticated;
revoke execute on function fp.create_entity(text,text,text),fp.entity_summaries(),fp.link_document_entity(uuid,uuid,text),fp.archive_entity(uuid) from public,anon;
grant execute on function fp.create_entity(text,text,text),fp.entity_summaries(),fp.link_document_entity(uuid,uuid,text),fp.archive_entity(uuid) to authenticated;
commit;
