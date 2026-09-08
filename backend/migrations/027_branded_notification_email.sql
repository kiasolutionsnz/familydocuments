begin;

create or replace function fp.queue_invitation_email() returns trigger
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  family_name text;
  inviter text;
begin
  select h.name,coalesce(m.display_name,m.email)
  into family_name,inviter
  from fp.households h
  join fp.members m on m.household_id=h.id and m.user_id=new.invited_by
  where h.id=new.household_id;

  insert into fp.notification_outbox(household_id,kind,recipient_email,subject,body_text,dedupe_key)
  values(
    new.household_id,
    'invitation',
    new.email,
    'You’re invited to join '||family_name,
    inviter||' invited you to join “'||family_name||'” on Family Documents.'||E'\n\n'||
      'Open Family Documents, then create an account or sign in using this exact email address. Your invitation will appear automatically.'||E'\n\n'||
      'This invitation expires on '||to_char(new.expires_at at time zone 'Pacific/Auckland','DD Mon YYYY')||'.',
    'invitation:'||new.id::text
  ) on conflict(dedupe_key) do nothing;
  return new;
end $$;

commit;
