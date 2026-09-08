begin;
do $$
declare owner_id uuid:=gen_random_uuid();viewer_id uuid:=gen_random_uuid();hid uuid:=gen_random_uuid();cid uuid:=gen_random_uuid();doc uuid:=gen_random_uuid();source_id uuid;result jsonb;sha text:=repeat('a',64);
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic Drive household',owner_id);
  insert into fp.members(household_id,user_id,email,role) values(hid,owner_id,'drive-owner@example.test','owner'),(hid,viewer_id,'drive-viewer@example.test','viewer');
  insert into fp.categories(id,household_id,name,created_by) values(cid,hid,'Drive records',owner_id);
  insert into fp.documents(id,household_id,category_id,title,created_by,source_name,source_sha256,mime_type) values(doc,hid,cid,'Synthetic selected Drive file',owner_id,'synthetic-drive.pdf',sha,'application/pdf');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','drive-owner@example.test','aal','aal1')::text,true);
  result:=fp.register_google_drive_source('synthetic-file-id-12345','synthetic-drive.pdf','application/pdf',1024,'2026-08-22T01:00:00Z','7',repeat('b',32),sha,'https://drive.google.com/file/d/synthetic-file-id-12345/view');source_id:=(result->>'id')::uuid;
  perform fp.link_google_drive_source(doc,source_id);
  result:=fp.document_source(doc);if result->>'provider'<>'google_drive' or result->>'provider_file_id'<>'synthetic-file-id-12345' or result?'content_base64' then raise exception 'Drive source disclosure contract failed';end if;
  result:=fp.update_google_drive_source(source_id,'synthetic-drive.pdf','application/pdf',1024,'2026-08-22T01:00:00Z','7',repeat('b',32),'["folder-a"]'::jsonb,'active');if result->>'status'<>'active' then raise exception 'initial parent baseline failed';end if;
  result:=fp.update_google_drive_source(source_id,'renamed-drive.pdf','application/pdf',1024,'2026-08-22T01:00:00Z','7',repeat('b',32),'["folder-b"]'::jsonb,'active');if result->>'status'<>'moved' then raise exception 'move or rename not detected';end if;
  if jsonb_array_length(fp.google_drive_source_summaries())<>1 then raise exception 'owner summary missing';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','drive-viewer@example.test','aal','aal1')::text,true);if jsonb_array_length(fp.google_drive_source_summaries())<>0 then raise exception 'private Drive source leaked';end if;
  begin perform fp.update_google_drive_source(source_id,'synthetic-drive.pdf','application/pdf',1024,'2026-08-22T02:00:00Z','8',repeat('c',32),'["folder-b"]'::jsonb,'active');raise exception 'viewer updated hidden source';exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','drive-owner@example.test','aal','aal1')::text,true);result:=fp.update_google_drive_source(source_id,'synthetic-drive.pdf','application/pdf',1024,'2026-08-22T02:00:00Z','8',repeat('c',32),'["folder-b"]'::jsonb,'active');if result->>'status'<>'changed' then raise exception 'version change not detected';end if;
  result:=fp.update_google_drive_source(source_id,'Unavailable Drive file','application/pdf',1,'1970-01-01T00:00:00Z','unknown',null,'[]'::jsonb,'missing');if result->>'status'<>'missing' then raise exception 'deleted file not detected';end if;
  result:=fp.update_google_drive_source(source_id,'Unavailable Drive file','application/pdf',1,'1970-01-01T00:00:00Z','unknown',null,'[]'::jsonb,'inaccessible');if result->>'status'<>'inaccessible' then raise exception 'inaccessible file not detected';end if;
  begin perform fp.disconnect_google_drive();raise exception 'AAL1 disconnected Drive';exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','drive-owner@example.test','aal','aal2')::text,true);perform fp.disconnect_google_drive();if not exists(select 1 from fp.external_sources where id=source_id and status='disconnected') then raise exception 'disconnect failed';end if;
end $$;
rollback;
