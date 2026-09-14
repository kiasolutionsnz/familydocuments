begin;
do $$
declare
  owner_id uuid:=gen_random_uuid();viewer_id uuid:=gen_random_uuid();
  family_a uuid:=gen_random_uuid();family_b uuid:=gen_random_uuid();result jsonb;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_a,'Synthetic Drive A',owner_id),(family_b,'Synthetic Drive B',owner_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_a,owner_id,'drive-owner@example.test','owner'),
    (family_b,owner_id,'drive-owner@example.test','owner'),
    (family_b,viewer_id,'drive-viewer@example.test','viewer');
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal2')::text,true);
  begin
    perform fp.household_google_drive_connection_summary();
    raise exception 'multiple Families silently selected';
  exception when sqlstate 'PT409' then null;end;
  perform fp.select_active_family(family_b);
  result:=fp.household_google_drive_connection_summary();
  if result->>'status'<>'not_connected' or result->>'household_id'<>family_b::text or result->>'credential_available'<>'false' then
    raise exception 'empty connection state incorrect';end if;
  result:=fp.authorize_google_drive_admin();
  if result->>'household_id'<>family_b::text then raise exception 'admin used first Family';end if;
  begin perform fp.authorize_google_drive_member();raise exception 'upload without Drive permitted';exception when no_data_found then null;end;
  insert into fp.google_drive_credentials(household_id,encrypted_refresh_token,token_nonce,scopes,connected_by)
    values(family_b,repeat('x',48),repeat('x',16),'https://www.googleapis.com/auth/drive.file',owner_id);
  if fp.household_google_drive_connection_summary()->>'status'<>'authorised' then raise exception 'folder selection state missing';end if;
  perform fp.select_household_google_drive_folder('synthetic-folder-b','Synthetic folder B');
  if exists(select 1 from fp.storage_connections where household_id=family_a) then raise exception 'wrote first Family';end if;
  result:=fp.authorize_google_drive_member();
  if result->>'household_id'<>family_b::text or result->>'folder_id'<>'synthetic-folder-b' then raise exception 'upload scope incorrect';end if;
  if fp.household_google_drive_connection_summary()->>'status'<>'active' then raise exception 'connected state incorrect';end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'role','authenticated','aal','aal1')::text,true);
  begin perform fp.authorize_google_drive_admin();raise exception 'MFA bypass';exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'role','authenticated','aal','aal2')::text,true);
  result:=fp.household_google_drive_connection_summary();
  if result->>'status'<>'active' or result->>'can_manage'<>'false' then raise exception 'viewer status incorrect';end if;
  begin perform fp.authorize_google_drive_member();raise exception 'viewer can upload';exception when insufficient_privilege then null;end;
  begin perform fp.authorize_google_drive_admin();raise exception 'viewer can manage';exception when insufficient_privilege then null;end;
  begin perform fp.select_active_family(family_a);raise exception 'cross-Family selection';exception when insufficient_privilege then null;end;
  update fp.google_drive_credentials set status='revoked' where household_id=family_b;
  if fp.household_google_drive_connection_summary()->>'status'<>'reconnect_required' then raise exception 'reconnect state incorrect';end if;
  update fp.members set status='suspended' where user_id=viewer_id;
  begin perform fp.household_google_drive_connection_summary();raise exception 'revoked member can read';exception when insufficient_privilege then null;end;
  perform set_config('request.jwt.claims','{}',true);
  begin perform fp.household_google_drive_connection_summary();raise exception 'anonymous access';exception when insufficient_privilege then null;end;
end $$;
rollback;
