begin;

create table if not exists fp.rental_properties(
  entity_id uuid primary key references fp.entities(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  address text not null check(char_length(address) between 3 and 240),
  ownership_label text check(ownership_label is null or char_length(ownership_label) between 2 and 100),
  manager_name text check(manager_name is null or char_length(manager_name) between 2 and 100),
  manager_email text check(manager_email is null or manager_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  manager_phone text check(manager_phone is null or char_length(manager_phone) between 3 and 40),
  created_by uuid not null,
  updated_at timestamptz not null default now()
);

create table if not exists fp.rental_bills(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  property_entity_id uuid not null references fp.rental_properties(entity_id) on delete cascade,
  document_id uuid not null references fp.documents(id) on delete cascade,
  expense_category text not null check(expense_category in ('rates','insurance','interest','repairs','maintenance','utilities','professional_fees','compliance','other')),
  status text not null default 'confirmed' check(status in ('proposed','confirmed','due','paid')),
  amount numeric(14,2) check(amount is null or amount>=0),
  currency text not null default 'NZD' check(currency ~ '^[A-Z]{3}$'),
  due_date date,
  paid_date date,
  account_reference text check(account_reference is null or char_length(account_reference)<=100),
  suggestion_reason text check(suggestion_reason is null or char_length(suggestion_reason)<=180),
  confirmed_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(property_entity_id,document_id),
  check((status='paid' and paid_date is not null) or status<>'paid')
);

create index if not exists rental_bills_property_due on fp.rental_bills(property_entity_id,status,due_date);
alter table fp.rental_properties enable row level security; alter table fp.rental_properties force row level security;
alter table fp.rental_bills enable row level security; alter table fp.rental_bills force row level security;
revoke all on fp.rental_properties,fp.rental_bills from public,anon,authenticated;

create or replace function fp.rental_property_workspace() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; admin boolean;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return jsonb_build_object('properties','[]'::jsonb,'bills','[]'::jsonb,'documents','[]'::jsonb); end if;
  admin:=fp.is_household_admin(hid);
  return jsonb_build_object(
    'properties',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'address',p.address,'ownership_label',p.ownership_label,'manager_name',p.manager_name,'manager_email',p.manager_email,'manager_phone',p.manager_phone,'created_by',p.created_by) order by e.name)
      from fp.rental_properties p join fp.entities e on e.id=p.entity_id
      where p.household_id=hid and e.status='active' and (admin or p.created_by=uid or exists(select 1 from fp.access_rules ar where ar.household_id=hid and ar.scope_type='entity' and ar.entity_id=e.id and ar.member_user_id=uid))),'[]'::jsonb),
    'bills',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'property_id',b.property_entity_id,'property_name',e.name,'document_id',d.id,'document_title',d.title,'provider_name',d.provider_name,'expense_category',b.expense_category,'status',b.status,'amount',coalesce(b.amount,d.amount),'currency',coalesce(b.currency,d.currency,'NZD'),'due_date',b.due_date,'paid_date',b.paid_date,'account_reference',b.account_reference,'suggestion_reason',b.suggestion_reason) order by coalesce(b.due_date,d.document_date) desc nulls last)
      from fp.rental_bills b join fp.entities e on e.id=b.property_entity_id join fp.documents d on d.id=b.document_id
      where b.household_id=hid and d.lifecycle_status<>'deleted' and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions dp where dp.document_id=d.id and dp.member_user_id=uid))),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'title',d.title,'provider_name',d.provider_name,'amount',d.amount,'currency',d.currency,'critical_date',d.critical_date,'suggested_property_id',(select rb.property_entity_id from fp.rental_bills rb join fp.documents prior on prior.id=rb.document_id where prior.household_id=hid and d.provider_name is not null and lower(prior.provider_name)=lower(d.provider_name) order by rb.created_at desc limit 1),'suggestion_reason',case when d.provider_name is not null and exists(select 1 from fp.rental_bills rb join fp.documents prior on prior.id=rb.document_id where prior.household_id=hid and lower(prior.provider_name)=lower(d.provider_name)) then 'Matched a provider used on an earlier confirmed rental bill' end) order by d.created_at desc)
      from fp.documents d where d.household_id=hid and d.lifecycle_status='active' and not exists(select 1 from fp.rental_bills rb where rb.document_id=d.id) and (admin or d.created_by=uid or exists(select 1 from fp.document_permissions dp where dp.document_id=d.id and dp.member_user_id=uid and dp.access_level in ('contribute','manage')))),'[]'::jsonb)
  );
end $$;

create or replace function fp.create_rental_property(property_name text,property_address text,ownership text default null,property_manager_name text default null,property_manager_email text default null,property_manager_phone text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid; member_role text; eid uuid;
begin
  select household_id,role into hid,member_role from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or member_role not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501'; end if;
  if char_length(trim(property_name)) not between 1 and 100 or char_length(trim(property_address)) not between 3 and 240 then raise exception 'invalid property details' using errcode='22023'; end if;
  insert into fp.entities(household_id,entity_type,name,created_by) values(hid,'property',trim(property_name),uid) returning id into eid;
  insert into fp.rental_properties(entity_id,household_id,address,ownership_label,manager_name,manager_email,manager_phone,created_by)
  values(eid,hid,trim(property_address),nullif(trim(ownership),''),nullif(trim(property_manager_name),''),nullif(lower(trim(property_manager_email)),''),nullif(trim(property_manager_phone),''),uid);
  return jsonb_build_object('id',eid,'name',trim(property_name),'address',trim(property_address));
end $$;

create or replace function fp.create_rental_bill(property uuid,document uuid,category text,bill_amount numeric default null,bill_currency text default 'NZD',bill_due_date date default null,account_ref text default null,suggestion text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); p fp.rental_properties; d fp.documents; row fp.rental_bills;
begin
  select * into p from fp.rental_properties where entity_id=property; select * into d from fp.documents where id=document and lifecycle_status='active';
  if p.entity_id is null or d.id is null or p.household_id<>d.household_id or not (fp.is_household_admin(d.household_id) or d.created_by=uid or exists(select 1 from fp.document_permissions dp where dp.document_id=d.id and dp.member_user_id=uid and dp.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501'; end if;
  insert into fp.rental_bills(household_id,property_entity_id,document_id,expense_category,status,amount,currency,due_date,account_reference,suggestion_reason,confirmed_by)
  values(d.household_id,p.entity_id,d.id,category,case when bill_due_date is not null and bill_due_date<=current_date then 'due' else 'confirmed' end,bill_amount,upper(coalesce(bill_currency,'NZD')),bill_due_date,nullif(trim(account_ref),''),nullif(trim(suggestion),''),uid) returning * into row;
  insert into fp.document_entities(document_id,entity_id,relationship,linked_by) values(d.id,p.entity_id,'related',uid) on conflict do nothing;
  return jsonb_build_object('id',row.id,'status',row.status,'property_id',row.property_entity_id,'document_id',row.document_id);
end $$;

create or replace function fp.set_rental_bill_status(bill uuid,new_status text,paid_on date default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); b fp.rental_bills; d fp.documents;
begin
  select * into b from fp.rental_bills where id=bill for update; select * into d from fp.documents where id=b.document_id;
  if b.id is null or new_status not in ('confirmed','due','paid') or not (fp.is_household_admin(b.household_id) or d.created_by=uid or exists(select 1 from fp.document_permissions dp where dp.document_id=d.id and dp.member_user_id=uid and dp.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501'; end if;
  update fp.rental_bills set status=new_status,paid_date=case when new_status='paid' then coalesce(paid_on,current_date) else null end,updated_at=now() where id=b.id;
  return jsonb_build_object('id',b.id,'status',new_status,'paid_date',case when new_status='paid' then coalesce(paid_on,current_date) end);
end $$;

create or replace function fp.rental_property_export() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); hid uuid;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if; perform fp.require_aal2();
  return jsonb_build_object('schema_version',1,'exported_at',now(),'notice','Organisation export only; expense categories are not tax advice.',
    'rows',coalesce((select jsonb_agg(jsonb_build_object('property_name',e.name,'property_address',p.address,'ownership',p.ownership_label,'document_title',d.title,'provider',d.provider_name,'expense_category',b.expense_category,'status',b.status,'amount',coalesce(b.amount,d.amount),'currency',coalesce(b.currency,d.currency,'NZD'),'due_date',b.due_date,'paid_date',b.paid_date,'account_reference',b.account_reference,'source_sha256',d.source_sha256) order by e.name,b.due_date)
      from fp.rental_bills b join fp.rental_properties p on p.entity_id=b.property_entity_id join fp.entities e on e.id=p.entity_id join fp.documents d on d.id=b.document_id where b.household_id=hid),'[]'::jsonb));
end $$;

revoke execute on function fp.rental_property_workspace(),fp.create_rental_property(text,text,text,text,text,text),fp.create_rental_bill(uuid,uuid,text,numeric,text,date,text,text),fp.set_rental_bill_status(uuid,text,date),fp.rental_property_export() from public,anon;
grant execute on function fp.rental_property_workspace(),fp.create_rental_property(text,text,text,text,text,text),fp.create_rental_bill(uuid,uuid,text,numeric,text,date,text,text),fp.set_rental_bill_status(uuid,text,date),fp.rental_property_export() to authenticated;

commit;
