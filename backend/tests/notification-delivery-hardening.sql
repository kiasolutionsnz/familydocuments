begin;
do $$
declare hid uuid:=gen_random_uuid(); notification_id uuid:=gen_random_uuid(); second_id uuid:=gen_random_uuid(); result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic notification delivery',gen_random_uuid());
  insert into fp.notification_outbox(id,household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
    values(notification_id,hid,'reminder','delivery@example.test','Synthetic delivery','No real content','notification-hardening:'||notification_id,now());
  result:=fp.claim_notification_batch(1);
  if jsonb_array_length(result)<>1 or (select attempts from fp.notification_outbox where id=notification_id)<>1 then raise exception 'first claim failed'; end if;
  result:=fp.complete_notification(notification_id,false,null,'smtp_delivery_failed');
  if result->>'status'<>'failed' or not exists(select 1 from fp.notification_outbox where id=notification_id and available_at between now()+interval '50 seconds' and now()+interval '70 seconds') then raise exception 'bounded retry backoff failed'; end if;
  update fp.notification_outbox set attempts=7,available_at=now() where id=notification_id;
  perform fp.claim_notification_batch(1); result:=fp.complete_notification(notification_id,false,null,'smtp_delivery_failed');
  if result->>'status'<>'dead_letter' then raise exception 'retry limit did not dead-letter'; end if;
  update fp.notification_outbox set status='sent',attempts=1,provider_message_id='<fp-'||notification_id||'@familydocuments.app>' where id=notification_id;
  result:=fp.record_notification_provider_event('synthetic-hard-bounce','bounce','delivery@example.test','<fp-'||notification_id||'@familydocuments.app>','hard',now());
  if result->>'status'<>'bounced' or result->>'suppressed'<>'true' then raise exception 'hard bounce was not suppressed'; end if;
  result:=fp.record_notification_provider_event('synthetic-hard-bounce','bounce','delivery@example.test','<fp-'||notification_id||'@familydocuments.app>','hard',now());
  if result->>'duplicate'<>'true' then raise exception 'provider event was not idempotent'; end if;
  insert into fp.notification_outbox(id,household_id,kind,recipient_email,subject,body_text,dedupe_key,available_at)
    values(second_id,hid,'reminder','DELIVERY@example.test','Future delivery','No real content','notification-hardening:'||second_id,now());
  result:=fp.claim_notification_batch(10);
  if jsonb_array_length(result)<>0 or not exists(select 1 from fp.notification_outbox where id=second_id and status='suppressed' and safe_error_code='recipient_suppressed') then raise exception 'suppressed recipient was claimable'; end if;
  delete from fp.notification_recipient_suppressions where recipient_email='delivery@example.test';
  update fp.notification_outbox set status='sent' where id=notification_id;
  perform fp.record_notification_provider_event('synthetic-unsubscribe','unsubscribe','delivery@example.test','<fp-'||notification_id||'@familydocuments.app>',null,now());
  if not exists(select 1 from fp.notification_recipient_suppressions where recipient_email='delivery@example.test' and reason='unsubscribe') then raise exception 'unsubscribe missing'; end if;
  perform fp.record_notification_provider_event('synthetic-resubscribe','resubscribe','delivery@example.test','<fp-'||notification_id||'@familydocuments.app>',null,now());
  if exists(select 1 from fp.notification_recipient_suppressions where recipient_email='delivery@example.test') then raise exception 'resubscribe did not clear provider unsubscribe'; end if;
end $$;
rollback;
