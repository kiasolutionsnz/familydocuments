begin;

create table if not exists fp.household_usage_quotas(
  household_id uuid not null references fp.households(id) on delete cascade,
  bucket text not null check(bucket in ('ai_day','ocr_month','email_attachments_month','notifications_month')),
  window_started_at timestamptz not null,
  used integer not null check(used between 0 and 1000000),
  updated_at timestamptz not null default now(),
  primary key(household_id,bucket)
);
alter table fp.household_usage_quotas enable row level security;
alter table fp.household_usage_quotas force row level security;
revoke all on fp.household_usage_quotas from public,anon,authenticated;

create or replace function fp.consume_household_quota(
  family uuid,
  bucket_name text,
  quota_limit integer,
  window_start timestamptz
) returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,fp
as $$
declare row fp.household_usage_quotas;
begin
  if family is null or bucket_name not in ('ai_day','ocr_month','email_attachments_month','notifications_month')
    or quota_limit not between 1 and 100000 or window_start is null or window_start>now() then
    raise exception 'invalid quota request' using errcode='22023';
  end if;
  insert into fp.household_usage_quotas(household_id,bucket,window_started_at,used)
  values(family,bucket_name,window_start,1)
  on conflict(household_id,bucket) do update set
    window_started_at=case
      when fp.household_usage_quotas.window_started_at<excluded.window_started_at then excluded.window_started_at
      else fp.household_usage_quotas.window_started_at end,
    used=case
      when fp.household_usage_quotas.window_started_at<excluded.window_started_at then 1
      else fp.household_usage_quotas.used+1 end,
    updated_at=now()
  returning * into row;
  return jsonb_build_object(
    'allowed',row.used<=quota_limit,
    'remaining',greatest(quota_limit-row.used,0),
    'limit',quota_limit,
    'bucket',bucket_name,
    'window_started_at',row.window_started_at
  );
end
$$;
revoke all on function fp.consume_household_quota(uuid,text,integer,timestamptz) from public,anon,authenticated;

create or replace function fp.enforce_free_tier_insert_quota() returns trigger
language plpgsql
security definer
set search_path=pg_catalog,fp
as $$
declare result jsonb;
begin
  if tg_table_name='document_analysis_jobs' then
    result:=fp.consume_household_quota(new.household_id,'ocr_month',200,date_trunc('month',now()));
  elsif tg_table_name='inbound_attachments' then
    result:=fp.consume_household_quota(new.household_id,'email_attachments_month',500,date_trunc('month',now()));
  elsif tg_table_name='notification_outbox' then
    result:=fp.consume_household_quota(new.household_id,'notifications_month',1000,date_trunc('month',now()));
  else
    raise exception 'unsupported quota trigger' using errcode='55000';
  end if;
  if not coalesce((result->>'allowed')::boolean,false) then
    raise exception 'free tier quota reached' using errcode='PT429';
  end if;
  return new;
end
$$;

drop trigger if exists document_analysis_jobs_free_tier_quota on fp.document_analysis_jobs;
create trigger document_analysis_jobs_free_tier_quota before insert on fp.document_analysis_jobs
for each row execute function fp.enforce_free_tier_insert_quota();
drop trigger if exists inbound_attachments_free_tier_quota on fp.inbound_attachments;
create trigger inbound_attachments_free_tier_quota before insert on fp.inbound_attachments
for each row execute function fp.enforce_free_tier_insert_quota();
drop trigger if exists notification_outbox_free_tier_quota on fp.notification_outbox;
create trigger notification_outbox_free_tier_quota before insert on fp.notification_outbox
for each row execute function fp.enforce_free_tier_insert_quota();

create or replace function fp.consume_conversation_rate_limit(bucket_name text,request_limit integer default 10,window_seconds integer default 60) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();row fp.conversation_rate_limits;now_at timestamptz:=clock_timestamp();daily jsonb;short_allowed boolean;
begin
  if bucket_name !~ '^[a-z0-9_-]{2,40}$' or request_limit not between 1 and 100 or window_seconds not between 10 and 3600 then raise exception 'invalid rate limit' using errcode='22023';end if;
  insert into fp.conversation_rate_limits(household_id,user_id,bucket,window_started_at,request_count) values(hid,uid,bucket_name,now_at,1)
    on conflict(household_id,user_id,bucket) do update set window_started_at=case when fp.conversation_rate_limits.window_started_at<=now_at-make_interval(secs=>window_seconds) then now_at else fp.conversation_rate_limits.window_started_at end,request_count=case when fp.conversation_rate_limits.window_started_at<=now_at-make_interval(secs=>window_seconds) then 1 else fp.conversation_rate_limits.request_count+1 end returning * into row;
  daily:=fp.consume_household_quota(hid,'ai_day',100,date_trunc('day',now_at));
  short_allowed:=row.request_count<=request_limit;
  return jsonb_build_object(
    'allowed',short_allowed and (daily->>'allowed')::boolean,
    'remaining',least(greatest(request_limit-row.request_count,0),(daily->>'remaining')::integer),
    'family_id',hid,
    'daily_limit',100,
    'daily_remaining',(daily->>'remaining')::integer
  );
end$$;

revoke execute on function fp.consume_conversation_rate_limit(text,integer,integer) from public,anon,authenticated;
grant execute on function fp.consume_conversation_rate_limit(text,integer,integer) to service_role;

comment on table fp.household_usage_quotas is
  'Free-tier abuse controls for service-cost operations. Google Drive storage bytes are not counted.';

commit;
