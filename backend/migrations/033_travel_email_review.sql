begin;

alter table fp.email_classification_proposals add column if not exists booking_reference text check(booking_reference is null or char_length(booking_reference)<=100);
alter table fp.email_classification_proposals add column if not exists suggested_travel_kind text check(suggested_travel_kind is null or suggested_travel_kind in ('flight','accommodation','rail','ferry','car_rental','activity','insurance','visa','ticket','other'));
alter table fp.email_classification_proposals add column if not exists suggested_destination text check(suggested_destination is null or char_length(suggested_destination)<=160);
alter table fp.email_classification_proposals add column if not exists suggested_trip_name text check(suggested_trip_name is null or char_length(suggested_trip_name)<=120);
alter table fp.email_classification_proposals drop constraint if exists email_classification_proposals_suggested_record_kind_check;
alter table fp.email_classification_proposals add constraint email_classification_proposals_suggested_record_kind_check check(suggested_record_kind is null or suggested_record_kind in ('general','rental','financial_statement','travel'));

create table if not exists fp.travel_trips(
  id uuid primary key default gen_random_uuid(), household_id uuid not null references fp.households(id) on delete cascade,
  name text not null check(char_length(name) between 1 and 120), destination text check(destination is null or char_length(destination)<=160),
  start_date date, end_date date, status text not null default 'planned' check(status in ('planned','active','completed','cancelled')),
  created_by uuid not null, created_at timestamptz not null default now(), check(end_date is null or start_date is null or end_date>=start_date), unique(household_id,name)
);
create table if not exists fp.travel_records(
  id uuid primary key default gen_random_uuid(), household_id uuid not null references fp.households(id) on delete cascade,
  trip_id uuid not null references fp.travel_trips(id) on delete cascade, document_id uuid not null references fp.documents(id) on delete restrict,
  travel_kind text not null check(travel_kind in ('flight','accommodation','rail','ferry','car_rental','activity','insurance','visa','ticket','other')),
  booking_reference text check(booking_reference is null or char_length(booking_reference)<=100), provider text check(provider is null or char_length(provider)<=120),
  origin text check(origin is null or char_length(origin)<=160), destination text check(destination is null or char_length(destination)<=160),
  starts_at timestamptz, ends_at timestamptz, amount numeric check(amount is null or amount>=0), currency text check(currency is null or currency~'^[A-Z]{3}$'),
  notes text check(notes is null or char_length(notes)<=500), confirmed_by uuid not null, confirmed_at timestamptz not null default now(), unique(document_id)
);
alter table fp.travel_trips enable row level security; alter table fp.travel_trips force row level security;
alter table fp.travel_records enable row level security; alter table fp.travel_records force row level security;

create or replace function fp.store_classification_enrichment(proposal uuid,invoice text,description text,record_kind text,expense_category text) returns void language plpgsql security definer set search_path=pg_catalog,fp as $$ begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'),'')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  if record_kind not in ('general','rental','financial_statement','travel') or expense_category not in ('rates','insurance','interest','repairs','maintenance','utilities','professional_fees','compliance','other') then raise exception 'invalid enrichment' using errcode='22023';end if;
  update fp.email_classification_proposals set invoice_number=nullif(left(trim(invoice),100),''),suggested_description=nullif(left(trim(description),500),''),suggested_record_kind=record_kind,suggested_expense_category=expense_category where id=proposal and status='needs_review';if not found then raise exception 'proposal unavailable' using errcode='P0002';end if;
end $$;
create policy travel_trip_authorised_read on fp.travel_trips for select using(fp.is_household_admin(household_id) or created_by=fp.current_user_id() or exists(select 1 from fp.travel_records r join fp.documents d on d.id=r.document_id where r.trip_id=travel_trips.id and (d.created_by=fp.current_user_id() or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));
create policy travel_record_authorised_read on fp.travel_records for select using(exists(select 1 from fp.documents d where d.id=document_id and d.lifecycle_status<>'deleted' and (d.created_by=fp.current_user_id() or fp.is_household_admin(d.household_id) or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=fp.current_user_id()))));

create or replace function fp.store_travel_classification_enrichment(proposal uuid,booking_ref text,travel_kind text,destination text,trip_name text) returns void language plpgsql security definer set search_path=pg_catalog,fp as $$ begin
  if coalesce(nullif(current_setting('request.jwt.claim.role',true),''),(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'),'')<>'service_role' then raise exception 'not authorised' using errcode='42501';end if;
  if travel_kind not in ('flight','accommodation','rail','ferry','car_rental','activity','insurance','visa','ticket','other') then raise exception 'invalid travel enrichment' using errcode='22023';end if;
  update fp.email_classification_proposals set booking_reference=nullif(left(trim(booking_ref),100),''),suggested_travel_kind=travel_kind,suggested_destination=nullif(left(trim(destination),160),''),suggested_trip_name=nullif(left(trim(trip_name),120),'') where id=proposal and status='needs_review';if not found then raise exception 'proposal unavailable' using errcode='P0002';end if;
end $$;

create or replace function fp.travel_workspace() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$ declare uid uuid:=fp.current_user_id();hid uuid;begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then return jsonb_build_object('trips','[]'::jsonb,'records','[]'::jsonb);end if;
  return jsonb_build_object('trips',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'destination',t.destination,'start_date',t.start_date,'end_date',t.end_date,'status',t.status) order by coalesce(t.start_date,'9999-12-31')) from fp.travel_trips t where t.household_id=hid),'[]'::jsonb),'records',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'trip_id',r.trip_id,'document_id',r.document_id,'document_title',d.title,'trip_name',t.name,'travel_kind',r.travel_kind,'booking_reference',r.booking_reference,'provider',r.provider,'origin',r.origin,'destination',r.destination,'starts_at',r.starts_at,'ends_at',r.ends_at,'amount',r.amount,'currency',r.currency,'notes',r.notes) order by coalesce(r.starts_at,r.confirmed_at)) from fp.travel_records r join fp.travel_trips t on t.id=r.trip_id join fp.documents d on d.id=r.document_id where r.household_id=hid and (fp.is_household_admin(hid) or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb));
end $$;

create or replace function fp.create_travel_trip(trip_name text,destination_name text default null,trip_start date default null,trip_end date default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$ declare uid uuid:=fp.current_user_id();hid uuid;role_name text;row fp.travel_trips;begin
  select household_id,role into hid,role_name from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or role_name not in ('owner','family_admin','adult_member','contributor') then raise exception 'not authorised' using errcode='42501';end if;
  if char_length(trim(coalesce(trip_name,''))) not between 1 and 120 or (trip_end is not null and trip_start is not null and trip_end<trip_start) then raise exception 'invalid trip' using errcode='22023';end if;
  insert into fp.travel_trips(household_id,name,destination,start_date,end_date,created_by) values(hid,trim(trip_name),nullif(left(trim(destination_name),160),''),trip_start,trip_end,uid) returning * into row;return jsonb_build_object('id',row.id,'name',row.name);
end $$;

create or replace function fp.create_travel_record(trip uuid,document uuid,kind text,booking_ref text default null,provider_name text default null,origin_name text default null,destination_name text default null,starts timestamptz default null,ends timestamptz default null,record_amount numeric default null,record_currency text default null,record_notes text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$ declare uid uuid:=fp.current_user_id();t fp.travel_trips;d fp.documents;row fp.travel_records;begin
  select * into t from fp.travel_trips where id=trip;select * into d from fp.documents where id=document and lifecycle_status='active';if t.id is null or d.id is null or t.household_id<>d.household_id or not(fp.is_household_admin(d.household_id) or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid and p.access_level in ('contribute','manage'))) then raise exception 'not authorised' using errcode='42501';end if;
  if kind not in ('flight','accommodation','rail','ferry','car_rental','activity','insurance','visa','ticket','other') or record_amount<0 or (record_currency is not null and upper(record_currency)!~'^[A-Z]{3}$') or (ends is not null and starts is not null and ends<starts) then raise exception 'invalid travel record' using errcode='22023';end if;
  insert into fp.travel_records(household_id,trip_id,document_id,travel_kind,booking_reference,provider,origin,destination,starts_at,ends_at,amount,currency,notes,confirmed_by) values(t.household_id,t.id,d.id,kind,nullif(left(trim(booking_ref),100),''),nullif(left(trim(provider_name),120),''),nullif(left(trim(origin_name),160),''),nullif(left(trim(destination_name),160),''),starts,ends,record_amount,case when record_currency is null then null else upper(record_currency) end,nullif(left(trim(record_notes),500),''),uid) returning * into row;return jsonb_build_object('id',row.id,'trip_id',row.trip_id,'document_id',row.document_id);
end $$;

create or replace function fp.email_classification_summaries() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$ declare uid uuid:=fp.current_user_id();hid uuid;begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501';end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'email_id',p.inbound_email_id,'email_subject',e.subject,'sender_address',e.sender_address,'file_name',a.file_name,'category_name',p.category_name,'title',p.title,'document_type',p.document_type,'provider_name',p.provider_name,'document_date',p.document_date,'due_date',p.due_date,'due_time',p.due_time,'due_time_zone',p.due_time_zone,'amount',p.amount,'currency',p.currency,'invoice_number',p.invoice_number,'suggested_description',p.suggested_description,'suggested_record_kind',p.suggested_record_kind,'suggested_expense_category',p.suggested_expense_category,'booking_reference',p.booking_reference,'suggested_travel_kind',p.suggested_travel_kind,'suggested_destination',p.suggested_destination,'suggested_trip_name',p.suggested_trip_name,'tags',p.tags,'confidence',p.confidence,'evidence_excerpt',p.evidence_excerpt,'source_sha256',p.source_sha256,'model_name',p.model_name,'status',p.status,'created_at',p.created_at) order by p.created_at desc) from fp.email_classification_proposals p join fp.inbound_emails e on e.id=p.inbound_email_id left join fp.inbound_attachments a on a.id=p.source_attachment_id where p.household_id=hid),'[]'::jsonb);
end $$;

create or replace function fp.ensure_travel_category() returns trigger language plpgsql security definer set search_path=pg_catalog,fp as $$ begin insert into fp.categories(household_id,name,is_system,created_by) values(new.id,'Travel',true,new.owner_user_id) on conflict do nothing;return new;end $$;
drop trigger if exists household_adds_travel_category on fp.households;create trigger household_adds_travel_category after insert on fp.households for each row execute function fp.ensure_travel_category();
insert into fp.categories(household_id,name,is_system,created_by) select h.id,'Travel',true,h.owner_user_id from fp.households h on conflict do nothing;
revoke all on fp.travel_trips,fp.travel_records from public,anon,authenticated;
revoke execute on function fp.store_travel_classification_enrichment(uuid,text,text,text,text),fp.ensure_travel_category() from public,anon,authenticated;grant execute on function fp.store_travel_classification_enrichment(uuid,text,text,text,text) to service_role;
revoke execute on function fp.travel_workspace(),fp.create_travel_trip(text,text,date,date),fp.create_travel_record(uuid,uuid,text,text,text,text,text,timestamptz,timestamptz,numeric,text,text) from public,anon;grant execute on function fp.travel_workspace(),fp.create_travel_trip(text,text,date,date),fp.create_travel_record(uuid,uuid,text,text,text,text,text,timestamptz,timestamptz,numeric,text,text) to authenticated;
commit;
