begin;

create extension if not exists pgcrypto;
create schema if not exists fp;

create or replace function fp.current_user_id() returns uuid
language sql stable
set search_path = pg_catalog
as $$ select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid $$;

create or replace function fp.current_email() returns text
language sql stable
set search_path = pg_catalog
as $$ select lower(nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', '')) $$;

create table if not exists fp.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  owner_user_id uuid not null,
  created_at timestamptz not null default now()
);

create table if not exists fp.members (
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  email text not null check (email = lower(email) and char_length(email) between 3 and 254),
  display_name text,
  role text not null check (role in ('owner','family_admin','adult_member','contributor','viewer')),
  status text not null default 'active' check (status in ('active','suspended')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (household_id, email)
);

create table if not exists fp.categories (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  is_system boolean not null default false,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (household_id, name)
);

create table if not exists fp.documents (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  category_id uuid not null references fp.categories(id),
  title text not null check (char_length(title) between 1 and 120),
  created_by uuid not null,
  created_at timestamptz not null default now()
);

create table if not exists fp.document_permissions (
  document_id uuid not null references fp.documents(id) on delete cascade,
  member_user_id uuid not null,
  access_level text not null check (access_level in ('view','contribute','manage')),
  granted_by uuid not null,
  granted_at timestamptz not null default now(),
  primary key (document_id, member_user_id)
);

create table if not exists fp.invitations (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  email text not null check (email = lower(email) and char_length(email) between 3 and 254),
  role text not null check (role in ('family_admin','adult_member','contributor','viewer')),
  status text not null default 'pending' check (status in ('pending','accepted','revoked','expired')),
  invited_by uuid not null,
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now()
);
create unique index if not exists invitations_one_pending_email
  on fp.invitations(household_id, email) where status = 'pending';

create or replace function fp.is_active_member(p_household uuid) returns boolean
language sql stable security definer
set search_path = pg_catalog, fp
as $$ select exists(select 1 from fp.members where household_id=p_household and user_id=fp.current_user_id() and status='active') $$;

create or replace function fp.is_household_admin(p_household uuid) returns boolean
language sql stable security definer
set search_path = pg_catalog, fp
as $$ select exists(select 1 from fp.members where household_id=p_household and user_id=fp.current_user_id() and status='active' and role in ('owner','family_admin')) $$;

alter table fp.households enable row level security;
alter table fp.households force row level security;
alter table fp.members enable row level security;
alter table fp.members force row level security;
alter table fp.categories enable row level security;
alter table fp.categories force row level security;
alter table fp.documents enable row level security;
alter table fp.documents force row level security;
alter table fp.document_permissions enable row level security;
alter table fp.document_permissions force row level security;
alter table fp.invitations enable row level security;
alter table fp.invitations force row level security;

drop policy if exists household_member_read on fp.households;
create policy household_member_read on fp.households for select using (fp.is_active_member(id));
drop policy if exists members_household_read on fp.members;
create policy members_household_read on fp.members for select using (fp.is_active_member(household_id));
drop policy if exists categories_household_read on fp.categories;
create policy categories_household_read on fp.categories for select using (fp.is_active_member(household_id));
drop policy if exists documents_authorised_read on fp.documents;
create policy documents_authorised_read on fp.documents for select using (
  created_by=fp.current_user_id() or fp.is_household_admin(household_id) or exists(
    select 1 from fp.document_permissions p where p.document_id=id and p.member_user_id=fp.current_user_id()
  )
);
drop policy if exists permissions_admin_read on fp.document_permissions;
create policy permissions_admin_read on fp.document_permissions for select using (
  member_user_id=fp.current_user_id() or exists(
    select 1 from fp.documents d where d.id=document_id and (d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id))
  )
);
drop policy if exists invitations_admin_or_recipient_read on fp.invitations;
create policy invitations_admin_or_recipient_read on fp.invitations for select using (
  fp.is_household_admin(household_id) or email=fp.current_email()
);

create or replace function fp.bootstrap_household(household_name text, display_name text default null) returns jsonb
language plpgsql security definer
set search_path = pg_catalog, fp
as $$
declare uid uuid:=fp.current_user_id(); em text:=fp.current_email(); hid uuid;
begin
  if uid is null or em is null then raise exception 'authentication required' using errcode='28000'; end if;
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then
    insert into fp.households(name,owner_user_id) values(trim(household_name),uid) returning id into hid;
    insert into fp.members(household_id,user_id,email,display_name,role) values(hid,uid,em,nullif(trim(display_name),''),'owner');
    insert into fp.categories(household_id,name,is_system,created_by)
      select hid,n,true,uid from unnest(array['People','Home','Vehicles','Insurance','Purchases & warranties','Household assets']) n;
  end if;
  return fp.household_snapshot();
end $$;

create or replace function fp.household_snapshot() returns jsonb
language plpgsql security definer
set search_path = pg_catalog, fp
as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return jsonb_build_object('needs_setup',true); end if;
  admin:=fp.is_household_admin(hid);
  return jsonb_build_object(
    'needs_setup',false,
    'household',(select jsonb_build_object('id',h.id,'name',h.name) from fp.households h where h.id=hid),
    'current_user',(select jsonb_build_object('id',m.user_id,'email',m.email,'display_name',m.display_name,'role',m.role) from fp.members m where m.household_id=hid and m.user_id=uid),
    'members',(select coalesce(jsonb_agg(jsonb_build_object('id',m.user_id,'email',m.email,'display_name',m.display_name,'role',m.role,'status',m.status) order by m.joined_at),'[]'::jsonb) from fp.members m where m.household_id=hid),
    'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'is_system',c.is_system) order by c.is_system desc,c.name),'[]'::jsonb) from fp.categories c where c.household_id=hid),
    'documents',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category_id',d.category_id,'created_by',d.created_by) order by d.created_at desc),'[]'::jsonb) from fp.documents d where d.household_id=hid and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),
    'permissions',(select coalesce(jsonb_agg(jsonb_build_object('document_id',p.document_id,'member_user_id',p.member_user_id,'access_level',p.access_level)),'[]'::jsonb) from fp.document_permissions p join fp.documents d on d.id=p.document_id where d.household_id=hid and (p.member_user_id=uid or admin or d.created_by=uid)),
    'invitations',case when admin then (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'status',i.status,'expires_at',i.expires_at) order by i.created_at desc),'[]'::jsonb) from fp.invitations i where i.household_id=hid) else '[]'::jsonb end
  );
end $$;

create or replace function fp.create_category(category_name text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; row fp.categories;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  insert into fp.categories(household_id,name,created_by) values(hid,trim(category_name),uid) returning * into row;
  return jsonb_build_object('id',row.id,'name',row.name,'is_system',row.is_system);
end $$;

create or replace function fp.invite_member(invitee_email text, member_role text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; row fp.invitations; em text:=lower(trim(invitee_email));
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'invalid email' using errcode='22023'; end if;
  if member_role not in ('family_admin','adult_member','contributor','viewer') then raise exception 'invalid role' using errcode='22023'; end if;
  insert into fp.invitations(household_id,email,role,invited_by) values(hid,em,member_role,uid) returning * into row;
  return jsonb_build_object('id',row.id,'email',row.email,'role',row.role,'status',row.status,'expires_at',row.expires_at);
end $$;

create or replace function fp.accept_my_invitation() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); em text:=fp.current_email(); row fp.invitations;
begin
  if uid is null or em is null then raise exception 'authentication required' using errcode='28000'; end if;
  select * into row from fp.invitations where email=em and status='pending' and expires_at>now() order by created_at desc limit 1 for update skip locked;
  if row.id is null then raise exception 'no invitation available' using errcode='P0002'; end if;
  insert into fp.members(household_id,user_id,email,role) values(row.household_id,uid,em,row.role) on conflict do nothing;
  update fp.invitations set status='accepted' where id=row.id;
  return fp.household_snapshot();
end $$;

create or replace function fp.create_document(document_title text, category uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; row fp.documents;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then raise exception 'household required' using errcode='42501'; end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023'; end if;
  insert into fp.documents(household_id,category_id,title,created_by) values(hid,category,trim(document_title),uid) returning * into row;
  return jsonb_build_object('id',row.id,'title',row.title,'category_id',row.category_id,'created_by',row.created_by);
end $$;

create or replace function fp.set_document_access(document uuid, member uuid, access text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.documents where id=document and (created_by=uid or fp.is_household_admin(household_id));
  if hid is null then raise exception 'not authorised' using errcode='42501'; end if;
  if not exists(select 1 from fp.members where household_id=hid and user_id=member and status='active') then raise exception 'invalid member' using errcode='22023'; end if;
  if access='none' then delete from fp.document_permissions where document_id=document and member_user_id=member;
  elsif access in ('view','contribute','manage') then
    insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by) values(document,member,access,uid)
    on conflict(document_id,member_user_id) do update set access_level=excluded.access_level,granted_by=excluded.granted_by,granted_at=now();
  else raise exception 'invalid access' using errcode='22023'; end if;
  return jsonb_build_object('document_id',document,'member_user_id',member,'access_level',access);
end $$;

revoke all on schema fp from public, anon, authenticated;
grant usage on schema fp to authenticated;
revoke all on all tables in schema fp from public, anon, authenticated;
grant execute on function fp.bootstrap_household(text,text), fp.household_snapshot(), fp.create_category(text), fp.invite_member(text,text), fp.accept_my_invitation(), fp.create_document(text,uuid), fp.set_document_access(uuid,uuid,text) to authenticated;
revoke execute on function fp.current_user_id(), fp.current_email(), fp.is_active_member(uuid), fp.is_household_admin(uuid) from public, anon, authenticated;

commit;
