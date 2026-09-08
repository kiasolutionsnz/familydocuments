begin;

create or replace function fp.household_google_drive_connection_summary() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id();hid uuid;row fp.storage_connections;credential fp.google_drive_credentials;connection_status text;
begin
  select household_id into hid from fp.members where user_id=uid and status='active' order by joined_at limit 1;
  if hid is null then return null;end if;
  select * into row from fp.storage_connections where household_id=hid and provider='google_drive';
  select * into credential from fp.google_drive_credentials where household_id=hid;
  if row.id is null and credential.household_id is null then return null;end if;
  connection_status:=case
    when credential.status='active' and row.status='active' then 'active'
    when credential.status='active' then 'authorised'
    when row.status='active' then 'reconnect_required'
    else coalesce(row.status,credential.status,'disconnected')
  end;
  return jsonb_build_object('provider','google_drive','folder_id',row.provider_folder_id,'folder_name',row.folder_name,'web_view_link',row.web_view_link,
    'status',connection_status,'credential_available',credential.status='active','google_account',credential.google_account,
    'configured_at',coalesce(row.configured_at,credential.connected_at),'can_manage',fp.is_household_admin(hid),'connection_mode','household_gateway');
end $$;

revoke execute on function fp.household_google_drive_connection_summary() from public,anon;
grant execute on function fp.household_google_drive_connection_summary() to authenticated;

commit;
