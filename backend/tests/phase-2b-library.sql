begin;

do $$
declare
  owner_id constant uuid:='22000000-0000-4000-8000-000000000001';
  viewer_id constant uuid:='22000000-0000-4000-8000-000000000002';
  outsider_id constant uuid:='22000000-0000-4000-8000-000000000003';
  family_id uuid:=gen_random_uuid(); other_family uuid:=gen_random_uuid();
  documents_category uuid:=gen_random_uuid(); travel_category uuid; rentals_category uuid; custom_category uuid:=gen_random_uuid(); foreign_category uuid:=gen_random_uuid();
  primary_document uuid:=gen_random_uuid(); travel_document uuid:=gen_random_uuid(); unassigned_travel uuid:=gen_random_uuid(); rental_document uuid:=gen_random_uuid(); unassigned_rental uuid:=gen_random_uuid(); foreign_document uuid:=gen_random_uuid();
  trip_id uuid:=gen_random_uuid(); foreign_trip uuid:=gen_random_uuid(); property_id uuid:=gen_random_uuid(); foreign_property uuid:=gen_random_uuid();
  link_category uuid:=gen_random_uuid(); private_category uuid; result jsonb; before_version timestamptz;
begin
  insert into fp.households(id,name,owner_user_id) values
    (family_id,'Library family',owner_id),(other_family,'Other library family',outsider_id);
  insert into fp.members(household_id,user_id,email,role) values
    (family_id,owner_id,'library-owner@example.test','owner'),
    (family_id,viewer_id,'library-viewer@example.test','viewer'),
    (other_family,outsider_id,'library-outsider@example.test','owner');
  select id into travel_category from fp.categories where household_id=family_id and name='Travel';
  select id into rentals_category from fp.categories where household_id=family_id and name='Rental records';
  insert into fp.categories(id,household_id,name,is_system,created_by) values
    (documents_category,family_id,'Documents',true,owner_id),
    (custom_category,family_id,'Medical',false,owner_id),
    (foreign_category,other_family,'Foreign',false,outsider_id);
  insert into fp.documents(id,household_id,category_id,title,original_filename,mime_type,created_by,confirmation_status,tags,created_at) values
    (primary_document,family_id,documents_category,'Family passport','passport.pdf','application/pdf',owner_id,'confirmed','["identity","travel"]',now()),
    (travel_document,family_id,travel_category,'Fiji flight','flight.pdf','application/pdf',owner_id,'confirmed','["flight"]',now()-interval '1 day'),
    (unassigned_travel,family_id,travel_category,'Travel notes','notes.pdf','application/pdf',owner_id,'confirmed','[]',now()-interval '2 days'),
    (rental_document,family_id,rentals_category,'Rental insurance','insurance.pdf','application/pdf',owner_id,'confirmed','["insurance"]',now()-interval '3 days'),
    (unassigned_rental,family_id,rentals_category,'Tenancy notes','tenancy.pdf','application/pdf',owner_id,'confirmed','[]',now()-interval '4 days'),
    (foreign_document,other_family,foreign_category,'Foreign secret','secret.pdf','application/pdf',outsider_id,'confirmed','["secret"]',now());
  insert into fp.document_permissions(document_id,member_user_id,access_level,granted_by)
    values(primary_document,viewer_id,'view',owner_id);
  insert into fp.travel_trips(id,household_id,name,destination,start_date,created_by) values
    (trip_id,family_id,'Fiji 2027','Fiji','2027-01-10',owner_id),
    (foreign_trip,other_family,'Private trip','Elsewhere','2027-02-01',outsider_id);
  insert into fp.travel_records(household_id,trip_id,document_id,travel_kind,confirmed_by)
    values(family_id,trip_id,travel_document,'flight',owner_id);
  insert into fp.entities(id,household_id,entity_type,name,created_by) values
    (property_id,family_id,'property','12 Example Street',owner_id),
    (foreign_property,other_family,'property','99 Private Street',outsider_id);
  insert into fp.rental_properties(entity_id,household_id,address,created_by) values
    (property_id,family_id,'12 Example Street, Wellington',owner_id),
    (foreign_property,other_family,'99 Private Street, Auckland',outsider_id);
  insert into fp.rental_bills(household_id,property_entity_id,document_id,expense_category,confirmed_by)
    values(family_id,property_id,rental_document,'insurance',owner_id);
  insert into fp.saved_link_categories(id,household_id,owner_user_id,name) values(link_category,family_id,owner_id,'Research');
  insert into fp.saved_links(household_id,owner_user_id,category_id,url,normalized_url_hash,source_host,title) values
    (family_id,owner_id,link_category,'https://example.test/library',repeat('4',64),'example.test','Library reference');

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','library-owner@example.test','role','authenticated','aal','aal2')::text,true);
  result:=fp.create_library_category('Family archive','shared');
  if result->>'visibility'<>'shared' then raise exception 'shared category visibility missing';end if;
  result:=fp.library_workspace(null,null,null,'newest',2,0);
  if (result->>'document_count')::int<>5 or jsonb_array_length(result->'documents')<>2 then raise exception 'counts or pagination failed';end if;
  if result->'documents'->0->>'title'<>'Family passport' then raise exception 'newest ordering failed';end if;
  if not exists(select 1 from jsonb_array_elements(result->'categories') x where x->>'name'='Medical') then raise exception 'custom category missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'trips') x where x->>'name'='Fiji 2027') or exists(select 1 from jsonb_array_elements(result->'trips') x where x->>'name'='Private trip') then raise exception 'trip isolation failed';end if;
  if not exists(select 1 from jsonb_array_elements(result->'unassigned_travel') x where x->>'title'='Travel notes') then raise exception 'unassigned travel missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'rentals') x where x->>'name'='12 Example Street') or exists(select 1 from jsonb_array_elements(result->'rentals') x where x->>'name'='99 Private Street') then raise exception 'rental isolation failed';end if;
  if not exists(select 1 from jsonb_array_elements(result->'unassigned_rentals') x where x->>'title'='Tenancy notes') then raise exception 'unassigned rental missing';end if;
  if not exists(select 1 from jsonb_array_elements(result->'links') x where x->>'title'='Library reference') then raise exception 'saved link missing';end if;
  if jsonb_array_length(fp.library_workspace('nothing matches',null,null,'newest',40,0)->'documents')<>0 then raise exception 'nonmatching search returned documents';end if;
  if not exists(select 1 from jsonb_array_elements(fp.library_workspace('IDENTITY',null,null,'newest',40,0)->'documents') x where x->>'id'=primary_document::text) then raise exception 'tag search failed';end if;
  if jsonb_array_length(fp.library_workspace(null,travel_category,null,'newest',40,0)->'documents')<>2 then raise exception 'category filter failed';end if;
  if jsonb_array_length(fp.library_workspace(null,null,'travel','newest',40,0)->'documents')<>1 then raise exception 'tag filter failed';end if;

  select updated_at into before_version from fp.documents where id=primary_document;
  perform fp.update_library_document(primary_document,custom_category,'[" Health ","health","IDENTITY"]',before_version);
  if (select category_id<>custom_category or tags<>'["health","identity"]'::jsonb from fp.documents where id=primary_document) then raise exception 'metadata update or tag normalisation failed';end if;
  begin perform fp.update_library_document(primary_document,foreign_category,'[]', (select updated_at from fp.documents where id=primary_document)); raise exception 'cross-family category accepted'; exception when sqlstate '22023' then null;end;
  begin perform fp.update_library_document(foreign_document,custom_category,'["secret"]', (select updated_at from fp.documents where id=foreign_document)); raise exception 'cross-family document/tag update accepted'; exception when insufficient_privilege then null;end;
  begin perform fp.update_library_document(primary_document,documents_category,'[]',before_version); raise exception 'stale update accepted'; exception when sqlstate 'PT409' then null;end;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',viewer_id,'email','library-viewer@example.test','role','authenticated')::text,true);
  result:=fp.create_library_category('My medical','private');
  private_category:=(result->>'id')::uuid;
  if result->>'visibility'<>'private' or not (result->>'owned_by_me')::boolean then raise exception 'private category result invalid';end if;
  result:=fp.library_workspace(null,null,null,'newest',40,0);
  if not exists(select 1 from jsonb_array_elements(result->'categories') x where x->>'id'=private_category::text) then raise exception 'private category not visible to its member owner';end if;
  if jsonb_array_length(result->'documents')<>1 or result->'documents'->0->>'id'<>primary_document::text or (result->'documents'->0->>'can_edit')::boolean then raise exception 'read-only document permissions failed';end if;
  begin perform fp.update_library_document(primary_document,documents_category,'[]',(select updated_at from fp.documents where id=primary_document));raise exception 'viewer edited metadata';exception when insufficient_privilege then null;end;
  delete from fp.document_permissions p where p.document_id=primary_document and p.member_user_id=viewer_id;
  if jsonb_array_length(fp.library_workspace('Family passport',null,null,'newest',40,0)->'documents')<>0 then raise exception 'revoked document remained searchable';end if;

  perform set_config('request.jwt.claims',jsonb_build_object('sub',owner_id,'email','library-owner@example.test','role','authenticated')::text,true);
  if exists(select 1 from jsonb_array_elements(fp.library_workspace(null,null,null,'newest',40,0)->'categories') x where x->>'id'=private_category::text) then raise exception 'private category leaked to family admin';end if;
  begin perform fp.create_travel_record(foreign_trip,primary_document,'other');raise exception 'cross-family trip association accepted';exception when insufficient_privilege then null;end;
  begin perform fp.create_rental_bill(foreign_property,primary_document,'other');raise exception 'cross-family rental association accepted';exception when insufficient_privilege then null;end;
end $$;

rollback;
