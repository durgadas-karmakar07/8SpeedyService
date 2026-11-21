-- =============================================================================
-- 8SpeedyService — Migration 000008: maintenance job (auto refunds + storage hygiene)
-- -----------------------------------------------------------------------------
-- pg_cron calls the `maintenance` Edge Function every 10 minutes through pg_net.
-- Authentication without any shared secret: for every run the database creates a
-- random one-time nonce, sends it in the header x-cron-nonce, and the function
-- consumes it (public.maintenance_consume_nonce, service_role only). Nobody else
-- can create nonces, and each nonce works once, for 2 minutes.
-- Safe to run more than once.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE TABLE IF NOT EXISTS private.cron_nonces (
    nonce TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
REVOKE ALL ON private.cron_nonces FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.maintenance_consume_nonce(p_nonce TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_ok BOOLEAN;
BEGIN
    DELETE FROM private.cron_nonces WHERE created_at < now() - INTERVAL '2 minutes';
    DELETE FROM private.cron_nonces WHERE nonce = p_nonce RETURNING TRUE INTO v_ok;
    RETURN COALESCE(v_ok, FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.maintenance_consume_nonce(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.maintenance_consume_nonce(TEXT) TO service_role;

-- Voice notes that can be deleted from Storage:
--   * uploaded but never linked to a booking, older than 2 hours
--   * linked to a booking that ended more than 30 days ago (link is cleared here;
--     the file is deleted on the next run as an orphan)
CREATE OR REPLACE FUNCTION public.maintenance_voice_notes_to_delete(p_limit INT DEFAULT 200)
RETURNS TABLE (name TEXT) LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000);
BEGIN
    UPDATE public.bookings b
       SET voice_note_path = NULL
     WHERE b.id IN (
            SELECT x.id FROM public.bookings x
             WHERE x.voice_note_path IS NOT NULL
               AND x.status IN ('COMPLETED', 'CANCELLED')
               AND COALESCE(x.completed_at, x.cancelled_at, x.updated_at) < now() - INTERVAL '30 days'
             LIMIT v_limit);
    RETURN QUERY
    SELECT o.name
      FROM storage.objects o
     WHERE o.bucket_id = 'voice-notes'
       AND o.created_at < now() - INTERVAL '2 hours'
       AND NOT EXISTS (SELECT 1 FROM public.bookings b WHERE b.voice_note_path = o.name)
     ORDER BY o.created_at
     LIMIT v_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.maintenance_voice_notes_to_delete(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.maintenance_voice_notes_to_delete(INT) TO service_role;

CREATE OR REPLACE FUNCTION private.call_maintenance_function()
RETURNS VOID LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_nonce TEXT := encode(extensions.gen_random_bytes(32), 'hex');
BEGIN
    INSERT INTO private.cron_nonces (nonce) VALUES (v_nonce);
    PERFORM net.http_post(
        url := 'https://mzxcbhiemdkhalslxwid.supabase.co/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-nonce', v_nonce),
        body := '{}'::jsonb,
        timeout_milliseconds := 55000
    );
END;
$$;
REVOKE ALL ON FUNCTION private.call_maintenance_function() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'speedy-maintenance-function';
    PERFORM cron.schedule('speedy-maintenance-function', '*/10 * * * *', 'SELECT private.call_maintenance_function();');
    -- pg_net keeps responses for a while; trim them daily.
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'speedy-net-cleanup';
    PERFORM cron.schedule('speedy-net-cleanup', '17 3 * * *', $c$DELETE FROM net._http_response WHERE created < now() - interval '2 days'$c$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available (%).', SQLERRM;
END;
$$;
