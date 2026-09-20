begin;

create table if not exists fp.account_deletion_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'completed', 'cancelled', 'blocked')),
  processed_at timestamptz,
  processor_note text,
  updated_at timestamptz not null default now()
);

alter table fp.account_deletion_requests enable row level security;
revoke all on fp.account_deletion_requests from public, anon, authenticated;

create or replace function fp.request_my_account_deletion(confirmation text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,fp,auth
as $$
declare
  uid uuid := fp.current_user_id();
  requested timestamptz;
begin
  if uid is null then
    raise exception 'authentication required' using errcode='42501';
  end if;
  if confirmation is distinct from 'DELETE' then
    raise exception 'confirmation required' using errcode='22023';
  end if;

  insert into fp.account_deletion_requests(user_id, requested_at, status, processed_at, processor_note, updated_at)
  values(uid, now(), 'pending', null, null, now())
  on conflict(user_id) do update set
    requested_at=excluded.requested_at,
    status='pending',
    processed_at=null,
    processor_note=null,
    updated_at=now()
  returning requested_at into requested;

  return jsonb_build_object(
    'status', 'pending',
    'requested_at', requested,
    'support_email', 'contact@familydocuments.app'
  );
end
$$;

revoke all on function fp.request_my_account_deletion(text) from public, anon;
grant execute on function fp.request_my_account_deletion(text) to authenticated;
alter function fp.request_my_account_deletion(text) owner to supabase_admin;

create or replace function fp.delete_my_account(confirmation text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,fp,auth
as $$
declare
  uid uuid := fp.current_user_id();
  account_email text;
  blocked_family text;
begin
  if uid is null then
    raise exception 'authentication required' using errcode='42501';
  end if;
  if confirmation is distinct from 'DELETE' then
    raise exception 'confirmation required' using errcode='22023';
  end if;

  select h.name into blocked_family
  from fp.households h
  where h.owner_user_id=uid
    and exists(
      select 1 from fp.members m
      where m.household_id=h.id and m.user_id<>uid and m.status='active'
    )
  order by h.created_at
  limit 1;
  if blocked_family is not null then
    raise exception 'Transfer Family ownership before deleting this account.' using errcode='PT409';
  end if;

  select lower(email) into account_email from auth.users where id=uid for update;
  if account_email is null then
    raise exception 'account unavailable' using errcode='PT404';
  end if;

  -- A sole-owner Family has no remaining app users. Remove its app metadata and
  -- credentials, but never call Google Drive or delete Drive files/folders.
  delete from fp.households h where h.owner_user_id=uid;

  -- Remove user-private and user-addressed app data in Families that remain.
  delete from fp.feedback_replies r using fp.feedback_tickets t
    where r.ticket_id=t.id and t.reporter_id=uid;
  delete from fp.feedback_tickets where reporter_id=uid;
  delete from fp.external_link_tokens where user_id=uid;
  delete from fp.external_identity_links where user_id=uid;
  delete from fp.saved_link_permissions where member_user_id=uid or granted_by=uid;
  delete from fp.saved_link_security_events
    where owner_user_id=uid or actor_user_id=uid or subject_user_id=uid;
  delete from fp.saved_links where owner_user_id=uid;
  delete from fp.saved_link_categories where owner_user_id=uid;
  delete from fp.travel_trip_shares where member_user_id=uid or granted_by=uid;
  delete from fp.travel_trip_travellers where member_user_id=uid;
  delete from fp.reminder_member_responses where member_user_id=uid;
  delete from fp.document_permissions where member_user_id=uid or granted_by=uid;
  delete from fp.access_rules where member_user_id=uid or created_by=uid;
  delete from fp.permission_audit_events where actor_user_id=uid or member_user_id=uid;
  delete from fp.security_audit_events where actor_user_id=uid or subject_user_id=uid;
  delete from fp.reminder_delivery_preferences where user_id=uid;
  delete from fp.app_usage_events where user_id=uid;
  delete from fp.active_family_contexts where user_id=uid;
  delete from fp.conversation_rate_limits where user_id=uid;
  delete from fp.conversations where user_id=uid;
  if to_regclass('fp.notification_delivery_events') is not null then
    execute 'delete from fp.notification_delivery_events e using fp.notification_outbox o where e.notification_id=o.id and lower(o.recipient_email)=$1'
      using account_email;
  end if;
  delete from fp.notification_outbox where lower(recipient_email)=account_email;
  if to_regclass('fp.notification_recipient_suppressions') is not null then
    execute 'delete from fp.notification_recipient_suppressions where recipient_email=$1'
      using account_email;
  end if;
  delete from fp.members where user_id=uid;
  if to_regclass('fp.user_profiles') is not null then
    execute 'delete from fp.user_profiles where user_id=$1' using uid;
  end if;
  delete from fp.account_deletion_requests where user_id=uid;

  -- Supabase cascades identities and sessions from auth.users. The caller's
  -- token becomes unusable after this transaction commits.
  delete from auth.users where id=uid;

  return jsonb_build_object(
    'deleted', true,
    'google_drive_files_deleted', false
  );
end
$$;

revoke all on function fp.delete_my_account(text) from public, anon;
grant execute on function fp.delete_my_account(text) to authenticated;
alter function fp.delete_my_account(text) owner to supabase_admin;

commit;
