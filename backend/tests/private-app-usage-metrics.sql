\set ON_ERROR_STOP on
begin;

do $$
begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema='fp' and table_name='app_usage_events'
  ) then raise exception 'app usage table is missing'; end if;
  if has_table_privilege('authenticated','fp.app_usage_events','select') then
    raise exception 'authenticated users must not read aggregate source events';
  end if;
  if not has_function_privilege('authenticated','fp.record_app_hit(uuid)','execute') then
    raise exception 'authenticated app hit function is unavailable';
  end if;
  if has_function_privilege('anon','fp.record_app_hit(uuid)','execute') then
    raise exception 'anonymous app hit recording must be denied';
  end if;
end $$;

rollback;
