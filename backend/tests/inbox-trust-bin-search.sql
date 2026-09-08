begin;
do $$
declare owner_id uuid:=gen_random_uuid();hid uuid:=gen_random_uuid();cid uuid:=gen_random_uuid();alias_id uuid:=gen_random_uuid();eid uuid:=gen_random_uuid();aid uuid:=gen_random_uuid();doc uuid:=gen_random_uuid();result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values(hid,'Synthetic inbox trust',owner_id);
  insert into fp.members(household_id,user_id,email,role) values(hid,owner_id,'inbox-owner@example.test','owner');
  insert into fp.categories(id,household_id,name,created_by) values(cid,hid,'Synthetic search',owner_id);
  insert into fp.household_inbox_aliases(id,household_id,local_part,created_by) values(alias_id,hid,'trust-'||encode(extensions.gen_random_bytes(8),'hex'),owner_id);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','inbox-owner@example.test','role','authenticated')::text,true);
  insert into fp.inbound_emails(id,household_id,inbox_alias_id,source_system,external_message_id,sender_address,recipient_addresses,subject,raw_email,raw_sha256,raw_size_bytes,body_text,attachment_count,attachment_status)
  values(eid,hid,alias_id,'mailpit_local','trust-test','new-sender@example.test','[]','Synthetic searchable PDF',convert_to('Synthetic email','UTF8'),encode(extensions.digest(convert_to('Synthetic email','UTF8'),'sha256'),'hex'),15,'Email body',1,'quarantined_unscanned');
  if (select sender_disposition from fp.inbound_emails where id=eid)<>'quarantined' then raise exception 'unknown sender was not quarantined';end if;
  insert into fp.inbound_attachments(id,inbound_email_id,household_id,mailpit_part_id,file_name,claimed_content_type,expected_size_bytes,expected_sha256,quarantined_content,scan_status)
  values(aid,eid,hid,'part-1','searchable.pdf','application/pdf',9,encode(extensions.digest(convert_to('PDF bytes','UTF8'),'sha256'),'hex'),convert_to('PDF bytes','UTF8'),'pending');
  if (select scan_status from fp.inbound_attachments where id=aid)<>'quarantined_sender' then raise exception 'unknown attachment entered scan queue';end if;
  result:=fp.set_inbound_sender_rule('new-sender@example.test','allow');
  if (select sender_disposition from fp.inbound_emails where id=eid)<>'allowed' or (select scan_status from fp.inbound_attachments where id=aid)<>'pending' then raise exception 'trust did not release quarantine';end if;
  update fp.inbound_attachments set scan_status='clean',content=convert_to('PDF bytes','UTF8'),content_sha256=expected_sha256,quarantined_content=null,search_text='The hidden searchable phrase is koru invoice reference.' where id=aid;
  insert into fp.documents(id,household_id,category_id,title,created_by,source_name,source_attachment_id,inbound_email_id,lifecycle_status,confirmation_status) values(doc,hid,cid,'Ordinary title',owner_id,'searchable.pdf',aid,eid,'active','confirmed');
  result:=fp.search_household_records('koru invoice',20);if jsonb_array_length(result)<>1 or result#>>'{0,id}'<>doc::text then raise exception 'OCR text was not permission-filtered into search';end if;
  result:=fp.inbound_email_detail(eid);if result->>'body_text'<>'Email body' then raise exception 'email detail missing body';end if;
  begin perform fp.move_inbound_email_to_bin(eid,false);raise exception 'active confirmed document allowed source removal';exception when foreign_key_violation then null;end;
  update fp.documents set lifecycle_status='deleted' where id=doc;perform fp.move_inbound_email_to_bin(eid,false);if (select deleted_at is null from fp.inbound_emails where id=eid) then raise exception 'email was not moved to bin';end if;
  perform fp.move_inbound_email_to_bin(eid,true);if (select deleted_at is not null from fp.inbound_emails where id=eid) then raise exception 'email was not restored';end if;
end$$;
rollback;
