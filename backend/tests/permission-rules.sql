begin;
do $$
declare
  owner_id uuid:=gen_random_uuid(); viewer_id uuid:=gen_random_uuid(); hid uuid:=gen_random_uuid(); category_id uuid:=gen_random_uuid(); entity_id uuid:=gen_random_uuid(); doc_id uuid:=gen_random_uuid();
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic permission test',owner_id);
  insert into fp.members(household_id,user_id,email,role) values(hid,owner_id,'permission-owner@example.test','owner'),(hid,viewer_id,'permission-viewer@example.test','viewer');
  insert into fp.categories(id,household_id,name,created_by) values(category_id,hid,'Private records',owner_id);
  insert into fp.entities(id,household_id,entity_type,name,created_by) values(entity_id,hid,'person','Synthetic child',owner_id);
  insert into fp.documents(id,household_id,category_id,title,created_by) values(doc_id,hid,category_id,'Synthetic private passport',owner_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','permission-owner@example.test')::text,true);
  perform fp.set_access_rule('category',category_id,viewer_id,'view');
  if exists(select 1 from fp.document_permissions where document_id=doc_id and member_user_id=viewer_id) then raise exception 'private record inherited a rule'; end if;
  perform fp.set_document_privacy(doc_id,'shared_by_rules');
  if not exists(select 1 from fp.document_permissions where document_id=doc_id and member_user_id=viewer_id and grant_source='rule' and access_level='view') then raise exception 'sharing rule did not apply'; end if;
  perform fp.set_document_access(doc_id,viewer_id,'manage');
  perform fp.set_access_rule('category',category_id,viewer_id,'none');
  if not exists(select 1 from fp.document_permissions where document_id=doc_id and member_user_id=viewer_id and grant_source='manual' and access_level='manage') then raise exception 'rule removal erased an explicit share'; end if;
  perform fp.set_document_access(doc_id,viewer_id,'none');
  if exists(select 1 from fp.document_permissions where document_id=doc_id and member_user_id=viewer_id) then raise exception 'manual revocation failed'; end if;
  perform fp.set_access_rule('entity',entity_id,viewer_id,'view');
  insert into fp.document_entities(document_id,entity_id,linked_by) values(doc_id,entity_id,owner_id);
  if not exists(select 1 from fp.document_permissions where document_id=doc_id and member_user_id=viewer_id and grant_source='rule') then raise exception 'entity rule did not apply after linking'; end if;
  if (select count(*) from fp.permission_audit_events where household_id=hid)<5 then raise exception 'permission audit is incomplete'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','permission-viewer@example.test')::text,true);
  begin perform fp.set_access_rule('category',category_id,viewer_id,'view'); raise exception 'viewer changed an access rule'; exception when insufficient_privilege then null; end;
  begin perform fp.set_document_privacy(doc_id,'private'); raise exception 'viewer changed document privacy'; exception when insufficient_privilege then null; end;
end $$;
rollback;
