\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE ROLE fp_table_owner NOLOGIN NOINHERIT NOBYPASSRLS;
CREATE ROLE fp_function_owner NOLOGIN NOINHERIT NOBYPASSRLS;
CREATE ROLE fp_api_executor LOGIN NOINHERIT NOBYPASSRLS PASSWORD :'executor_password';
CREATE ROLE fp_job_executor LOGIN NOINHERIT NOBYPASSRLS PASSWORD :'job_password';
CREATE ROLE fp_postgrest_authenticator NOLOGIN NOINHERIT NOBYPASSRLS;
CREATE ROLE bodycorp_synthetic_owner NOLOGIN NOINHERIT NOBYPASSRLS;
CREATE ROLE bodycorp_synthetic_executor LOGIN NOINHERIT NOBYPASSRLS PASSWORD :'bodycorp_password';

CREATE SCHEMA fp_private AUTHORIZATION fp_table_owner;
CREATE SCHEMA fp_api AUTHORIZATION fp_function_owner;
CREATE SCHEMA bodycorp_synthetic AUTHORIZATION bodycorp_synthetic_owner;
REVOKE ALL ON SCHEMA fp_private, fp_api, bodycorp_synthetic FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE fp_table_owner IN SCHEMA fp_private REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE fp_table_owner IN SCHEMA fp_private REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE fp_function_owner IN SCHEMA fp_api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE bodycorp_synthetic_owner IN SCHEMA bodycorp_synthetic REVOKE ALL ON TABLES FROM PUBLIC;

SET ROLE fp_table_owner;
CREATE TABLE fp_private.context_keys (
  key_id integer PRIMARY KEY CHECK (key_id = 1),
  key_material bytea NOT NULL
);
INSERT INTO fp_private.context_keys VALUES (1, public.gen_random_bytes(32));

CREATE TABLE fp_private.memberships (
  user_id uuid NOT NULL,
  family_id uuid NOT NULL,
  active boolean NOT NULL DEFAULT true,
  PRIMARY KEY (user_id, family_id)
);
CREATE TABLE fp_private.records (
  record_id uuid PRIMARY KEY,
  family_id uuid NOT NULL,
  label text NOT NULL
);
INSERT INTO fp_private.memberships VALUES
 ('00000000-0000-0000-0000-000000000101','00000000-0000-0000-0000-000000000001',true),
 ('00000000-0000-0000-0000-000000000202','00000000-0000-0000-0000-000000000002',true);
INSERT INTO fp_private.records VALUES
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','family-one'),
 ('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','family-two');
ALTER TABLE fp_private.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE fp_private.memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE fp_private.records ENABLE ROW LEVEL SECURITY;
ALTER TABLE fp_private.records FORCE ROW LEVEL SECURITY;
RESET ROLE;

GRANT USAGE ON SCHEMA fp_private TO fp_function_owner;
GRANT SELECT ON fp_private.context_keys, fp_private.memberships, fp_private.records TO fp_function_owner;

SET ROLE fp_function_owner;
CREATE FUNCTION fp_api.context_signature(p_user uuid, p_family uuid, p_tx bigint)
RETURNS text LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
 SELECT encode(public.hmac(
   convert_to(p_user::text || ':' || p_family::text || ':' || p_tx::text, 'UTF8'),
   (SELECT key_material FROM fp_private.context_keys WHERE key_id=1), 'sha256'), 'hex')
$$;

CREATE FUNCTION fp_api.set_context(p_user uuid, p_family uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE tx bigint := txid_current();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM fp_private.memberships m
    WHERE m.user_id=p_user AND m.family_id=p_family AND m.active
  ) THEN RAISE EXCEPTION 'unauthorized context'; END IF;
  PERFORM set_config('fp.user_id', p_user::text, true);
  PERFORM set_config('fp.family_id', p_family::text, true);
  PERFORM set_config('fp.tx_id', tx::text, true);
  PERFORM set_config('fp.signature', fp_api.context_signature(p_user,p_family,tx), true);
END $$;

CREATE FUNCTION fp_api.context_valid()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $$
 SELECT CASE WHEN nullif(current_setting('fp.user_id',true),'') IS NULL
   OR nullif(current_setting('fp.family_id',true),'') IS NULL
   OR nullif(current_setting('fp.tx_id',true),'') IS NULL
   OR nullif(current_setting('fp.signature',true),'') IS NULL
 THEN false ELSE
   current_setting('fp.tx_id',true)::bigint = txid_current()
   AND current_setting('fp.signature',true) = fp_api.context_signature(
     current_setting('fp.user_id',true)::uuid,
     current_setting('fp.family_id',true)::uuid,
     current_setting('fp.tx_id',true)::bigint)
 END
$$;

CREATE FUNCTION fp_api.list_records()
RETURNS TABLE(record_id uuid, label text) LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$ SELECT r.record_id, r.label FROM fp_private.records r ORDER BY r.record_id $$;
RESET ROLE;

GRANT USAGE ON SCHEMA fp_api TO fp_table_owner;
GRANT EXECUTE ON FUNCTION fp_api.context_valid() TO fp_table_owner;
SET ROLE fp_table_owner;
CREATE POLICY membership_context ON fp_private.memberships
 USING (current_user='fp_function_owner' OR (fp_api.context_valid()
        AND family_id=nullif(current_setting('fp.family_id',true),'')::uuid
        AND user_id=nullif(current_setting('fp.user_id',true),'')::uuid));
CREATE POLICY records_context ON fp_private.records
 USING (fp_api.context_valid() AND family_id=nullif(current_setting('fp.family_id',true),'')::uuid);
RESET ROLE;

ALTER FUNCTION fp_api.context_signature(uuid,uuid,bigint) OWNER TO fp_function_owner;
ALTER FUNCTION fp_api.set_context(uuid,uuid) OWNER TO fp_function_owner;
ALTER FUNCTION fp_api.context_valid() OWNER TO fp_function_owner;
ALTER FUNCTION fp_api.list_records() OWNER TO fp_function_owner;
REVOKE ALL ON ALL TABLES IN SCHEMA fp_private FROM PUBLIC, fp_api_executor, fp_job_executor, fp_postgrest_authenticator;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fp_api FROM PUBLIC;
GRANT USAGE ON SCHEMA fp_api TO fp_api_executor;
GRANT EXECUTE ON FUNCTION fp_api.set_context(uuid,uuid), fp_api.list_records() TO fp_api_executor;

SET ROLE bodycorp_synthetic_owner;
CREATE TABLE bodycorp_synthetic.private_rows(id integer PRIMARY KEY, secret text NOT NULL);
INSERT INTO bodycorp_synthetic.private_rows VALUES (1,'synthetic-only');
RESET ROLE;
REVOKE ALL ON SCHEMA bodycorp_synthetic FROM PUBLIC, fp_api_executor, fp_job_executor, fp_postgrest_authenticator;
REVOKE ALL ON ALL TABLES IN SCHEMA bodycorp_synthetic FROM PUBLIC, fp_api_executor, fp_job_executor, fp_postgrest_authenticator;
REVOKE ALL ON SCHEMA fp_private, fp_api FROM bodycorp_synthetic_executor;
REVOKE ALL ON ALL TABLES IN SCHEMA fp_private FROM bodycorp_synthetic_executor;
