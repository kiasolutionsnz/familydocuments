begin;

alter table fp.documents add column if not exists source_name text;
alter table fp.documents add column if not exists source_sha256 text;
alter table fp.documents add column if not exists mime_type text;
alter table fp.documents add column if not exists extracted_text text;
alter table fp.documents add column if not exists document_type text;
alter table fp.documents add column if not exists provider_name text;
alter table fp.documents add column if not exists critical_date date;
alter table fp.documents add column if not exists ocr_confidence numeric(5,4);
alter table fp.documents add column if not exists confirmation_status text not null default 'confirmed';

create table if not exists fp.reminders (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  document_id uuid not null references fp.documents(id) on delete cascade,
  title text not null check(char_length(title) between 1 and 160),
  due_at date not null,
  status text not null default 'upcoming' check(status in ('upcoming','completed','dismissed')),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique(document_id,due_at)
);
alter table fp.reminders enable row level security;
alter table fp.reminders force row level security;
drop policy if exists reminders_authorised_read on fp.reminders;
create policy reminders_authorised_read on fp.reminders for select using (
  exists(select 1 from fp.documents d where d.id=document_id and (
    d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(
      select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()
    )
  ))
);

create or replace function fp.create_document(document_title text, category uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; member_role text; row fp.documents;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501'; end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023'; end if;
  insert into fp.documents(household_id,category_id,title,created_by) values(hid,category,trim(document_title),uid) returning * into row;
  return jsonb_build_object('id',row.id,'title',row.title,'category_id',row.category_id,'created_by',row.created_by);
end $$;

create or replace function fp.confirm_extraction(
  document_title text, category uuid, source_name text, source_sha256 text, source_mime_type text,
  confirmed_text text, confirmed_document_type text, confirmed_provider text,
  confirmed_critical_date date default null, mean_confidence numeric default null
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; member_role text; row fp.documents; reminder_id uuid;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501'; end if;
  if not exists(select 1 from fp.categories where id=category and household_id=hid) then raise exception 'invalid category' using errcode='22023'; end if;
  if source_sha256 !~ '^[0-9a-f]{64}$' or source_mime_type not in ('application/pdf','image/jpeg','image/png') then raise exception 'invalid source evidence' using errcode='22023'; end if;
  if char_length(confirmed_text) not between 3 and 100000 or mean_confidence is null or mean_confidence<0 or mean_confidence>1 then raise exception 'invalid extraction' using errcode='22023'; end if;
  insert into fp.documents(household_id,category_id,title,created_by,source_name,source_sha256,mime_type,extracted_text,document_type,provider_name,critical_date,ocr_confidence,confirmation_status)
  values(hid,category,trim(document_title),uid,left(trim(source_name),255),source_sha256,source_mime_type,confirmed_text,left(trim(confirmed_document_type),80),nullif(left(trim(confirmed_provider),120),''),confirmed_critical_date,mean_confidence,'confirmed') returning * into row;
  if confirmed_critical_date is not null then
    insert into fp.reminders(household_id,document_id,title,due_at,created_by)
    values(hid,row.id,concat(row.title,' — check or renew'),confirmed_critical_date,uid) returning id into reminder_id;
  end if;
  return jsonb_build_object('document_id',row.id,'title',row.title,'reminder_id',reminder_id,'critical_date',row.critical_date,'confirmation_status',row.confirmation_status);
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
    'documents',(select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'category_id',d.category_id,'created_by',d.created_by,'source_name',d.source_name,'document_type',d.document_type,'provider_name',d.provider_name,'critical_date',d.critical_date,'ocr_confidence',d.ocr_confidence,'confirmation_status',d.confirmation_status) order by d.created_at desc),'[]'::jsonb) from fp.documents d where d.household_id=hid and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),
    'reminders',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'document_id',r.document_id,'title',r.title,'due_at',r.due_at,'status',r.status) order by r.due_at),'[]'::jsonb) from fp.reminders r join fp.documents d on d.id=r.document_id where r.household_id=hid and (d.created_by=uid or admin or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),
    'permissions',(select coalesce(jsonb_agg(jsonb_build_object('document_id',p.document_id,'member_user_id',p.member_user_id,'access_level',p.access_level)),'[]'::jsonb) from fp.document_permissions p join fp.documents d on d.id=p.document_id where d.household_id=hid and (p.member_user_id=uid or admin or d.created_by=uid)),
    'invitations',case when admin then (select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'status',i.status,'expires_at',i.expires_at) order by i.created_at desc),'[]'::jsonb) from fp.invitations i where i.household_id=hid) else '[]'::jsonb end
  );
end $$;

revoke all on fp.reminders from public,anon,authenticated;
grant execute on function fp.confirm_extraction(text,uuid,text,text,text,text,text,text,date,numeric) to authenticated;

commit;
