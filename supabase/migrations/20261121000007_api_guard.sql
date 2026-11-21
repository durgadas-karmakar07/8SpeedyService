-- =============================================================================
-- 8SpeedyService — Migration 000007: API guard (PostgREST db_pre_request)
-- -----------------------------------------------------------------------------
-- Audit #2, attack 2: PostGIS is installed in `public` (Supabase default) and
-- its helper functions are owned by supabase_admin, so we cannot REVOKE them.
-- Anyone with the public APK key could call e.g. /rest/v1/rpc/postgis_full_version
-- (version disclosure), /rpc/addauth or /rpc/populate_geometry_columns, and read
-- /rest/v1/geometry_columns.
--
-- This guard runs before every REST request of the app roles and only allows
--   * RPC calls to functions created by OUR migrations (owner `postgres`)
--   * table/view access to relations created by OUR migrations
-- Everything owned by extensions (PostGIS, ...) answers 404.
-- New RPCs need no allow-list entry: if a migration creates them, they work.
--
-- Emergency off switch (if the API ever misbehaves):
--   ALTER ROLE authenticator RESET pgrst.db_pre_request; NOTIFY pgrst, 'reload config';
-- Safe to run more than once.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS api_guard;
REVOKE ALL ON SCHEMA api_guard FROM PUBLIC;
GRANT USAGE ON SCHEMA api_guard TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION api_guard.check_request()
RETURNS VOID LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
    v_path TEXT := current_setting('request.path', TRUE);
    v_name TEXT;
    v_owner OID;
BEGIN
    -- Server-side callers (service_role: Edge Functions, dashboard) are not limited.
    IF v_path IS NULL OR current_user NOT IN ('anon', 'authenticated') THEN
        RETURN;
    END IF;
    SELECT oid INTO v_owner FROM pg_catalog.pg_roles WHERE rolname = 'postgres';

    IF v_path LIKE '/rpc/%' THEN
        v_name := split_part(substr(v_path, 6), '/', 1);
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc p
              JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'public' AND p.proname = v_name AND p.proowner = v_owner
        ) THEN
            RAISE SQLSTATE 'PT404' USING MESSAGE = 'Not found';
        END IF;
    ELSE
        v_name := split_part(substr(v_path, 2), '/', 1);
        IF v_name = '' OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND c.relname = v_name AND c.relowner = v_owner
        ) THEN
            RAISE SQLSTATE 'PT404' USING MESSAGE = 'Not found';
        END IF;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION api_guard.check_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api_guard.check_request() TO anon, authenticated, service_role;

ALTER ROLE authenticator SET pgrst.db_pre_request = 'api_guard.check_request';
NOTIFY pgrst, 'reload config';
