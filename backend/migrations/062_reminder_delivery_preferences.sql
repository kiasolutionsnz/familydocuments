begin;

-- Email remains the only delivery channel. Each member can opt out of their
-- own reminder emails without changing shared reminder visibility or delivery
-- for anyone else.
create table if not exists fp.reminder_delivery_preferences(
  household_id uuid not null references fp.households(id) on delete cascade,
  user_id uuid not null,
  email_enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(household_id,user_id)
);
alter table fp.reminder_delivery_preferences enable row level security;
alter table fp.reminder_delivery_preferences force row level security;
revoke all on fp.reminder_delivery_preferences from public,anon,authenticated;

create or replace function fp.reminder_delivery_settings() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();address text;
begin
  select email into address from fp.members where household_id=hid and user_id=uid and status='active';
  if hid is null or address is null then raise exception 'not authorised' using errcode='42501';end if;
  return jsonb_build_object(
    'email_enabled',coalesce((select email_enabled from fp.reminder_delivery_preferences where household_id=hid and user_id=uid),true),
    'history',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'subject',o.subject,'status',o.status,'created_at',o.created_at,'sent_at',o.sent_at) order by o.created_at desc)
      from (select * from fp.notification_outbox where household_id=hid and kind='reminder' and lower(recipient_email)=lower(address) order by created_at desc limit 30) o),'[]'::jsonb)
  );
end$$;

create or replace function fp.set_reminder_email_delivery(enabled boolean) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid:=fp.active_family_id();
begin
  if hid is null or not exists(select 1 from fp.members where household_id=hid and user_id=uid and status='active') then raise exception 'not authorised' using errcode='42501';end if;
  insert into fp.reminder_delivery_preferences(household_id,user_id,email_enabled)
  values(hid,uid,enabled)
  on conflict(household_id,user_id) do update set email_enabled=excluded.email_enabled,updated_at=now();
  return jsonb_build_object('email_enabled',enabled);
end$$;

create or replace function fp.enqueue_due_notifications() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501';end if;
  insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
  select r.household_id,'reminder',m.email,'Due today — '||r.title,
    r.title||' is due today, '||to_char(r.due_at,'DD Mon YYYY')||'. Sign in to acknowledge it or mark it complete.',
    'reminder_due_day:'||r.id::text||':'||r.due_at::text||':'||m.user_id::text,
    (r.due_at+coalesce(r.due_time,time '08:00')) at time zone r.due_time_zone
  from fp.reminders r
  left join fp.documents d on d.id=r.document_id
  join fp.members m on m.household_id=r.household_id and m.status='active' and
    ((r.audience='personal' and m.user_id=r.created_by) or (r.audience='family' and (r.email_all_members or m.user_id=r.created_by)))
  left join fp.reminder_delivery_preferences p on p.household_id=m.household_id and p.user_id=m.user_id
  where r.status='upcoming' and (r.document_id is null or d.lifecycle_status='active')
    and r.due_at between (now() at time zone 'Pacific/Auckland')::date and (now() at time zone 'Pacific/Auckland')::date+7
    and coalesce(p.email_enabled,true)
  on conflict(dedupe_key) do nothing;
  get diagnostics changed=row_count;
  return jsonb_build_object('queued',changed,'default_delivery_time','08:00','time_zone','Pacific/Auckland');
end$$;

revoke execute on function fp.reminder_delivery_settings(),fp.set_reminder_email_delivery(boolean),fp.enqueue_due_notifications() from public,anon;
grant execute on function fp.reminder_delivery_settings(),fp.set_reminder_email_delivery(boolean) to authenticated;
grant execute on function fp.enqueue_due_notifications() to service_role;

commit;
