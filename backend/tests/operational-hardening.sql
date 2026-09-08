begin;
-- A future Auckland due day must remain future when the test runs after
-- 08:00 NZ time but before UTC midnight. Match the production schedule's zone.
set local time zone 'Pacific/Auckland';
do $$
declare owner_id uuid:='41000000-0000-0000-0000-000000000001'; viewer_id uuid:='41000000-0000-0000-0000-000000000002'; hid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); d1 uuid:=gen_random_uuid(); d2 uuid:=gen_random_uuid(); invitation_id uuid; reminder_id uuid; result jsonb;
begin
 insert into fp.households(id,name,owner_user_id) values(hid,'Operational test',owner_id);
 insert into fp.members(household_id,user_id,email,display_name,role) values(hid,owner_id,'ops-owner@example.test','Ops owner','owner'),(hid,viewer_id,'ops-viewer@example.test','Ops viewer','viewer');
 insert into fp.categories(id,household_id,name,created_by) values(cid,hid,'Test',owner_id);
 insert into fp.documents(id,household_id,category_id,title,created_by,tags,lifecycle_status) values(d1,hid,cid,'Primary',owner_id,'["old"]','active'),(d2,hid,cid,'Duplicate',owner_id,'[]','active');
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','ops-owner@example.test','aal','aal2')::text,true);
 result:=fp.invite_member('invitee@example.test','viewer'); invitation_id:=(result->>'id')::uuid;
 if not exists(select 1 from fp.notification_outbox where dedupe_key='invitation:'||invitation_id) then raise exception 'invitation not queued'; end if;
 perform fp.set_document_access(d1,viewer_id,'view');
 result:=fp.edit_document_metadata(d1,'Edited primary',cid,'["policy","home"]','2026-08-22','Provider'); if result->>'updated'<>'true' then raise exception 'metadata not edited'; end if;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','ops-viewer@example.test','aal','aal1')::text,true);
 result:=fp.explain_document_access(d1,null); if result->>'allowed'<>'true' or not (result->'reasons' @> '[{"type":"direct_share"}]') then raise exception 'direct access not explained'; end if;
 begin perform fp.edit_document_metadata(d1,'Viewer edit',cid,'[]',null,null); raise exception 'viewer edited metadata'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','ops-owner@example.test','aal','aal2')::text,true);
 result:=fp.merge_documents(d1,d2); if result->>'status'<>'archived_with_provenance' or not exists(select 1 from fp.documents where id=d2 and lifecycle_status='archived' and merged_into=d1) then raise exception 'merge failed'; end if;
 result:=fp.household_export(); if result->>'schema_version'<>'1' or (result::text like '%extracted_text%') then raise exception 'unsafe export'; end if;
 insert into fp.reminders(id,household_id,document_id,title,due_at,created_by) values(gen_random_uuid(),hid,d1,'Test renewal',current_date+1,owner_id) returning id into reminder_id;
 result:=fp.enqueue_due_notifications(); if not exists(select 1 from fp.notification_outbox where dedupe_key='reminder_due_day:'||reminder_id||':'||(current_date+1)::text||':'||owner_id and available_at=((current_date+1)+time '08:00') at time zone 'Pacific/Auckland') then raise exception 'reminder not queued for 8am Auckland on its due date'; end if;
 result:=fp.claim_notification_batch(50);
 if exists(select 1 from fp.notification_outbox where dedupe_key='reminder_due_day:'||reminder_id||':'||(current_date+1)::text||':'||owner_id and status<>'pending') then raise exception 'future reminder claimed before delivery time'; end if;
 if not exists(select 1 from jsonb_array_elements(result) notification where notification->>'kind'='invitation') then raise exception 'due invitation not claimed'; end if;
end $$;
rollback;
