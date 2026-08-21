\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION pg_temp.assert_true(ok boolean, message text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'ASSERT: %',message; END IF; END $$;

SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT 1 FROM pg_roles WHERE rolname LIKE 'fp\_%' ESCAPE '\' AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)
), 'fp roles must have no superuser/bypassrls/create privileges');
SELECT pg_temp.assert_true((SELECT NOT rolcanlogin FROM pg_roles WHERE rolname='fp_table_owner'), 'table owner non-login');
SELECT pg_temp.assert_true((SELECT NOT rolcanlogin FROM pg_roles WHERE rolname='fp_function_owner'), 'function owner non-login');
SELECT pg_temp.assert_true((SELECT rolcanlogin AND NOT rolinherit FROM pg_roles WHERE rolname='fp_api_executor'), 'executor login noinherit');
SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT 1 FROM information_schema.role_table_grants WHERE grantee IN ('fp_api_executor','fp_job_executor','fp_postgrest_authenticator')
 AND table_schema='fp_private'
), 'executors/authenticator have no table grants');
SELECT pg_temp.assert_true(NOT has_schema_privilege('fp_postgrest_authenticator','fp_private','USAGE'), 'private schema excluded from PostgREST authenticator');
SELECT pg_temp.assert_true(NOT has_schema_privilege('fp_postgrest_authenticator','fp_api','USAGE'), 'api schema excluded until explicit edge binding');
SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='fp_private' AND c.relname IN ('memberships','records')
 AND c.relkind='r' AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity)
), 'all tenant/content tables FORCE RLS');
SELECT pg_temp.assert_true(NOT EXISTS(
 SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='fp_api' AND p.prosecdef AND coalesce(array_to_string(p.proconfig,','),'') NOT LIKE '%search_path=pg_catalog%'
), 'security definers fix search_path');
SELECT pg_temp.assert_true(NOT has_schema_privilege('fp_api_executor','bodycorp_synthetic','USAGE'), 'FP cannot enter Bodycorp schema');
SELECT pg_temp.assert_true(NOT has_schema_privilege('bodycorp_synthetic_executor','fp_private','USAGE'), 'Bodycorp cannot enter FP private schema');

SET SESSION AUTHORIZATION fp_api_executor;
BEGIN;
SELECT fp_api.set_context('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001');
SELECT pg_temp.assert_true((SELECT count(*)=1 AND min(label)='family-one' FROM fp_api.list_records()), 'family one sees only own row');
COMMIT;
SELECT pg_temp.assert_true(nullif(current_setting('fp.family_id',true),'') IS NULL, 'context clears after commit');

BEGIN;
SELECT fp_api.set_context('00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000002');
SELECT pg_temp.assert_true((SELECT count(*)=1 AND min(label)='family-two' FROM fp_api.list_records()), 'pooled reuse sees only family two');
ROLLBACK;
SELECT pg_temp.assert_true(nullif(current_setting('fp.family_id',true),'') IS NULL, 'context clears after rollback');

DO $$
BEGIN
  BEGIN
    PERFORM fp_api.set_context('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'synthetic transaction error';
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
END $$;
SELECT pg_temp.assert_true(nullif(current_setting('fp.family_id',true),'') IS NULL, 'context clears after error/subtransaction');

BEGIN;
SELECT fp_api.set_context('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001');
SELECT set_config('fp.family_id','00000000-0000-0000-0000-000000000002',true);
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM fp_api.list_records()), 'tampered context signature denies all');
ROLLBACK;
RESET SESSION AUTHORIZATION;

DO $$ BEGIN
  BEGIN EXECUTE 'SET SESSION AUTHORIZATION fp_api_executor'; EXCEPTION WHEN OTHERS THEN NULL; END;
END $$;

SELECT 'DATABASE_ASSERTIONS_PASS' AS result;
