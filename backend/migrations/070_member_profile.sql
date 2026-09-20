begin;

create table if not exists fp.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  photo_mime text,
  photo_bytes bytea,
  updated_at timestamptz not null default now(),
  constraint user_profile_photo_pair check ((photo_mime is null) = (photo_bytes is null)),
  constraint user_profile_photo_size check (photo_bytes is null or octet_length(photo_bytes) <= 1048576)
);
alter table fp.user_profiles enable row level security;
revoke all on fp.user_profiles from public, anon, authenticated;

create or replace function fp.my_profile() returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); p fp.user_profiles; fallback_name text; families jsonb;
begin
  if uid is null then raise exception 'authentication required' using errcode='42501'; end if;
  select * into p from fp.user_profiles where user_id=uid;
  select m.display_name into fallback_name from fp.members m where m.user_id=uid and m.status='active' order by m.joined_at limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('name',h.name,'role',m.role,'joined_at',m.joined_at) order by m.joined_at),'[]'::jsonb)
    into families from fp.members m join fp.households h on h.id=m.household_id where m.user_id=uid and m.status='active';
  return jsonb_build_object('display_name',coalesce(p.display_name,fallback_name,''),
    'photo_mime',p.photo_mime,'photo_base64',case when p.photo_bytes is null then null else encode(p.photo_bytes,'base64') end,
    'updated_at',p.updated_at,'families',families);
end $$;

create or replace function fp.save_my_profile(new_name text, new_photo_mime text default null, new_photo_base64 text default null, remove_photo boolean default false) returns jsonb
language plpgsql security definer set search_path=pg_catalog,fp as $$
declare uid uuid:=fp.current_user_id(); clean_name text:=btrim(coalesce(new_name,'')); bytes bytea; mime text:=lower(btrim(coalesce(new_photo_mime,'')));
begin
  if uid is null then raise exception 'authentication required' using errcode='42501'; end if;
  if char_length(clean_name) not between 1 and 80 then raise exception 'name must be 1 to 80 characters' using errcode='22023'; end if;
  if remove_photo and (new_photo_mime is not null or new_photo_base64 is not null) then raise exception 'choose photo or remove it' using errcode='22023'; end if;
  if (new_photo_mime is null) <> (new_photo_base64 is null) then raise exception 'photo type and content are required together' using errcode='22023'; end if;
  if new_photo_base64 is not null then
    if mime not in ('image/jpeg','image/png','image/webp') or char_length(new_photo_base64)>1398104 then raise exception 'unsupported or oversized photo' using errcode='22023'; end if;
    begin bytes:=decode(new_photo_base64,'base64'); exception when others then raise exception 'invalid photo' using errcode='22023'; end;
    if octet_length(bytes)<12 or octet_length(bytes)>1048576 then raise exception 'photo must be under 1 MB' using errcode='22023'; end if;
    if not ((mime='image/jpeg' and substring(bytes from 1 for 3)=decode('ffd8ff','hex'))
      or (mime='image/png' and substring(bytes from 1 for 8)=decode('89504e470d0a1a0a','hex'))
      or (mime='image/webp' and substring(bytes from 1 for 4)=convert_to('RIFF','UTF8') and substring(bytes from 9 for 4)=convert_to('WEBP','UTF8')))
    then raise exception 'photo content does not match its type' using errcode='22023'; end if;
  end if;
  insert into fp.user_profiles(user_id,display_name,photo_mime,photo_bytes)
    values(uid,clean_name,case when new_photo_base64 is null then null else mime end,bytes)
    on conflict(user_id) do update set display_name=excluded.display_name,
      photo_mime=case when new_photo_base64 is not null or remove_photo then excluded.photo_mime else fp.user_profiles.photo_mime end,
      photo_bytes=case when new_photo_base64 is not null or remove_photo then excluded.photo_bytes else fp.user_profiles.photo_bytes end,
      updated_at=now();
  update fp.members set display_name=clean_name where user_id=uid;
  return fp.my_profile();
end $$;

revoke all on function fp.my_profile(), fp.save_my_profile(text,text,text,boolean) from public, anon;
grant execute on function fp.my_profile(), fp.save_my_profile(text,text,text,boolean) to authenticated;
commit;
