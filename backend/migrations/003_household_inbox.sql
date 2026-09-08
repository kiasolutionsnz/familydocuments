begin;

create table if not exists fp.household_inbox_aliases (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  local_part text not null unique check (local_part ~ '^family-[0-9a-f]{24}$'),
  domain text not null default 'family-passport.local' check (domain = 'family-passport.local'),
  status text not null default 'active' check (status in ('active','rotated','disabled')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
create unique index if not exists household_inbox_one_active
  on fp.household_inbox_aliases(household_id) where status='active';

alter table fp.household_inbox_aliases enable row level security;
alter table fp.household_inbox_aliases force row level security;
drop policy if exists household_inbox_admin_read on fp.household_inbox_aliases;
create policy household_inbox_admin_read on fp.household_inbox_aliases for select
  using (fp.is_household_admin(household_id));

create or replace function fp.create_inbox_alias(p_household uuid, p_actor uuid) returns void
language plpgsql security definer
set search_path=pg_catalog,fp
as $$
declare candidate text;
begin
  if exists(select 1 from fp.household_inbox_aliases where household_id=p_household and status='active') then return; end if;
  loop
    candidate := 'family-' || encode(extensions.gen_random_bytes(12),'hex');
    begin
      insert into fp.household_inbox_aliases(household_id,local_part,created_by) values(p_household,candidate,p_actor);
      exit;
    exception when unique_violation then
      if exists(select 1 from fp.household_inbox_aliases where household_id=p_household and status='active') then exit; end if;
    end;
  end loop;
end $$;

select fp.create_inbox_alias(h.id,h.owner_user_id)
from fp.households h
where not exists(select 1 from fp.household_inbox_aliases a where a.household_id=h.id and a.status='active');

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
    perform fp.create_inbox_alias(hid,uid);
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
    'inbox',case when admin then (select jsonb_build_object('address',a.local_part||'@'||a.domain,'status',a.status,'created_at',a.created_at) from fp.household_inbox_aliases a where a.household_id=hid and a.status='active') else null end,
    'members',(select coalesce(jsonb_agg(jsonb_build_object('id',m.user_id,'email',m.email,'display_name',m.display_name,'role',m.role,'status',m.status) order by m.joined_at),'[]'::jsonb) from fp.members m where m.household_id=hid),
    'categories',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'is_system',c.is_system) order by c.is_system desc,c.name),'[]'::jsonb) from fp.categories c where c.household_id=hid),
    'documents',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category_id',d.category_id,'created_by',d.created_by,'source_name',d.source_name,'document_type',d.document_type,'provider_name',d.provider_name,'critical_date',d.critical_date,'ocr_confidence',d.ocr_confidence,'confirmation_status',d.confirmation_status) order by d.created_at desc),'[]'::jsonb) from fp.documents d where d.household_id=hid and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),
    'reminders',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'status',r.status) order by r.due_at),'[]'::jsonb) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),
    'permissions',(select coalesce(jsonb_agg(jsonb_build_object('document_id',p.document_id,'member_user_id',p.member_user_id,'access_level',p.access_level)),'[]'::jsonb) from fp.document_permissions p join fp.documents d on d.id=p.document_id where d.household_id=hid and (p.member_user_id=uid or admin or d.created_by=uid)),
    'invitations',case when admin then (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'status',i.status,'expires_at',i.expires_at) order by i.created_at desc),'[]'::jsonb) from fp.invitations i where i.household_id=hid) else '[]'::jsonb end
  );
end $$;

create or replace function fp.rotate_household_inbox() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text,0));
  update fp.household_inbox_aliases set status='rotated',ended_at=now() where household_id=hid and status='active';
  perform fp.create_inbox_alias(hid,uid);
  return fp.household_snapshot();
end $$;

create or replace function fp.disable_household_inbox() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text,0));
  update fp.household_inbox_aliases set status='disabled',ended_at=now() where household_id=hid and status='active';
  return fp.household_snapshot();
end $$;

create or replace function fp.enable_household_inbox() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text,0));
  perform fp.create_inbox_alias(hid,uid);
  return fp.household_snapshot();
end $$;

revoke all on fp.household_inbox_aliases from public,anon,authenticated;
revoke execute on function fp.create_inbox_alias(uuid,uuid) from public,anon,authenticated;
grant execute on function fp.rotate_household_inbox(), fp.disable_household_inbox(), fp.enable_household_inbox() to authenticated;

commit;
