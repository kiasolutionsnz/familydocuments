begin;

alter table fp.documents add column if not exists privacy_mode text not null default 'private';
alter table fp.documents drop constraint if exists documents_privacy_mode_check;
alter table fp.documents add constraint documents_privacy_mode_check check(privacy_mode in ('private','shared_by_rules'));

alter table fp.document_permissions add column if not exists grant_source text not null default 'manual';
alter table fp.document_permissions drop constraint if exists document_permissions_grant_source_check;
alter table fp.document_permissions add constraint document_permissions_grant_source_check check(grant_source in ('manual','rule'));

create table if not exists fp.access_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  scope_type text not null check(scope_type in ('category','entity')),
  category_id uuid references fp.categories(id) on delete cascade,
  entity_id uuid references fp.entities(id) on delete cascade,
  member_user_id uuid not null,
  access_level text not null check(access_level in ('view','contribute','manage')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((scope_type='category' and category_id is not null and entity_id is null) or (scope_type='entity' and entity_id is not null and category_id is null))
);
create unique index if not exists access_rules_category_member on fp.access_rules(household_id,category_id,member_user_id) where scope_type='category';
create unique index if not exists access_rules_entity_member on fp.access_rules(household_id,entity_id,member_user_id) where scope_type='entity';

alter table fp.document_permissions add column if not exists access_rule_id uuid references fp.access_rules(id) on delete set null;

create table if not exists fp.permission_audit_events (
  id bigint generated always as identity primary key,
  household_id uuid not null references fp.households(id) on delete cascade,
  document_id uuid references fp.documents(id) on delete set null,
  actor_user_id uuid not null,
  member_user_id uuid,
  event_type text not null check(event_type in ('manual_grant','manual_revoke','rule_saved','rule_removed','privacy_changed')),
  details jsonb not null default '{}'::jsonb check(jsonb_typeof(details)='object'),
  created_at timestamptz not null default now()
);

alter table fp.access_rules enable row level security; alter table fp.access_rules force row level security;
alter table fp.permission_audit_events enable row level security; alter table fp.permission_audit_events force row level security;
drop policy if exists access_rules_admin_read on fp.access_rules;
create policy access_rules_admin_read on fp.access_rules for select using(fp.is_household_admin(household_id));
drop policy if exists permission_audit_admin_read on fp.permission_audit_events;
create policy permission_audit_admin_read on fp.permission_audit_events for select using(fp.is_household_admin(household_id));

create or replace function fp.rebuild_rule_permissions(target_household uuid) returns void
language plpgsql security definer set search_path=pg_catalog,fp as $$
begin
  delete from fp.document_permissions p using fp.documents d
    where p.document_id=d.id and d.household_id=target_household and p.grant_source='rule';
  with candidates as (
    select d.id document_id,r.member_user_id,r.access_level,r.id rule_id,
           case r.access_level when 'manage' then 3 when 'contribute' then 2 else 1 end strength
    from fp.documents d join fp.access_rules r on r.household_id=d.household_id and r.scope_type='category' and r.category_id=d.category_id
    where d.household_id=target_household and d.privacy_mode='shared_by_rules'
    union all
    select d.id,r.member_user_id,r.access_level,r.id,
           case r.access_level when 'manage' then 3 when 'contribute' then 2 else 1 end
    from fp.documents d join fp.document_entities de on de.document_id=d.id
      join fp.access_rules r on r.household_id=d.household_id and r.scope_type='entity' and r.entity_id=de.entity_id
    where d.household_id=target_household and d.privacy_mode='shared_by_rules'
  ), strongest as (
    select distinct on(document_id,member_user_id) document_id,member_user_id,access_level,rule_id
    from candidates order by document_id,member_user_id,strength desc,rule_id
  )
  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by,grant_source,access_rule_id)
    select s.document_id,s.member_user_id,s.access_level,h.owner_user_id,'rule',s.rule_id
    from strongest s join fp.documents d on d.id=s.document_id join fp.households h on h.id=d.household_id
    on conflict(document_id,member_user_id) do nothing;
end $$;

create or replace function fp.refresh_rule_permissions_trigger() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare hid uuid;
begin
  if tg_table_name='documents' then hid:=coalesce(new.household_id,old.household_id);
  else select household_id into hid from fp.documents where id=coalesce(new.document_id,old.document_id); end if;
  if hid is not null then perform fp.rebuild_rule_permissions(hid); end if;
  return coalesce(new,old);
end $$;
drop trigger if exists documents_refresh_rule_permissions on fp.documents;
create trigger documents_refresh_rule_permissions after insert or update of category_id,privacy_mode on fp.documents for each row execute function fp.refresh_rule_permissions_trigger();
drop trigger if exists entities_refresh_rule_permissions on fp.document_entities;
create trigger entities_refresh_rule_permissions after insert or delete on fp.document_entities for each row execute function fp.refresh_rule_permissions_trigger();

create or replace function fp.set_document_access(document uuid,member uuid,access text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.documents where id=document and (created_by=uid or fp.is_household_admin(household_id));
  if hid is null then raise exception 'not authorised' using errcode='42501'; end if;
  if not exists(select 1 from fp.members where household_id=hid and user_id=member and status='active') then raise exception 'invalid member' using errcode='22023'; end if;
  if access='none' then
    delete from fp.document_permissions where document_id=document and member_user_id=member;
    insert into fp.permission_audit_events(household_id,document_id,actor_user_id,member_user_id,event_type) values(hid,document,uid,member,'manual_revoke');
  elsif access in ('view','contribute','manage') then
    insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by,grant_source,access_rule_id) values(document,member,access,uid,'manual',null)
    on conflict(document_id,member_user_id) do update set access_level=excluded.access_level,granted_by=excluded.granted_by,granted_at=now(),grant_source='manual',access_rule_id=null;
    insert into fp.permission_audit_events(household_id,document_id,actor_user_id,member_user_id,event_type,details) values(hid,document,uid,member,'manual_grant',jsonb_build_object('access',access));
  else raise exception 'invalid access' using errcode='22023'; end if;
  return jsonb_build_object('document_id',document,'member_user_id',member,'access_level',access);
end $$;

create or replace function fp.set_document_privacy(document uuid,mode text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  if mode not in ('private','shared_by_rules') then raise exception 'invalid privacy mode' using errcode='22023'; end if;
  select household_id into hid from fp.documents where id=document and (created_by=uid or fp.is_household_admin(household_id));
  if hid is null then raise exception 'not authorised' using errcode='42501'; end if;
  update fp.documents set privacy_mode=mode where id=document;
  insert into fp.permission_audit_events(household_id,document_id,actor_user_id,event_type,details) values(hid,document,uid,'privacy_changed',jsonb_build_object('mode',mode));
  return jsonb_build_object('document_id',document,'privacy_mode',mode);
end $$;

create or replace function fp.set_access_rule(rule_scope text,scope_id uuid,member uuid,access text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; rid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  if rule_scope not in ('category','entity') then raise exception 'invalid scope' using errcode='22023'; end if;
  if not exists(select 1 from fp.members where household_id=hid and user_id=member and status='active') then raise exception 'invalid member' using errcode='22023'; end if;
  if rule_scope='category' and not exists(select 1 from fp.categories where id=scope_id and household_id=hid) then raise exception 'invalid category' using errcode='22023'; end if;
  if rule_scope='entity' and not exists(select 1 from fp.entities where id=scope_id and household_id=hid and status='active') then raise exception 'invalid entity' using errcode='22023'; end if;
  if access='none' then
    delete from fp.access_rules where household_id=hid and member_user_id=member and ((rule_scope='category' and category_id=scope_id) or (rule_scope='entity' and entity_id=scope_id)) returning id into rid;
    insert into fp.permission_audit_events(household_id,actor_user_id,member_user_id,event_type,details) values(hid,uid,member,'rule_removed',jsonb_build_object('scope_type',rule_scope,'scope_id',scope_id));
  elsif access in ('view','contribute','manage') then
    if rule_scope='category' then
      insert into fp.access_rules(household_id,scope_type,category_id,member_user_id,access_level,created_by) values(hid,rule_scope,scope_id,member,access,uid)
      on conflict(household_id,category_id,member_user_id) where scope_type='category' do update set access_level=excluded.access_level,updated_at=now() returning id into rid;
    else
      insert into fp.access_rules(household_id,scope_type,entity_id,member_user_id,access_level,created_by) values(hid,rule_scope,scope_id,member,access,uid)
      on conflict(household_id,entity_id,member_user_id) where scope_type='entity' do update set access_level=excluded.access_level,updated_at=now() returning id into rid;
    end if;
    insert into fp.permission_audit_events(household_id,actor_user_id,member_user_id,event_type,details) values(hid,uid,member,'rule_saved',jsonb_build_object('scope_type',rule_scope,'scope_id',scope_id,'access',access));
  else raise exception 'invalid access' using errcode='22023'; end if;
  perform fp.rebuild_rule_permissions(hid);
  return jsonb_build_object('id',rid,'scope_type',rule_scope,'scope_id',scope_id,'member_user_id',member,'access_level',access);
end $$;

create or replace function fp.access_rule_summaries() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'scope_type',r.scope_type,'scope_id',coalesce(r.category_id,r.entity_id),'scope_name',coalesce(c.name,e.name),'member_user_id',r.member_user_id,'member_name',coalesce(m.display_name,m.email),'access_level',r.access_level) order by r.updated_at desc) from fp.access_rules r left join fp.categories c on c.id=r.category_id left join fp.entities e on e.id=r.entity_id join fp.members m on m.household_id=r.household_id and m.user_id=r.member_user_id where r.household_id=hid),'[]'::jsonb);
end $$;

create or replace function fp.permission_audit_summaries(result_limit integer default 20) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'event_type',x.event_type,'document_title',d.title,'member_name',coalesce(m.display_name,m.email),'details',x.details,'created_at',x.created_at) order by x.created_at desc) from (select * from fp.permission_audit_events where household_id=hid order by created_at desc limit least(greatest(result_limit,1),50)) x left join fp.documents d on d.id=x.document_id left join fp.members m on m.household_id=x.household_id and m.user_id=x.member_user_id),'[]'::jsonb);
end $$;

revoke all on fp.access_rules,fp.permission_audit_events from public,anon,authenticated;
revoke execute on function fp.rebuild_rule_permissions(uuid),fp.refresh_rule_permissions_trigger() from public,anon,authenticated;
revoke execute on function fp.set_document_privacy(uuid,text),fp.set_access_rule(text,uuid,uuid,text),fp.access_rule_summaries(),fp.permission_audit_summaries(integer) from public,anon;
grant execute on function fp.set_document_privacy(uuid,text),fp.set_access_rule(text,uuid,uuid,text),fp.access_rule_summaries(),fp.permission_audit_summaries(integer) to authenticated;

commit;
