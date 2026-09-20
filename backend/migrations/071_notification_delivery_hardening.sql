begin;

alter table fp.notification_outbox drop constraint if exists notification_outbox_status_check;
alter table fp.notification_outbox add constraint notification_outbox_status_check
  check(status in ('pending','sending','sent','failed','suppressed','bounced','unsubscribed','dead_letter'));

create table if not exists fp.notification_recipient_suppressions(
  recipient_email text primary key,
  reason text not null check(reason in ('hard_bounce','spam_complaint','unsubscribe','manual')),
  source text not null check(source in ('smtp2go','support')),
  provider_event_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(recipient_email=lower(trim(recipient_email)))
);
alter table fp.notification_recipient_suppressions enable row level security;
alter table fp.notification_recipient_suppressions force row level security;
revoke all on fp.notification_recipient_suppressions from public,anon,authenticated;

create table if not exists fp.notification_delivery_events(
  id uuid primary key default gen_random_uuid(),
  notification_id uuid references fp.notification_outbox(id) on delete set null,
  provider_event_key text not null unique,
  event_type text not null check(event_type in ('delivered','bounce','spam','unsubscribe','resubscribe','reject')),
  bounce_type text check(bounce_type is null or bounce_type in ('hard','soft')),
  provider_message_id text,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table fp.notification_delivery_events enable row level security;
alter table fp.notification_delivery_events force row level security;
revoke all on fp.notification_delivery_events from public,anon,authenticated;

create or replace function fp.claim_notification_batch(batch_size integer default 20) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare result jsonb;
begin
  if current_user not in ('postgres','supabase_admin','service_role') then raise exception 'service role required' using errcode='42501'; end if;
  update fp.notification_outbox o set status='suppressed',safe_error_code='recipient_suppressed',lease_until=null
    where o.status in ('pending','failed') and exists(
      select 1 from fp.notification_recipient_suppressions s where s.recipient_email=lower(trim(o.recipient_email))
    );
  update fp.notification_outbox set status='dead_letter',safe_error_code=coalesce(safe_error_code,'retry_limit_reached'),lease_until=null
    where status='failed' and attempts>=8;
  with chosen as (
    select id from fp.notification_outbox
    where status in ('pending','failed') and available_at<=now() and (lease_until is null or lease_until<now()) and attempts<8
    order by available_at for update skip locked limit least(greatest(batch_size,1),50)
  ), updated as (
    update fp.notification_outbox o set status='sending',attempts=attempts+1,lease_until=now()+interval '2 minutes'
    from chosen where o.id=chosen.id returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'recipient_email',recipient_email,'subject',subject,'body_text',body_text)),'[]'::jsonb)
  into result from updated;
  return result;
end $$;

create or replace function fp.complete_notification(notification uuid,sent boolean,provider_id text default null,error_code text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare row fp.notification_outbox; next_status text;
begin
  if current_user not in ('postgres','supabase_admin','service_role') then raise exception 'service role required' using errcode='42501'; end if;
  select * into row from fp.notification_outbox where id=notification for update;
  if row.id is null then return jsonb_build_object('updated',false); end if;
  next_status:=case
    when sent then 'sent'
    when error_code='synthetic_recipient_blocked' then 'suppressed'
    when row.attempts>=8 then 'dead_letter'
    else 'failed'
  end;
  update fp.notification_outbox set status=next_status,
    provider_message_id=case when sent then left(provider_id,200) else provider_message_id end,
    safe_error_code=case when sent then null when next_status='dead_letter' then coalesce(left(error_code,80),'retry_limit_reached') else left(coalesce(error_code,'delivery_failed'),80) end,
    sent_at=case when sent then now() else sent_at end,lease_until=null,
    available_at=case when next_status in ('sent','suppressed','dead_letter') then available_at else now()+make_interval(secs=>least(3600,30*(2^least(row.attempts,7)))) end
  where id=row.id;
  return jsonb_build_object('updated',true,'status',next_status);
end $$;

create or replace function fp.record_notification_provider_event(
  provider_event_key text,event_type text,recipient text,message_id text,bounce_type text default null,occurred_at timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare normal_email text:=lower(trim(recipient)); row fp.notification_outbox; parsed_id uuid; next_status text;
begin
  if current_user not in ('postgres','supabase_admin','service_role') then raise exception 'service role required' using errcode='42501'; end if;
  if length(trim(provider_event_key)) not between 1 and 200
    or event_type not in ('delivered','bounce','spam','unsubscribe','resubscribe','reject')
    or (bounce_type is not null and bounce_type not in ('hard','soft'))
    or normal_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
    or occurred_at>now()+interval '5 minutes' or occurred_at<now()-interval '30 days' then
    raise exception 'invalid provider event' using errcode='22023';
  end if;
  if exists(select 1 from fp.notification_delivery_events e where e.provider_event_key=trim(record_notification_provider_event.provider_event_key)) then
    return jsonb_build_object('recorded',true,'duplicate',true);
  end if;
  begin
    parsed_id:=nullif(substring(coalesce(message_id,'') from 'fp-([0-9a-fA-F-]{36})@'),'')::uuid;
  exception when invalid_text_representation then parsed_id:=null;
  end;
  select * into row from fp.notification_outbox o
    where lower(trim(o.recipient_email))=normal_email
      and (o.provider_message_id=message_id or o.id=parsed_id)
    order by o.created_at desc limit 1 for update;
  if row.id is null then return jsonb_build_object('recorded',false,'reason','notification_not_found'); end if;
  insert into fp.notification_delivery_events(notification_id,provider_event_key,event_type,bounce_type,provider_message_id,occurred_at)
    values(row.id,trim(provider_event_key),event_type,bounce_type,left(message_id,200),occurred_at);
  if event_type='resubscribe' then
    delete from fp.notification_recipient_suppressions where recipient_email=normal_email and reason='unsubscribe' and source='smtp2go';
  elsif event_type='unsubscribe' or event_type='spam' or (event_type='bounce' and bounce_type='hard') then
    insert into fp.notification_recipient_suppressions(recipient_email,reason,source,provider_event_key)
      values(normal_email,case when event_type='unsubscribe' then 'unsubscribe' when event_type='spam' then 'spam_complaint' else 'hard_bounce' end,'smtp2go',trim(provider_event_key))
      on conflict(recipient_email) do update set reason=excluded.reason,source=excluded.source,provider_event_key=excluded.provider_event_key,updated_at=now();
  end if;
  next_status:=case
    when event_type='delivered' then 'sent'
    when event_type='unsubscribe' then 'unsubscribed'
    when event_type='spam' then 'suppressed'
    when event_type='bounce' then 'bounced'
    when event_type='reject' then 'suppressed'
    else row.status
  end;
  update fp.notification_outbox set status=next_status,
    safe_error_code=case when event_type='bounce' then 'recipient_'||coalesce(bounce_type,'unknown')||'_bounce' when event_type='spam' then 'spam_complaint' when event_type='unsubscribe' then 'recipient_unsubscribed' when event_type='reject' then 'provider_rejected' else safe_error_code end,
    lease_until=null where id=row.id;
  return jsonb_build_object('recorded',true,'duplicate',false,'status',next_status,'suppressed',exists(select 1 from fp.notification_recipient_suppressions where recipient_email=normal_email));
end $$;

revoke execute on function fp.claim_notification_batch(integer),fp.complete_notification(uuid,boolean,text,text),fp.record_notification_provider_event(text,text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function fp.claim_notification_batch(integer),fp.complete_notification(uuid,boolean,text,text),fp.record_notification_provider_event(text,text,text,text,text,timestamptz) to service_role;

commit;
