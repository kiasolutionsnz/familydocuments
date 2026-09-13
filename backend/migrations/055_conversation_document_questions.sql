begin;

-- Extend only the read action. Existing mutation validation remains unchanged.
alter function fp.assert_conversation_action_v1(text,jsonb) rename to assert_conversation_action_before_055;
create function fp.assert_conversation_action_v1(action_type text,parameters jsonb) returns void
language plpgsql immutable set search_path=pg_catalog,fp as $$
begin
  if action_type='search_family_content' and parameters?'document_id' then
    if jsonb_typeof(parameters->'document_id')<>'string' or parameters->>'document_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then
      raise exception 'invalid document reference' using errcode='22023';
    end if;
    perform fp.assert_conversation_action_before_055(action_type,parameters-'document_id');
  else
    perform fp.assert_conversation_action_before_055(action_type,parameters);
  end if;
end $$;

alter function fp.run_conversation_execution(uuid) rename to run_conversation_execution_before_055;
create function fp.run_conversation_execution(execution uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare e fp.conversation_executions; d fp.documents; evidence text; question text; answer text; result jsonb; request_text text; pending text[]:=array[]::text[];
begin
  select * into e from fp.conversation_executions where id=execution for update;
  if e.id is null or e.user_id<>fp.current_user_id() or e.household_id<>fp.active_family_id() then
    raise exception 'not authorised' using errcode='42501';
  end if;
  if e.action_type<>'search_family_content' or not e.action_parameters?'document_id' then
    result:=fp.run_conversation_execution_before_055(execution);
    if e.action_type='request_document_ocr' then
      select lower(left(content,2000)) into request_text from fp.conversation_messages
        where conversation_id=e.conversation_id and user_id=e.user_id and role='user'
        order by created_at desc,id desc limit 1;
      if request_text ~ '(rental|property)' then pending:=array_append(pending,'linking this to a rental property');end if;
      if request_text ~ '(expense|expenses)' then pending:=array_append(pending,'recording an expense');end if;
      if request_text ~ '(remind|reminder)' then pending:=array_append(pending,'creating a reminder');end if;
      if cardinality(pending)>0 then
        result:=result||jsonb_build_object('pending_actions',to_jsonb(pending),'message',
          (result->>'message')||' Reading is the only action queued. Still not completed: '||array_to_string(pending,', ')||'.');
      end if;
    end if;
    return result;
  end if;
  perform fp.conversation_member(e.conversation_id);
  d:=fp.authorized_source_document((e.action_parameters->>'document_id')::uuid);
  question:=lower(e.action_parameters->>'query');
  -- Evidence is returned as a bounded quotation, never interpreted as an action.
  -- Do not guess a subtotal/total or a payment date from general model knowledge.
  if question ~ '(how much|amount|total|cost)' then
    select string_agg(line,E'\n') into evidence from (
      select left(trim(line),200) line from regexp_split_to_table(coalesce(d.extracted_text,''),E'\n') line
      where line ~* '(total|amount due|balance due)' and line ~ '[0-9]' limit 4
    ) lines;
  elsif question ~ '(when|due|date)' then
    select string_agg(line,E'\n') into evidence from (
      select left(trim(line),200) line from regexp_split_to_table(coalesce(d.extracted_text,''),E'\n') line
      where line ~* '(due|payment date|expiry|expires)' and line ~ '[0-9]' limit 4
    ) lines;
  end if;
  answer:=case when evidence is not null then 'The document contains these matching lines. Check the original before making a payment:'||E'\n'||evidence
    when coalesce(d.extracted_text,'')='' then 'I do not have readable text for this document yet. Open it or ask me to read it.'
    else 'I could not find a reliable answer in this document. You can open the original to check.' end;
  return jsonb_build_object('message',answer,'document_id',d.id,'title',d.title,'match_type','ocr',
    'references',jsonb_build_array(jsonb_build_object('type','document','id',d.id,'label',left(d.title,120))));
end $$;

revoke all on function fp.run_conversation_execution_before_055(uuid),fp.run_conversation_execution(uuid) from public,anon,authenticated;
revoke all on function fp.assert_conversation_action_before_055(text,jsonb),fp.assert_conversation_action_v1(text,jsonb) from public,anon;
commit;
