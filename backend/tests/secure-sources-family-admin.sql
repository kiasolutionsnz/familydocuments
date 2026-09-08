begin;
do $$
declare owner_id uuid:=gen_random_uuid(); viewer_id uuid:=gen_random_uuid(); next_owner uuid:=gen_random_uuid(); hid uuid:=gen_random_uuid(); cid uuid:=gen_random_uuid(); eid uuid:=gen_random_uuid(); aid uuid:=gen_random_uuid(); doc uuid:=gen_random_uuid(); iid uuid:=gen_random_uuid(); alias_id uuid:=gen_random_uuid(); result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic secure workflow',owner_id);
  insert into fp.members(household_id,user_id,email,role) values(hid,owner_id,'secure-owner@example.test','owner'),(hid,viewer_id,'secure-viewer@example.test','viewer'),(hid,next_owner,'secure-next@example.test','adult_member');
  insert into fp.categories(id,household_id,name,created_by) values(cid,hid,'Secure source',owner_id);
  insert into fp.household_inbox_aliases(id,household_id,local_part,created_by) values(alias_id,hid,'family-'||encode(extensions.gen_random_bytes(12),'hex'),owner_id);
  insert into fp.inbound_emails(id,household_id,inbox_alias_id,source_system,external_message_id,sender_address,recipient_addresses,subject,raw_email,raw_sha256,raw_size_bytes,body_text,attachment_count,attachment_status)
    values(eid,hid,alias_id,'mailpit_local','secure-source-test','sender@example.test','[]','Secure source',convert_to('Synthetic email','UTF8'),encode(extensions.digest(convert_to('Synthetic email','UTF8'),'sha256'),'hex'),15,'Synthetic email',1,'quarantined_unscanned');
  insert into fp.inbound_attachments(id,inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,content,content_sha256,scan_status)
    values(aid,eid,hid,'part-1','synthetic.pdf','application/pdf',9,encode(extensions.digest(convert_to('PDF bytes','UTF8'),'sha256'),'hex'),convert_to('PDF bytes','UTF8'),encode(extensions.digest(convert_to('PDF bytes','UTF8'),'sha256'),'hex'),'clean');
  insert into fp.documents(id,household_id,category_id,title,created_by,source_name,source_attachment_id,inbound_email_id,lifecycle_status) values(doc,hid,cid,'Synthetic source record',owner_id,'synthetic.pdf',aid,eid,'active');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','secure-owner@example.test','aal','aal1')::text,true);
  result:=fp.document_source(doc); if result->>'content_base64'<>encode(convert_to('PDF bytes','UTF8'),'base64') then raise exception 'source bytes changed'; end if;
  begin perform fp.manage_member(viewer_id,'suspend',null); raise exception 'aal1 administered member'; exception when insufficient_privilege then null; end;
  update fp.documents set lifecycle_status='deleted' where id=doc;
  begin perform fp.purge_document(doc,'PURGE'); raise exception 'aal1 purged source'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','secure-owner@example.test','aal','aal2')::text,true);
  perform fp.manage_member(viewer_id,'suspend',null); if not exists(select 1 from fp.members where household_id=hid and user_id=viewer_id and status='suspended') then raise exception 'suspension failed'; end if;
  perform fp.manage_member(viewer_id,'activate',null); perform fp.manage_member(viewer_id,'role','contributor');
  perform fp.purge_document(doc,'PURGE'); if exists(select 1 from fp.documents where id=doc) or exists(select 1 from fp.inbound_attachments where id=aid) or exists(select 1 from fp.inbound_emails where id=eid) then raise exception 'purge left unreferenced source data'; end if;
  perform fp.transfer_household_ownership(next_owner); if not exists(select 1 from fp.members where household_id=hid and user_id=next_owner and role='owner') then raise exception 'ownership transfer failed'; end if;
  if (select count(*) from fp.security_audit_events where household_id=hid)<6 then raise exception 'security audit incomplete'; end if;
end $$;
rollback;
