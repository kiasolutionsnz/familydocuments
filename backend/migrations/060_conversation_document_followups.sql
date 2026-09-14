begin;

-- Keep document answers grounded in one currently authorised record. The model
-- may select this read action, but neither it nor the client supplies evidence.
alter function fp.run_conversation_execution(uuid) rename to run_conversation_execution_before_060;
create function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare
  e fp.conversation_executions;
  d fp.documents;
  job_status text;
  category_name text;
  question text;
  evidence text;
  answer text;
  result jsonb;
begin
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.user_id<>fp.current_user_id() or e.household_id<>fp.active_family_id() then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if e.action_type<>'search_family_content' or not e.action_parameters?'document_id' then
    return fp.run_conversation_execution_before_060(execution);
  end if;
  perform fp.conversation_member(e.conversation_id);
  d:=fp.authorized_source_document((e.action_parameters->>'document_id')::uuid);
  select c.name into category_name from fp.categories c
    where c.id=d.category_id and c.household_id=e.household_id;
  select j.status into job_status from fp.document_analysis_jobs j
    where j.document_id=d.id and j.household_id=e.household_id
    order by j.created_at desc,j.id desc limit 1;
  question:=lower(e.action_parameters->>'query');

  if question ~ '(have you|did you|finished|scann?ed|read(?:ing)?|process(?:ed|ing)?)'
     and question !~ '(how much|amount|total|value|cost|due)' then
    answer:=case job_status
      when 'queued' then 'This document is queued for reading. I cannot confirm its details yet.'
      when 'processing' then 'I am reading this document now. I will show the result when it finishes.'
      when 'retry_wait' then 'Reading is delayed and will be retried. I cannot confirm its details yet.'
      when 'succeeded' then case when nullif(trim(d.extracted_text),'') is null
        then 'Reading finished, but I could not extract readable text from this document.'
        else 'Yes, I finished reading this document. Ask me about a specific detail, or open the original.' end
      when 'failed' then 'Reading failed. You can retry reading or open the original.'
      when 'permanent_failed' then 'Reading failed. You can open the original or save it without reading.'
      else case when nullif(trim(d.extracted_text),'') is null
        then 'I have not read this document yet. You can ask me to read it.'
        else 'This document has readable text available. Ask me about a specific detail.' end end;
  elsif question ~ '(how much|amount|total|value|cost|price)' then
    select left(trim(line),200) into evidence
      from regexp_split_to_table(coalesce(d.extracted_text,''),E'\n') line
      where line ~* '(grand total|invoice total|invoice value|invoice amount|amount due|amount payable|balance due|total payable|total)' and line ~ '[0-9]'
      limit 1;
    answer:=case when evidence is not null
      then 'I found this total in the document: '||evidence||E'\nCheck the original before making a payment.'
      when job_status in ('queued','processing','retry_wait')
      then 'I cannot confirm the invoice total yet because reading has not finished.'
      when job_status in ('failed','permanent_failed')
      then 'Reading failed, so I cannot confirm the invoice total. You can retry or open the original.'
      when nullif(trim(d.extracted_text),'') is null
      then 'I do not have readable text for this invoice yet. Ask me to read it, or open the original.'
      else 'I read the document, but could not verify an invoice total in its text. Open the original to check.' end;
  elsif question ~ '(when|due|date|expiry|expires)' then
    select left(trim(line),200) into evidence
      from regexp_split_to_table(coalesce(d.extracted_text,''),E'\n') line
      where line ~* '(due|payment date|expiry|expires)' and line ~ '[0-9]'
      limit 1;
    answer:=case when evidence is not null
      then 'I found this date in the document: '||evidence||E'\nCheck the original before relying on it.'
      when job_status in ('queued','processing','retry_wait') then 'Reading has not finished, so I cannot confirm a date yet.'
      else 'I could not verify that date from the document. You can open the original to check.' end;
  else
    answer:='This is '||left(d.title,120)||coalesce(' in '||category_name,'')||'. '||
      case when job_status='succeeded' and nullif(trim(d.extracted_text),'') is not null
        then 'I have read it. You can ask about a specific amount or date.'
        when job_status in ('queued','processing','retry_wait') then 'It is still being read, so I cannot confirm its details yet.'
        when nullif(trim(d.extracted_text),'') is null then 'I do not have readable text for it yet.'
        else 'I can help find a specific detail in it.' end;
  end if;
  result:=jsonb_build_object('message',answer,'document_id',d.id,'title',d.title,
    'category',category_name,'tags',coalesce(d.tags,'[]'::jsonb),
    'reading_status',coalesce(job_status,'not_requested'),'match_type','ocr',
    'references',jsonb_build_array(jsonb_build_object('type','document','id',d.id,'label',left(d.title,120))));
  return result;
end $$;

revoke all on function fp.run_conversation_execution_before_060(uuid),fp.run_conversation_execution(uuid) from public,anon,authenticated;

-- Optional local-AI wording is saved by the trusted gateway only after the
-- grounded read action has succeeded. Replays return the existing answer.
create function fp.refine_conversation_document_answer(execution uuid, wording text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.conversation_executions;
begin
  if current_setting('request.jwt.claim.role',true)<>'service_role' then
    raise exception 'not authorised' using errcode='42501';
  end if;
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.user_id<>fp.current_user_id() or e.household_id<>fp.active_family_id()
     or e.action_type<>'search_family_content' or not e.action_parameters?'document_id'
     or e.status<>'succeeded' then
    raise exception 'not authorised' using errcode='42501';
  end if;
  perform fp.conversation_member(e.conversation_id);
  perform fp.authorized_source_document((e.action_parameters->>'document_id')::uuid);
  if e.result->>'ai_refined'='true' then return fp.conversation_execution_public(e);end if;
  if char_length(trim(wording)) not between 1 and 500 or wording ~ '[[:cntrl:]]' then
    raise exception 'invalid answer' using errcode='22023';
  end if;
  update fp.conversation_executions set result=result||jsonb_build_object('message',trim(wording),'ai_refined',true),
    updated_at=clock_timestamp() where id=e.id returning * into e;
  update fp.conversation_messages set content=trim(wording)
    where conversation_id=e.conversation_id and household_id=e.household_id and user_id=e.user_id
      and client_message_id='outcome-'||e.id and role='assistant' and kind='result';
  return fp.conversation_execution_public(e);
end $$;

revoke all on function fp.refine_conversation_document_answer(uuid,text) from public,anon,authenticated;
grant execute on function fp.refine_conversation_document_answer(uuid,text) to service_role;
commit;
