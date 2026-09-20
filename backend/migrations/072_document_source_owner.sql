begin;

-- document_source is a SECURITY DEFINER wrapper around private source helpers.
-- Keep it under the same narrowly scoped owner as those helpers so callers do
-- not need direct EXECUTE on internal authorization functions.
alter function fp.document_source(uuid) owner to supabase_admin;

revoke all on function fp.document_source(uuid) from public, anon;
grant execute on function fp.document_source(uuid) to authenticated;

commit;
