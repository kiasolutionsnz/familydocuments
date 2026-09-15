begin;

create table if not exists fp.rental_income_entries(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  property_entity_id uuid not null references fp.rental_properties(entity_id) on delete cascade,
  received_on date not null,
  amount numeric(14,2) not null check(amount>=0),
  currency text not null default 'NZD' check(currency~'^[A-Z]{3}$'),
  description text not null check(char_length(trim(description)) between 1 and 240),
  document_id uuid references fp.documents(id) on delete set null,
  recorded_by uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists rental_income_property_date_idx on fp.rental_income_entries(property_entity_id,received_on);
alter table fp.rental_income_entries enable row level security;
alter table fp.rental_income_entries force row level security;
revoke all on fp.rental_income_entries from public,anon,authenticated;

create or replace function fp.add_rental_income(property uuid,received_date date,received_amount numeric,received_currency text default 'NZD',income_description text default 'Rental income',related_document uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();p fp.rental_properties;row fp.rental_income_entries;
begin
  select * into p from fp.rental_properties where entity_id=property;
  if p.entity_id is null or not fp.is_active_member(p.household_id) or not (fp.is_household_admin(p.household_id) or p.created_by=uid or exists(select 1 from fp.access_rules a where a.household_id=p.household_id and a.scope_type='entity' and a.entity_id=p.entity_id and a.member_user_id=uid)) then raise exception 'not authorised' using errcode='42501';end if;
  if received_date is null or received_amount is null or received_amount<0 or upper(received_currency)!~'^[A-Z]{3}$' or char_length(trim(income_description)) not between 1 and 240 then raise exception 'invalid rental income' using errcode='22023';end if;
  if related_document is not null and not exists(select 1 from fp.documents d where d.id=related_document and d.household_id=p.household_id and d.lifecycle_status='active' and (d.created_by=uid or fp.is_household_admin(p.household_id) or exists(select 1 from fp.document_permissions x where x.document_id=d.id and x.member_user_id=uid and x.access_level in ('contribute','manage')))) then raise exception 'document unavailable' using errcode='42501';end if;
  insert into fp.rental_income_entries(household_id,property_entity_id,received_on,amount,currency,description,document_id,recorded_by) values(p.household_id,p.entity_id,received_date,received_amount,upper(received_currency),trim(income_description),related_document,uid) returning * into row;
  return jsonb_build_object('id',row.id,'property_id',row.property_entity_id,'received_on',row.received_on,'amount',row.amount,'currency',row.currency);
end$$;

create or replace function fp.rental_financial_year_review(property uuid,financial_year_start date) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();p fp.rental_properties;year_end date;expenses jsonb;income jsonb;
begin
  select * into p from fp.rental_properties where entity_id=property;
  if p.entity_id is null or not fp.is_active_member(p.household_id) or not (fp.is_household_admin(p.household_id) or p.created_by=uid or exists(select 1 from fp.access_rules a where a.household_id=p.household_id and a.scope_type='entity' and a.entity_id=p.entity_id and a.member_user_id=uid)) then raise exception 'not authorised' using errcode='42501';end if;
  if financial_year_start is null or extract(month from financial_year_start)<>4 or extract(day from financial_year_start)<>1 then raise exception 'financial year must begin on 1 April' using errcode='22023';end if;
  year_end:=(financial_year_start+interval '1 year')::date;
  select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount) order by currency),'[]'::jsonb) into expenses from (select coalesce(b.currency,'NZD') currency,sum(coalesce(b.amount,d.amount,0)) amount from fp.rental_bills b join fp.documents d on d.id=b.document_id where b.property_entity_id=p.entity_id and coalesce(b.paid_date,b.due_date,d.document_date,d.created_at::date)>=financial_year_start and coalesce(b.paid_date,b.due_date,d.document_date,d.created_at::date)<year_end group by b.currency) x;
  select coalesce(jsonb_agg(jsonb_build_object('currency',currency,'amount',amount) order by currency),'[]'::jsonb) into income from (select currency,sum(amount) amount from fp.rental_income_entries where property_entity_id=p.entity_id and received_on>=financial_year_start and received_on<year_end group by currency) x;
  return jsonb_build_object('property_id',p.entity_id,'financial_year_start',financial_year_start,'financial_year_end',year_end-1,'income',income,'expenses',expenses,'notice','Organisation summary only; confirm tax treatment with your adviser.');
end$$;

revoke execute on function fp.add_rental_income(uuid,date,numeric,text,text,uuid),fp.rental_financial_year_review(uuid,date) from public,anon;
grant execute on function fp.add_rental_income(uuid,date,numeric,text,text,uuid),fp.rental_financial_year_review(uuid,date) to authenticated;

commit;
