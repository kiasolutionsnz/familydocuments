begin;

create table fp.push_devices(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check(platform in ('android','ios')),
  token text not null,
  token_hash text generated always as (encode(digest(token,'sha256'),'hex')) stored,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(user_id,token_hash)
);
alter table fp.push_devices enable row level security;
alter table fp.push_devices force row level security;
revoke all on fp.push_devices from public,anon,authenticated;

create table fp.push_notification_outbox(
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references fp.push_devices(id) on delete cascade,
  title text not null check(char_length(title) between 1 and 120),
  body_text text not null check(char_length(body_text) between 1 and 500),
  route text not null default '/reminders' check(char_length(route) between 1 and 200),
  status text not null default 'pending' check(status in ('pending','sending','sent','failed','dead_letter')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  lease_until timestamptz,
  provider_message_id text,
  safe_error_code text,
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
alter table fp.push_notification_outbox enable row level security;
alter table fp.push_notification_outbox force row level security;
revoke all on fp.push_notification_outbox from public,anon,authenticated;

alter table fp.reminder_delivery_preferences
  add column if not exists push_enabled boolean not null default false;

create or replace function fp.reminder_delivery_settings() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();address text;
begin
  select email into address from fp.members where household_id=hid and user_id=uid and status='active';
  if hid is null or address is null then raise exception 'not authorised' using errcode='42501';end if;
  return jsonb_build_object(
    'email_enabled',coalesce((select email_enabled from fp.reminder_delivery_preferences where household_id=hid and user_id=uid),true),
    'push_enabled',coalesce((select push_enabled from fp.reminder_delivery_preferences where household_id=hid and user_id=uid),false),
    'history',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'subject',o.subject,'status',o.status,'created_at',o.created_at,'sent_at',o.sent_at) order by o.created_at desc)
      from (select * from fp.notification_outbox where household_id=hid and kind='reminder' and lower(recipient_email)=lower(address) order by created_at desc limit 30) o),'[]'::jsonb)
  );
end$$;

create or replace function fp.register_push_device(device_token text,device_platform text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare uid uuid:=fp.current_user_id(); row fp.push_devices;
begin
  if uid is null or device_platform not in ('android','ios') or char_length(trim(device_token)) not between 20 and 4096 then
    raise exception 'invalid push device' using errcode='22023';
  end if;
  insert into fp.push_devices(user_id,platform,token)
  values(uid,device_platform,trim(device_token))
  on conflict(user_id,token_hash) do update set enabled=true,platform=excluded.platform,last_seen_at=now()
  returning * into row;
  return jsonb_build_object('registered',true,'device_id',row.id,'platform',row.platform);
end$$;

create or replace function fp.disable_push_device(device_token text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp,extensions as $$
declare uid uuid:=fp.current_user_id(); changed integer;
begin
  update fp.push_devices set enabled=false,last_seen_at=now()
  where user_id=uid and token_hash=encode(digest(trim(device_token),'sha256'),'hex');
  get diagnostics changed=row_count;
  return jsonb_build_object('disabled',changed>0);
end$$;

create or replace function fp.disable_all_push_devices() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); changed integer;
begin
  update fp.push_devices set enabled=false,last_seen_at=now() where user_id=uid and enabled;
  get diagnostics changed=row_count;
  return jsonb_build_object('disabled',changed);
end$$;

create or replace function fp.set_reminder_push_delivery(enabled boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
begin
  if hid is null or not exists(select 1 from fp.members where household_id=hid and user_id=uid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.reminder_delivery_preferences(household_id,user_id,push_enabled)
  values(hid,uid,enabled)
  on conflict(household_id,user_id) do update set push_enabled=excluded.push_enabled,updated_at=now();
  return jsonb_build_object('push_enabled',enabled);
end$$;

create or replace function fp.enqueue_due_push_notifications() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  insert into fp.push_notification_outbox(household_id,user_id,device_id,title,body_text,route,dedupe_key,available_at)
  select r.household_id,m.user_id,pd.id,'Due today — '||r.title,
    r.title||' is due today, '||to_char(r.due_at,'DD Mon YYYY')||'.','/reminders',
    'reminder_push:'||r.id::text||':'||r.due_at::text||':'||m.user_id::text||':'||pd.id::text,
    (r.due_at+coalesce(r.due_time,time '08:00')) at time zone r.due_time_zone
  from fp.reminders r
  left join fp.documents d on d.id=r.document_id
  join fp.members m on m.household_id=r.household_id and m.status='active' and
    ((r.audience='personal' and m.user_id=r.created_by) or (r.audience='family' and (r.email_all_members or m.user_id=r.created_by)))
  join fp.reminder_delivery_preferences pref on pref.household_id=m.household_id and pref.user_id=m.user_id and pref.push_enabled
  join fp.push_devices pd on pd.user_id=m.user_id and pd.enabled
  where r.status='upcoming' and (r.document_id is null or d.lifecycle_status='active')
    and r.due_at between (now() at time zone 'Pacific/Auckland')::date and (now() at time zone 'Pacific/Auckland')::date+7
  on conflict(dedupe_key) do nothing;
  get diagnostics changed=row_count;
  return jsonb_build_object('queued',changed);
end$$;

create or replace function fp.claim_push_notification_batch(batch_size integer default 20) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  update fp.push_notification_outbox set status='dead_letter',safe_error_code=coalesce(safe_error_code,'retry_limit_reached'),lease_until=null
  where status in ('pending','failed') and attempts>=8;
  with chosen as (
    select o.id from fp.push_notification_outbox o join fp.push_devices d on d.id=o.device_id
    where o.status in ('pending','failed') and o.available_at<=now() and (o.lease_until is null or o.lease_until<now()) and o.attempts<8 and d.enabled
    order by o.available_at for update of o skip locked limit least(greatest(batch_size,1),50)
  ), updated as (
    update fp.push_notification_outbox o set status='sending',attempts=attempts+1,lease_until=now()+interval '2 minutes'
    from chosen,fp.push_devices d where o.id=chosen.id and d.id=o.device_id
    returning o.id,o.device_id,o.title,o.body_text,o.route,d.token
  ) select coalesce(jsonb_agg(to_jsonb(updated)),'[]'::jsonb) into result from updated;
  return result;
end$$;

create or replace function fp.complete_push_notification(notification uuid,sent boolean,provider_id text default null,error_code text default null,disable_device boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.push_notification_outbox; next_status text;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  select * into row from fp.push_notification_outbox where id=notification for update;
  if row.id is null then return jsonb_build_object('updated',false);end if;
  next_status:=case when sent then 'sent' when row.attempts>=8 or disable_device then 'dead_letter' else 'failed' end;
  update fp.push_notification_outbox set status=next_status,provider_message_id=case when sent then left(provider_id,200) end,
    safe_error_code=case when sent then null else left(coalesce(error_code,'push_delivery_failed'),80) end,
    sent_at=case when sent then now() end,lease_until=null,
    available_at=case when sent or disable_device then available_at else now()+make_interval(secs=>least(3600,30*(2^least(attempts,7)))) end
  where id=notification;
  if disable_device then update fp.push_devices set enabled=false where id=row.device_id;end if;
  return jsonb_build_object('updated',true,'status',next_status);
end$$;

revoke execute on function fp.register_push_device(text,text),fp.disable_push_device(text),fp.disable_all_push_devices(),fp.set_reminder_push_delivery(boolean),fp.enqueue_due_push_notifications(),fp.claim_push_notification_batch(integer),fp.complete_push_notification(uuid,boolean,text,text,boolean) from public,anon;
grant execute on function fp.register_push_device(text,text),fp.disable_push_device(text),fp.disable_all_push_devices(),fp.set_reminder_push_delivery(boolean) to authenticated;
grant execute on function fp.enqueue_due_push_notifications(),fp.claim_push_notification_batch(integer),fp.complete_push_notification(uuid,boolean,text,text,boolean) to service_role;

commit;
