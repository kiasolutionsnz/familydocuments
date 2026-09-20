begin;

do $$
begin
  if to_regclass('fp.push_devices') is null or to_regclass('fp.push_notification_outbox') is null then
    raise exception 'push notification tables are missing';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='fp' and table_name='reminder_delivery_preferences' and column_name='push_enabled') then
    raise exception 'push reminder preference is missing';
  end if;
  if to_regprocedure('fp.register_push_device(text,text)') is null
    or to_regprocedure('fp.disable_all_push_devices()') is null
    or to_regprocedure('fp.enqueue_due_push_notifications()') is null
    or to_regprocedure('fp.claim_push_notification_batch(integer)') is null then
    raise exception 'push notification functions are missing';
  end if;
end$$;

rollback;
