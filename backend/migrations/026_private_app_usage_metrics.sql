begin;

create table if not exists fp.app_usage_events (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  household_id uuid references fp.households(id) on delete set null,
  hit_id uuid not null,
  occurred_at timestamptz not null default now(),
  unique(user_id, hit_id)
);

create index if not exists app_usage_events_occurred_at
  on fp.app_usage_events(occurred_at desc);

alter table fp.app_usage_events enable row level security;
alter table fp.app_usage_events force row level security;

create or replace function fp.record_app_hit(hit_id uuid) returns void
language plpgsql security definer
set search_path = pg_catalog, fp
as $$
declare
  uid uuid := fp.current_user_id();
  hid uuid;
begin
  if uid is null or hit_id is null then
    raise exception 'authentication required' using errcode='28000';
  end if;

  select household_id into hid
  from fp.members
  where user_id=uid and status='active'
  order by joined_at
  limit 1;

  insert into fp.app_usage_events(user_id,household_id,hit_id)
  values(uid,hid,hit_id)
  on conflict(user_id,hit_id) do nothing;

  delete from fp.app_usage_events where occurred_at < now()-interval '90 days';
end $$;

revoke all on fp.app_usage_events from public,anon,authenticated;
revoke execute on function fp.record_app_hit(uuid) from public,anon;
grant execute on function fp.record_app_hit(uuid) to authenticated;

commit;
