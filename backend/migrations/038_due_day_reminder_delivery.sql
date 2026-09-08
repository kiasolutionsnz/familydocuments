begin;

create or replace function fp.enqueue_due_notifications() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare changed integer;
begin
  if current_user not in ('postgres','service_role') then
    raise exception 'service role required' using errcode='42501';
  end if;

  insert into fp.notification_outbox(
    household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at
  )
  select
    r.household_id,
    'reminder',
    m.email,
    'Due today — '||r.title,
    r.title||' is due today, '||to_char(r.due_at,'DD Mon YYYY')||'. Sign in to acknowledge it or mark it complete.',
    'reminder_due_day:'||r.id::text||':'||r.due_at::text||':'||m.user_id::text,
    (r.due_at+time '08:00') at time zone 'Pacific/Auckland'
  from fp.reminders r
  join fp.documents d on d.id=r.document_id and d.lifecycle_status='active'
  join fp.members m on m.household_id=r.household_id
    and m.status='active'
    and (
      (r.audience='personal' and m.user_id=r.created_by)
      or (r.audience='family' and (r.email_all_members or m.user_id=r.created_by))
    )
  where r.status='upcoming'
    and r.due_at between (now() at time zone 'Pacific/Auckland')::date
      and (now() at time zone 'Pacific/Auckland')::date+7
  on conflict(dedupe_key) do nothing;

  get diagnostics changed=row_count;
  return jsonb_build_object('queued',changed,'delivery_time','08:00','time_zone','Pacific/Auckland');
end $$;

revoke execute on function fp.enqueue_due_notifications() from public,anon,authenticated;
grant execute on function fp.enqueue_due_notifications() to service_role;

commit;
