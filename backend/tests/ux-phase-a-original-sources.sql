-- Run only in a disposable migrated database. All fixtures are synthetic and
-- rolled back; the Drive tests use database metadata, never a provider account.
begin;

create function pg_temp.ux_raises(statement text,expected_state text) returns void
language plpgsql as $$
declare actual_state text;
begin
  begin execute statement; exception when others then get stacked diagnostics actual_state=returned_sqlstate;end;
  if actual_state is distinct from expected_state then
    raise exception 'expected SQLSTATE %, got % for %',expected_state,coalesce(actual_state,'success'),statement;
  end if;
end $$;

create function pg_temp.ux_fail_reminder() returns trigger language plpgsql as $$
begin
  if new.title='Synthetic atomic failure — check or renew' then
    raise exception 'synthetic reminder write failure' using errcode='22000';
  end if;
  return new;
end $$;
create trigger ux_synthetic_reminder_failure before insert on fp.reminders
for each row execute function pg_temp.ux_fail_reminder();

do $$
declare
  owner_a uuid:='10000000-0000-0000-0000-000000000001';
  owner_b uuid:='20000000-0000-0000-0000-000000000002';
  household_a uuid:=gen_random_uuid();
  household_b uuid:=gen_random_uuid();
  category_a uuid:=gen_random_uuid();
  category_b uuid:=gen_random_uuid();
  viewer_a uuid:=gen_random_uuid();
  draft_id uuid;
  rejected_draft uuid;
  expired_draft uuid;
  manual_document_id uuid;
  atomic_draft uuid;
  drive_source_id uuid;
  foreign_drive_source_id uuid;
  saved_document_id uuid;
  source_bytes bytea:=decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aKuoAAAAASUVORK5CYII=','base64');
  extraction text:='Synthetic car policy. Provider: Example Insurance.';
  precision_confidence numeric:=0.987654321;
  result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(household_a,'Synthetic UX A',owner_a),(household_b,'Synthetic UX B',owner_b);
  insert into fp.members(household_id,user_id,email,role) values
    (household_a,owner_a,'ux-owner-a@example.test','owner'),(household_b,owner_b,'ux-owner-b@example.test','owner'),
    (household_a,viewer_a,'ux-viewer-a@example.test','viewer');
  insert into fp.categories(id,household_id,name,is_system,created_by) values
    (category_a,household_a,'Insurance',true,owner_a),(category_b,household_b,'Insurance',true,owner_b);

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_a,'email','ux-owner-a@example.test','role','authenticated')::text,true);
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(NULL,%L,%L,%L)','image/png',encode(source_bytes,'base64'),category_a),'22023');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,NULL,%L,%L)','test.png',encode(source_bytes,'base64'),category_a),'22023');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,%L,NULL,%L)','test.png','image/png',category_a),'22023');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,%L,%L,%L)','test.png','image/png',encode(source_bytes,'base64'),category_b),'22023');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,%L,%L,%L)','test.png','image/png','aW52YWxpZA==',category_a),'22023');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,%L,repeat(''A'',7340033),%L)','test.png','image/png',category_a),'22023');
  perform pg_temp.ux_raises('select fp.validate_document_bytes(''image/png'',NULL)','22023');
  perform pg_temp.ux_raises('select fp.validate_document_bytes(''image/png'',decode(repeat(''00'',5242881),''hex''))','22023');
  result:=fp.create_ocr_intake_draft('synthetic-policy.png','image/png',encode(source_bytes,'base64'),category_a);
  draft_id:=(result->>'draft_id')::uuid;
  if result->>'status'<>'processing' or not exists(select 1 from fp.ocr_intake_drafts where id=draft_id and content=source_bytes) then raise exception 'draft was not saved before OCR';end if;
  if exists(select 1 from fp.documents where household_id=household_a) then raise exception 'unreviewed intake created document';end if;
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,NULL,0.9)',draft_id),'22023');
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,NULL)',draft_id,extraction),'22023');
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,2)',draft_id,extraction),'22023');
  perform fp.record_ocr_intake_result(draft_id,extraction,precision_confidence);
  perform fp.record_ocr_intake_result(draft_id,extraction,precision_confidence);
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,0.2)',draft_id,'different text'),'22023');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,NULL,%L,%L,%L,NULL,NULL,%s)',draft_id,category_a,extraction,'Policy',precision_confidence),'22023');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,NULL,%L,NULL,NULL,%s)',draft_id,'Policy',category_a,'Policy',precision_confidence),'22023');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,NULL)',draft_id,'Policy',category_a,extraction,'Policy'),'22023');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,%s)',draft_id,'Policy',category_b,extraction,'Policy',precision_confidence),'22023');
  if exists(select 1 from fp.documents where household_id=household_a) then raise exception 'invalid confirmation partially saved';end if;
  update fp.members set role='viewer' where household_id=household_a and user_id=owner_a;
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,%s)',draft_id,extraction,precision_confidence),'42501');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,%s)',draft_id,'Policy',category_a,extraction,'Policy',precision_confidence),'42501');
  update fp.members set role='owner' where household_id=household_a and user_id=owner_a;
  result:=fp.confirm_ocr_intake(draft_id,'Synthetic car policy',category_a,extraction,'Insurance policy','Example Insurance','2027-09-30',precision_confidence);
  saved_document_id:=(result->>'document_id')::uuid;
  if not exists(select 1 from fp.manual_document_sources where document_id=saved_document_id and content=source_bytes and sha256=encode(extensions.digest(source_bytes,'sha256'),'hex')) then raise exception 'permanent original missing';end if;
  perform pg_temp.ux_raises(format('update fp.manual_document_sources set household_id=%L where document_id=%L',household_b,saved_document_id),'42501');
  if not exists(select 1 from fp.ocr_intake_drafts where id=draft_id and status='confirmed' and octet_length(content)=0) then raise exception 'confirmed staging bytes not cleared';end if;
  if not exists(select 1 from fp.documents d join fp.manual_document_sources m on m.document_id=d.id where d.id=saved_document_id and d.storage_key='manual/'||m.id::text and d.file_size=octet_length(source_bytes) and d.ocr_confidence=round(precision_confidence,4)) then raise exception 'permanent metadata incorrect';end if;
  result:=fp.document_source(saved_document_id);
  if result->>'file_name'<>'synthetic-policy.png' or decode(result->>'content_base64','base64')<>source_bytes then raise exception 'authorised source did not open';end if;
  result:=fp.confirm_ocr_intake(draft_id,'Synthetic car policy',category_a,extraction,'Insurance policy','Example Insurance','2027-09-30',precision_confidence);
  if coalesce((result->>'duplicate')::boolean,false)<>true then raise exception 'confirmation was not idempotent';end if;
  if (select count(*) from fp.documents where household_id=household_a)<>1 or (select count(*) from fp.reminders where document_id=saved_document_id)<>1 or (select count(*) from fp.security_audit_events where document_id=saved_document_id and event_type='ocr_intake_confirmed')<>1 then raise exception 'confirmation duplicated effects';end if;
  perform pg_temp.ux_raises(format('select fp.reject_ocr_intake(%L)',draft_id),'PT404');
  result:=fp.create_manual_document('Manual synthetic image',category_a,'manual.png','image/png',encode(source_bytes,'base64'));
  manual_document_id:=(result->>'document_id')::uuid;
  if decode(fp.document_source(manual_document_id)->>'content_base64','base64')<>source_bytes then raise exception 'manual original did not open';end if;
  result:=fp.create_ocr_intake_draft('atomic.png','image/png',encode(source_bytes,'base64'),category_a);atomic_draft:=(result->>'draft_id')::uuid;
  perform fp.record_ocr_intake_result(atomic_draft,extraction,0.9);
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,%L,0.9)',atomic_draft,'Synthetic atomic failure',category_a,extraction,'Policy','2027-09-30'),'22000');
  if exists(select 1 from fp.documents where household_id=household_a and title='Synthetic atomic failure') or not exists(select 1 from fp.ocr_intake_drafts where id=atomic_draft and status='review_required' and content=source_bytes) then raise exception 'reminder failure did not roll back document/source transfer';end if;
  perform fp.reject_ocr_intake(atomic_draft);

  update fp.documents set lifecycle_status='archived' where id=saved_document_id;
  perform fp.document_source(saved_document_id);
  update fp.documents set lifecycle_status='active' where id=saved_document_id;
  update fp.members set status='suspended' where household_id=household_a and user_id=owner_a;
  perform pg_temp.ux_raises(format('select fp.document_source(%L)',saved_document_id),'PT404');
  perform pg_temp.ux_raises(format('select fp.authorize_google_drive_document(%L)',saved_document_id),'PT404');
  update fp.members set status='active' where household_id=household_a and user_id=owner_a;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_a,'role','authenticated')::text,true);
  perform pg_temp.ux_raises(format('select fp.document_source(%L)',saved_document_id),'PT404');
  perform pg_temp.ux_raises(format('select fp.create_ocr_intake_draft(%L,%L,%L,%L)','test.png','image/png',encode(source_bytes,'base64'),category_a),'42501');
  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by) values(saved_document_id,viewer_a,'view',owner_a);
  perform fp.document_source(saved_document_id);
  update fp.members set status='suspended' where household_id=household_a and user_id=viewer_a;
  perform pg_temp.ux_raises(format('select fp.document_source(%L)',saved_document_id),'PT404');

  -- A stale permission row must not authorise another household.
  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by) values(saved_document_id,owner_b,'view',owner_a);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_b,'email','ux-owner-b@example.test','role','authenticated')::text,true);
  begin perform fp.document_source(saved_document_id);raise exception 'cross-household source opened';exception when no_data_found then null;when sqlstate 'PT404' then null;end;
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,0.5)',draft_id,'tamper'),'42501');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,0.5)',draft_id,'Policy',category_a,extraction,'Policy'),'42501');
  perform pg_temp.ux_raises(format('select fp.reject_ocr_intake(%L)',draft_id),'42501');
  perform pg_temp.ux_raises(format('select fp.reject_ocr_intake(%L)',gen_random_uuid()),'42501');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_a,'email','ux-owner-a@example.test','role','authenticated')::text,true);
  result:=fp.create_ocr_intake_draft('reject.png','image/png',encode(source_bytes,'base64'),category_a);rejected_draft:=(result->>'draft_id')::uuid;
  perform fp.reject_ocr_intake(rejected_draft);perform fp.reject_ocr_intake(rejected_draft);
  if not exists(select 1 from fp.ocr_intake_drafts where id=rejected_draft and status='rejected' and octet_length(content)=0 and extracted_text is null) then raise exception 'rejection retained private payload';end if;
  result:=fp.create_ocr_intake_draft('expire.png','image/png',encode(source_bytes,'base64'),category_a);expired_draft:=(result->>'draft_id')::uuid;
  perform fp.record_ocr_intake_result(expired_draft,extraction,0.9);
  update fp.ocr_intake_drafts set expires_at=now()-interval '1 minute' where id=expired_draft;
  perform pg_temp.ux_raises(format('select fp.record_ocr_intake_result(%L,%L,0.9)',expired_draft,extraction),'PT404');
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,0.9)',expired_draft,'Expired',category_a,extraction,'Policy'),'PT404');
  perform pg_temp.ux_raises('select fp.expire_ocr_intake_drafts()','42501');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);perform fp.expire_ocr_intake_drafts();
  if not exists(select 1 from fp.ocr_intake_drafts where id=expired_draft and status='failed' and octet_length(content)=0 and extracted_text is null) then raise exception 'expired payload not cleared';end if;
  if not exists(select 1 from fp.manual_document_sources where document_id=saved_document_id and content=source_bytes) then raise exception 'retention deleted confirmed original';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_a,'role','authenticated')::text,true);
  insert into fp.storage_connections(household_id,provider,provider_folder_id,folder_name,configured_by)
  values(household_a,'google_drive','synthetic-folder-only','Synthetic folder',owner_a);
  insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,content_sha256,added_by)
  values(household_a,'google_drive','synthetic-file-only','manual.png','image/png',octet_length(source_bytes),now(),'1',encode(extensions.digest(source_bytes,'sha256'),'hex'),owner_a) returning id into drive_source_id;
  insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(manual_document_id,drive_source_id,owner_a);
  insert into fp.external_sources(household_id,provider,provider_file_id,file_name,mime_type,size_bytes,modified_time,provider_version,content_sha256,added_by)
  values(household_b,'google_drive','synthetic-foreign-file','foreign.png','image/png',octet_length(source_bytes),now(),'1',encode(extensions.digest(source_bytes,'sha256'),'hex'),owner_b) returning id into foreign_drive_source_id;
  perform pg_temp.ux_raises(format('insert into fp.document_external_sources(document_id,external_source_id,linked_by) values(%L,%L,%L)',saved_document_id,foreign_drive_source_id,owner_a),'42501');
  result:=fp.authorize_google_drive_document(manual_document_id);
  if result->>'file_id'<>'synthetic-file-only' then raise exception 'Drive source lookup wrong';end if;
  update fp.members set status='suspended' where household_id=household_a and user_id=owner_a;
  perform pg_temp.ux_raises(format('select fp.authorize_google_drive_document(%L)',manual_document_id),'PT404');
  update fp.members set status='active' where household_id=household_a and user_id=owner_a;
  update fp.external_sources set status='missing' where id=drive_source_id;
  perform pg_temp.ux_raises(format('select fp.document_source(%L)',manual_document_id),'PT404');
  perform pg_temp.ux_raises(format('select fp.authorize_google_drive_document(%L)',manual_document_id),'PT404');
  delete from fp.manual_document_sources where document_id=saved_document_id;
  if (select source_status from fp.documents where id=saved_document_id)<>'unavailable' then raise exception 'missing source metadata stale';end if;
  begin perform fp.document_source(saved_document_id);raise exception 'missing original opened';exception when no_data_found then null;when sqlstate 'PT404' then null;end;
  update fp.documents set lifecycle_status='deleted' where id=saved_document_id;
  begin perform fp.document_source(saved_document_id);raise exception 'deleted source opened';exception when no_data_found then null;when sqlstate 'PT404' then null;end;
  perform pg_temp.ux_raises(format('select fp.confirm_ocr_intake(%L,%L,%L,%L,%L,NULL,NULL,%s)',draft_id,'Policy',category_a,extraction,'Policy',precision_confidence),'PT404');
  perform set_config('ux.owner',owner_a::text,true);perform set_config('ux.category',category_a::text,true);
end $$;

set local role authenticated;
do $$
declare result jsonb;
begin
  perform set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('ux.owner'),'role','authenticated')::text,true);
  result:=fp.create_ocr_intake_draft('role-test.png','image/png','iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aKuoAAAAASUVORK5CYII=',current_setting('ux.category')::uuid);
  if result->>'draft_id' is null then raise exception 'authenticated RPC grant missing';end if;
  perform fp.reject_ocr_intake((result->>'draft_id')::uuid);
  perform pg_temp.ux_raises('select content from fp.ocr_intake_drafts','42501');
  perform pg_temp.ux_raises('select content from fp.manual_document_sources','42501');
  perform pg_temp.ux_raises('select fp.expire_ocr_intake_drafts()','42501');
  perform pg_temp.ux_raises('select fp.authorized_source_document(gen_random_uuid())','42501');
end $$;
reset role;
set local role anon;
select pg_temp.ux_raises('select fp.create_ocr_intake_draft(NULL,NULL,NULL,NULL)','42501');
reset role;

rollback;
