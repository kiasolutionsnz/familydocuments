begin;
do $$
declare owner_id uuid:=gen_random_uuid();viewer_id uuid:=gen_random_uuid();family uuid:=gen_random_uuid();other_family uuid:=gen_random_uuid();
  conversation_id uuid;attachment_id uuid;reservation jsonb;staged jsonb;outcome jsonb;v_document_id uuid;job_id uuid;claim jsonb;
  sha text:=repeat('a',64);service_claims text:='{"role":"service_role"}';
begin
  insert into fp.households(id,name,owner_user_id) values(family,'Synthetic Drive originals',owner_id),(other_family,'Synthetic other Family',owner_id);
  insert into fp.members(household_id,user_id,email,role) values(family,owner_id,'drive-owner@example.test','owner'),
    (family,viewer_id,'drive-viewer@example.test','viewer'),(other_family,owner_id,'drive-owner@example.test','owner');
  insert into fp.categories(household_id,name,created_by) values(family,'Finance',owner_id),(family,'Documents',owner_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal1')::text,true);
  perform fp.select_active_family(family);
  conversation_id:=(fp.start_conversation('synthetic-drive-conversation-001')->>'id')::uuid;
  perform set_config('request.jwt.claims',service_claims,true);
  begin
    perform fp.reserve_conversation_drive_upload(conversation_id,owner_id,family,'synthetic-file-id-12345','synthetic-bill.pdf','application/pdf',123,sha);
    raise exception 'Drive-free upload was permitted';
  exception when no_data_found then null;end;
  insert into fp.google_drive_credentials(household_id,encrypted_refresh_token,token_nonce,scopes,connected_by)
    values(family,repeat('x',48),repeat('x',16),'https://www.googleapis.com/auth/drive.file',owner_id);
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,status,configured_by)
    values(family,'google_drive','synthetic-folder-12345','Family files','active',owner_id);
  begin
    perform fp.reserve_conversation_drive_upload(conversation_id,viewer_id,family,'synthetic-other-file','synthetic-bill.pdf','application/pdf',123,sha);
    raise exception 'read-only member reserved an original';
  exception when insufficient_privilege then null;end;
  begin
    perform fp.reserve_conversation_drive_upload(conversation_id,owner_id,other_family,'synthetic-other-file','synthetic-bill.pdf','application/pdf',123,sha);
    raise exception 'cross-Family original reserved';
  exception when insufficient_privilege then null;end;
  reservation:=fp.reserve_conversation_drive_upload(conversation_id,owner_id,family,'synthetic-file-id-12345','synthetic-bill.pdf','application/pdf',123,sha);
  if reservation->>'status'<>'reserved' then raise exception 'reservation missing';end if;
  if fp.reserve_conversation_drive_upload(conversation_id,owner_id,family,'synthetic-ignored-id-1234','synthetic-bill.pdf','application/pdf',123,sha)->>'file_id' <> reservation->>'file_id' then
    raise exception 'lost response reserved another Drive ID';end if;
  staged:=fp.finish_conversation_drive_upload((reservation->>'id')::uuid,owner_id,family,conversation_id,'synthetic-file-id-12345',
    '2026-09-14T00:00:00Z','7',repeat('b',32));attachment_id:=(staged->>'id')::uuid;
  if staged->>'id' is null or exists(select 1 from fp.conversation_attachments where id=attachment_id and content is not null) then
    raise exception 'original bytes persisted in conversation';end if;
  if fp.finish_conversation_drive_upload((reservation->>'id')::uuid,owner_id,family,conversation_id,'synthetic-file-id-12345',
    '2026-09-14T00:00:00Z','7',repeat('b',32))->>'id' <> staged->>'id' then raise exception 'finish replay duplicated attachment';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal1')::text,true);
  outcome:=fp.submit_conversation_action(conversation_id,'synthetic-save-action-001','save_document',1,
    jsonb_build_object('attachment_id',attachment_id,'category_name','Finance','tags',jsonb_build_array('invoice')),'synthetic-save-request-001',false);
  if outcome->>'state'<>'succeeded' then raise exception 'Drive save failed: %',outcome;end if;
  v_document_id:=(outcome->'result'->>'document_id')::uuid;
  if v_document_id is null or not exists(select 1 from fp.documents d where d.id=v_document_id and d.storage_provider='google_drive') or
    exists(select 1 from fp.manual_document_sources s where s.document_id=v_document_id) then raise exception 'saved a local original';end if;
  if fp.document_source(v_document_id)->>'provider'<>'google_drive' then raise exception 'original cannot be reopened';end if;
  if fp.submit_conversation_action(conversation_id,'synthetic-save-action-001','save_document',1,
    jsonb_build_object('attachment_id',attachment_id,'category_name','Finance','tags',jsonb_build_array('invoice')),'synthetic-save-request-001',false)->>'state'<>'succeeded' then
    raise exception 'lost-response replay failed';end if;
  if (select count(*) from fp.document_external_sources x where x.document_id=v_document_id)<>1 then raise exception 'duplicate original';end if;
  outcome:=fp.submit_conversation_action(conversation_id,'synthetic-ocr-action-001','request_document_ocr',1,
    jsonb_build_object('document_id',v_document_id,'mode','invoice'),'synthetic-ocr-request-001',false);
  if outcome->>'state'<>'succeeded' then raise exception 'Drive OCR enqueue failed: %',outcome;end if;
  job_id:=(outcome->'result'->>'job_id')::uuid;
  perform set_config('request.jwt.claims',service_claims,true);
  claim:=fp.claim_document_analysis_jobs(1);
  if claim->0->>'job_id'<>job_id::text or claim->0->>'source_kind'<>'google_drive' or claim->0->>'content_base64' is not null then
    raise exception 'worker claim leaked or missed Drive original';end if;
  if fp.authorize_drive_analysis_source(job_id,(claim->0->>'lease_token')::uuid)->>'file_id'<>'synthetic-file-id-12345' then
    raise exception 'leased worker could not fetch Drive source';end if;
  begin perform fp.authorize_drive_analysis_source(job_id,gen_random_uuid());raise exception 'wrong lease read Drive source';exception when insufficient_privilege then null;end;
  update fp.members set role='viewer' where user_id=owner_id and household_id=family;
  begin perform fp.authorize_drive_analysis_source(job_id,(claim->0->>'lease_token')::uuid);raise exception 'read-only requester read Drive source';exception when insufficient_privilege then null;end;
  update fp.members set status='suspended' where user_id=owner_id and household_id=family;
  begin perform fp.authorize_drive_analysis_source(job_id,(claim->0->>'lease_token')::uuid);raise exception 'revoked requester read Drive source';exception when insufficient_privilege then null;end;
end $$;
rollback;
