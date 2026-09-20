do $$
declare
  member_id uuid;
  owner_id uuid;
  result jsonb;
  household_count bigint;
  drive_credential_count bigint;
begin
  select m.user_id into member_id
  from fp.members m
  join auth.users u on u.id=m.user_id
  join fp.households h on h.id=m.household_id
  where m.status='active' and h.owner_user_id<>m.user_id
  order by m.joined_at
  limit 1;
  if member_id is null then
    raise exception 'account deletion test requires an active non-owner member';
  end if;

  select h.owner_user_id into owner_id
  from fp.households h
  join auth.users u on u.id=h.owner_user_id
  where exists(
    select 1 from fp.members m
    where m.household_id=h.id and m.user_id<>h.owner_user_id and m.status='active'
  )
  limit 1;
  if owner_id is null then
    raise exception 'account deletion test requires an owner with another active member';
  end if;

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',owner_id,'role','authenticated')::text,
    true
  );
  begin
    perform fp.delete_my_account('DELETE');
    raise exception 'owner deletion should require an ownership transfer';
  exception when sqlstate 'PT409' then
    null;
  end;
  if not exists(select 1 from auth.users where id=owner_id) then
    raise exception 'blocked owner was deleted';
  end if;

  select count(*) into household_count from fp.households;
  select count(*) into drive_credential_count from fp.google_drive_credentials;
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',member_id,'role','authenticated')::text,
    true
  );
  result:=fp.delete_my_account('DELETE');
  if result->>'deleted'<>'true' or result->>'google_drive_files_deleted'<>'false' then
    raise exception 'account deletion result was not explicit about Drive preservation';
  end if;
  if exists(select 1 from auth.users where id=member_id) then
    raise exception 'auth user was not deleted';
  end if;
  if exists(select 1 from fp.members where user_id=member_id) then
    raise exception 'family membership was not deleted';
  end if;
  if (select count(*) from fp.households)<>household_count then
    raise exception 'non-owner deletion changed household records';
  end if;
  if (select count(*) from fp.google_drive_credentials)<>drive_credential_count then
    raise exception 'non-owner deletion changed Google Drive credentials';
  end if;
end
$$;
