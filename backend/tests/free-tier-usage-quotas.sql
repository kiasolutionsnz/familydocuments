do $$
declare
  family_id uuid;
  first_result jsonb;
  second_result jsonb;
  third_result jsonb;
begin
  select id into family_id from fp.households order by created_at limit 1;
  if family_id is null then raise exception 'quota test requires a Family'; end if;

  first_result:=fp.consume_household_quota(family_id,'ai_day',2,date_trunc('day',now()));
  second_result:=fp.consume_household_quota(family_id,'ai_day',2,date_trunc('day',now()));
  third_result:=fp.consume_household_quota(family_id,'ai_day',2,date_trunc('day',now()));
  if (first_result->>'allowed')::boolean is not true
    or (second_result->>'allowed')::boolean is not true
    or (third_result->>'allowed')::boolean is not false then
    raise exception 'quota boundary did not allow two and reject the third';
  end if;
  if (third_result->>'remaining')::integer<>0 then
    raise exception 'quota remaining count is incorrect';
  end if;
  if not exists(select 1 from pg_trigger where tgname='document_analysis_jobs_free_tier_quota' and not tgisinternal)
    or not exists(select 1 from pg_trigger where tgname='inbound_attachments_free_tier_quota' and not tgisinternal)
    or not exists(select 1 from pg_trigger where tgname='notification_outbox_free_tier_quota' and not tgisinternal) then
    raise exception 'one or more quota enforcement triggers are missing';
  end if;
end
$$;
