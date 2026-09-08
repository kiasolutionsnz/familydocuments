begin;

create table if not exists fp.travel_itinerary_entries(
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references fp.travel_trips(id) on delete cascade,
  household_id uuid not null references fp.households(id) on delete cascade,
  item_kind text not null check(item_kind in ('flight','accommodation','rail','ferry','car_rental','activity','meal','transfer','note','other')),
  title text not null check(char_length(title) between 1 and 160),
  provider text check(provider is null or char_length(provider)<=120),
  origin text check(origin is null or char_length(origin)<=160),
  destination text check(destination is null or char_length(destination)<=160),
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null default 'planned' check(status in ('planned','completed','cancelled')),
  booking_reference text check(booking_reference is null or char_length(booking_reference)<=100),
  notes text check(notes is null or char_length(notes)<=500),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_by uuid not null,
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  check(ends_at is null or starts_at is null or ends_at>=starts_at)
);
create index if not exists travel_itinerary_trip_time_idx on fp.travel_itinerary_entries(trip_id,starts_at,created_at);
alter table fp.travel_itinerary_entries enable row level security;
alter table fp.travel_itinerary_entries force row level security;
drop policy if exists travel_itinerary_authorised_read on fp.travel_itinerary_entries;
create policy travel_itinerary_authorised_read on fp.travel_itinerary_entries for select using(fp.can_manage_trip(trip_id,'view'));

create or replace function fp.create_travel_itinerary_entry(trip uuid,item_kind text,item_title text,provider_name text default null,origin_name text default null,destination_name text default null,starts timestamptz default null,ends timestamptz default null,booking_ref text default null,item_notes text default null) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare t fp.travel_trips;row fp.travel_itinerary_entries;begin
  if not fp.can_manage_trip(trip,'contribute') then raise exception 'not authorised' using errcode='42501';end if;
  select * into t from fp.travel_trips where id=trip;
  if t.id is null or item_kind not in ('flight','accommodation','rail','ferry','car_rental','activity','meal','transfer','note','other') or char_length(trim(coalesce(item_title,''))) not between 1 and 160 or (ends is not null and starts is not null and ends<starts) then raise exception 'invalid itinerary entry' using errcode='22023';end if;
  insert into fp.travel_itinerary_entries(trip_id,household_id,item_kind,title,provider,origin,destination,starts_at,ends_at,booking_reference,notes,created_by,updated_by) values(t.id,t.household_id,item_kind,trim(item_title),nullif(left(trim(provider_name),120),''),nullif(left(trim(origin_name),160),''),nullif(left(trim(destination_name),160),''),starts,ends,nullif(left(trim(booking_ref),100),''),nullif(left(trim(item_notes),500),''),fp.current_user_id(),fp.current_user_id()) returning * into row;
  return jsonb_build_object('id',row.id,'trip_id',row.trip_id,'status',row.status);
end$$;

create or replace function fp.update_travel_itinerary_entry(entry uuid,item_kind text,item_title text,provider_name text,origin_name text,destination_name text,starts timestamptz,ends timestamptz,booking_ref text,item_notes text,item_status text) returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare row fp.travel_itinerary_entries;begin
  select * into row from fp.travel_itinerary_entries where id=entry;
  if row.id is null or not fp.can_manage_trip(row.trip_id,'contribute') then raise exception 'not authorised' using errcode='42501';end if;
  if item_kind not in ('flight','accommodation','rail','ferry','car_rental','activity','meal','transfer','note','other') or item_status not in ('planned','completed','cancelled') or char_length(trim(coalesce(item_title,''))) not between 1 and 160 or (ends is not null and starts is not null and ends<starts) then raise exception 'invalid itinerary entry' using errcode='22023';end if;
  update fp.travel_itinerary_entries i set item_kind=$2,title=trim($3),provider=nullif(left(trim($4),120),''),origin=nullif(left(trim($5),160),''),destination=nullif(left(trim($6),160),''),starts_at=$7,ends_at=$8,booking_reference=nullif(left(trim($9),100),''),notes=nullif(left(trim($10),500),''),status=$11,updated_by=fp.current_user_id(),updated_at=now(),completed_at=case when $11='completed' then coalesce(i.completed_at,now()) else null end,cancelled_at=case when $11='cancelled' then coalesce(i.cancelled_at,now()) else null end where i.id=$1;
  return jsonb_build_object('id',entry,'trip_id',row.trip_id,'status',item_status);
end$$;

create or replace function fp.travel_workspace() returns jsonb language plpgsql security definer set search_path=pg_catalog,fp as $$declare uid uuid:=fp.current_user_id();hid uuid;begin select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;if hid is null then return jsonb_build_object('trips','[]'::jsonb,'records','[]'::jsonb,'travellers','[]'::jsonb,'shares','[]'::jsonb,'costs','[]'::jsonb,'itinerary_entries','[]'::jsonb);end if;return jsonb_build_object('trips',coalesce((select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'destination',t.destination,'start_date',t.start_date,'end_date',t.end_date,'status',t.status,'home_currency',t.home_currency,'budget',t.budget,'notes',t.notes,'can_manage',fp.can_manage_trip(t.id,'manage'),'can_contribute',fp.can_manage_trip(t.id,'contribute')) order by coalesce(t.start_date,'9999-12-31')) from fp.travel_trips t where t.household_id=hid and fp.can_manage_trip(t.id,'view')),'[]'::jsonb),'records',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'trip_id',r.trip_id,'document_id',r.document_id,'document_title',d.title,'trip_name',t.name,'travel_kind',r.travel_kind,'booking_reference',r.booking_reference,'provider',r.provider,'origin',r.origin,'destination',r.destination,'starts_at',r.starts_at,'ends_at',r.ends_at,'amount',r.amount,'currency',r.currency,'notes',r.notes) order by coalesce(r.starts_at,r.confirmed_at)) from fp.travel_records r join fp.travel_trips t on t.id=r.trip_id join fp.documents d on d.id=r.document_id where r.household_id=hid and fp.can_manage_trip(t.id,'view') and (fp.is_household_admin(hid) or d.created_by=uid or exists(select 1 from fp.document_permissions p where p.document_id=d.id and p.member_user_id=uid))),'[]'::jsonb),'travellers',coalesce((select jsonb_agg(to_jsonb(v) order by v.name) from fp.travel_trip_travellers v where v.household_id=hid and fp.can_manage_trip(v.trip_id,'view')),'[]'::jsonb),'shares',coalesce((select jsonb_agg(to_jsonb(s)) from fp.travel_trip_shares s join fp.travel_trips t on t.id=s.trip_id where t.household_id=hid and (fp.is_household_admin(hid) or t.created_by=uid or s.member_user_id=uid)),'[]'::jsonb),'costs',coalesce((select jsonb_agg(to_jsonb(c) order by c.confirmed_at) from fp.travel_cost_entries c where c.household_id=hid and fp.can_manage_trip(c.trip_id,'view')),'[]'::jsonb),'itinerary_entries',coalesce((select jsonb_agg(to_jsonb(i) order by coalesce(i.starts_at,i.created_at),i.created_at) from fp.travel_itinerary_entries i where i.household_id=hid and fp.can_manage_trip(i.trip_id,'view')),'[]'::jsonb));end$$;

revoke all on fp.travel_itinerary_entries from public,anon,authenticated;
revoke execute on function fp.create_travel_itinerary_entry(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text),fp.update_travel_itinerary_entry(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text) from public,anon;
grant execute on function fp.create_travel_itinerary_entry(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text),fp.update_travel_itinerary_entry(uuid,text,text,text,text,text,timestamptz,timestamptz,text,text,text),fp.travel_workspace() to authenticated;
commit;
