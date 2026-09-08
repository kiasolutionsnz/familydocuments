begin;

alter table fp.notification_outbox drop constraint if exists notification_outbox_status_check;
alter table fp.notification_outbox add constraint notification_outbox_status_check check(status in ('pending','sending','sent','failed','suppressed'));

create or replace function fp.complete_notification(notification uuid,sent boolean,provider_id text default null,error_code text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare next_status text;
begin
  if current_user not in ('postgres','service_role') then raise exception 'service role required' using errcode='42501'; end if;
  next_status:=case when sent then 'sent' when error_code='synthetic_recipient_blocked' then 'suppressed' else 'failed' end;
  update fp.notification_outbox set status=next_status,provider_message_id=case when sent then left(provider_id,200) end,
    safe_error_code=case when sent then null else left(coalesce(error_code,'delivery_failed'),80) end,
    sent_at=case when sent then now() end,lease_until=null,
    available_at=case when next_status in ('sent','suppressed') then available_at else now()+make_interval(secs=>least(3600,30*(2^least(attempts,7)))) end
  where id=notification;
  return jsonb_build_object('updated',found,'status',next_status);
end $$;

update fp.notification_outbox set status='suppressed',lease_until=null
where status='failed' and safe_error_code='synthetic_recipient_blocked';

commit;
