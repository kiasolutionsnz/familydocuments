begin;

do $$
declare
  owner_id constant uuid:='2f000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='2f000000-0000-4000-8000-000000000002';
  family_one uuid:=gen_random_uuid();family_two uuid:=gen_random_uuid();
  category_one uuid:=gen_random_uuid();category_two uuid:=gen_random_uuid();
  document_one uuid:=gen_random_uuid();document_two uuid:=gen_random_uuid();
  pdf bytea:=convert_to('%PDF-1.4'||chr(10)||'synthetic fixture'||chr(10)||'%%EOF','UTF8');
  result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_one,'Viewer fixture one',owner_id),
    (family_two,'Viewer fixture two',owner_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_one,owner_id,'owner-2f@example.test','owner'),
    (family_two,owner_id,'owner-2f@example.test','owner'),
    (family_one,viewer_id,'viewer-2f@example.test','viewer');
  insert into fp.categories(id,household_id,name,is_system,created_by) values
    (category_one,family_one,'Documents',true,owner_id),
    (category_two,family_two,'Documents',true,owner_id);
  insert into fp.documents(id,household_id,category_id,title,created_by,
    original_filename,mime_type,confirmation_status) values
    (document_one,family_one,category_one,'Synthetic first',owner_id,
      'first.pdf','application/pdf','confirmed'),
    (document_two,family_two,category_two,'Synthetic second',owner_id,
      'second.pdf','application/pdf','confirmed');
  insert into fp.manual_document_sources(household_id,document_id,file_name,
    mime_type,content,sha256,created_by) values
    (family_one,document_one,'first.pdf','application/pdf',pdf,
      encode(extensions.digest(pdf,'sha256'),'hex'),owner_id);
  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by)
    values(document_one,viewer_id,'view',owner_id);

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,
    'email','owner-2f@example.test','role','authenticated')::text,true);
  perform fp.select_active_family(family_one);
  result:=fp.document_preview_source(document_one);
  if decode(result->>'content_base64','base64')<>pdf then
    raise exception 'preview altered original bytes';
  end if;
  begin
    perform fp.document_preview_source(document_two);
    raise exception 'other active Family source was exposed';
  exception when sqlstate 'PT404' then null;
  end;
  perform fp.select_active_family(family_two);
  result:=fp.document_preview_source(document_two);
  if result->>'status'<>'file_unavailable' then
    raise exception 'missing original was not distinguished';
  end if;
  begin
    perform fp.document_preview_source(document_one);
    raise exception 'previous Family source was exposed';
  exception when sqlstate 'PT404' then null;
  end;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,
    'email','viewer-2f@example.test','role','authenticated')::text,true);
  result:=fp.document_preview_source(document_one);
  if decode(result->>'content_base64','base64')<>pdf then
    raise exception 'read-only permitted source was denied';
  end if;
  update fp.members set status='suspended'
    where household_id=family_one and user_id=viewer_id;
  begin
    perform fp.document_preview_source(document_one);
    raise exception 'revoked source was exposed';
  exception when insufficient_privilege then null;
  end;
end $$;

rollback;
