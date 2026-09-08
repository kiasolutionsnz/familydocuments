begin;

alter table fp.household_inbox_aliases drop constraint if exists household_inbox_aliases_local_part_check;
alter table fp.household_inbox_aliases add constraint household_inbox_aliases_local_part_check
  check (local_part ~ '^(family-[0-9a-f]{24}|[a-z0-9][a-z0-9-]{2,39})$');

create or replace function fp.set_household_inbox_alias(preferred_local_part text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  uid uuid:=fp.current_user_id(); hid uuid; candidate text:=lower(trim(preferred_local_part));
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null or not fp.is_household_admin(hid) then raise exception 'not authorised' using errcode='42501'; end if;
  if candidate !~ '^[a-z0-9][a-z0-9-]{2,39}$' or candidate ~ '--' then
    raise exception 'inbox name must be 3 to 40 lowercase letters, numbers or single hyphens' using errcode='22023';
  end if;
  if candidate = any(array['admin','administrator','abuse','billing','contact','help','info','mailer-daemon','no-reply','noreply','postmaster','privacy','security','support','webmaster']) then
    raise exception 'reserved inbox name' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(hid::text,0));
  if exists(select 1 from fp.household_inbox_aliases where local_part=candidate and household_id<>hid) then
    raise exception 'inbox name unavailable' using errcode='23505';
  end if;
  update fp.household_inbox_aliases set status='rotated',ended_at=now() where household_id=hid and status='active';
  insert into fp.household_inbox_aliases(household_id,local_part,domain,created_by)
    values(hid,candidate,'familydocuments.servicehub.co.nz',uid);
  return fp.household_snapshot();
exception when unique_violation then
  raise exception 'inbox name unavailable' using errcode='23505';
end $$;

revoke execute on function fp.set_household_inbox_alias(text) from public,anon;
grant execute on function fp.set_household_inbox_alias(text) to authenticated;

commit;
