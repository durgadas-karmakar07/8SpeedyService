-- =============================================================================
-- 8SpeedyService — migration 000010: AI answer feedback / reporting + retention
-- =============================================================================
-- * Google Play "AI-generated content" policy: users must be able to report or
--   flag offensive AI output without leaving the app. Both apps (1.1.0) show
--   "Helpful / Not helpful / Report" under every AI answer. The choice is saved
--   on the user's own public.ai_requests row by public.ai_submit_feedback().
--   Review reports in the SQL editor:
--     SELECT id, mode, feedback, feedback_note, output->>'summary' AS answer, feedback_at
--       FROM public.ai_requests
--      WHERE feedback IN ('wrong', 'unsafe', 'offensive')
--      ORDER BY feedback_at DESC;
-- * Retention (privacy policy): AI questions/answers and chat messages are
--   deleted 180 days after they were written, in batches, by private.maintenance().
-- * Partial indexes so the 10-minute maintenance job never scans whole tables.
-- Re-runnable.
-- =============================================================================

ALTER TABLE public.ai_requests ADD COLUMN IF NOT EXISTS feedback TEXT;
ALTER TABLE public.ai_requests ADD COLUMN IF NOT EXISTS feedback_note TEXT;
ALTER TABLE public.ai_requests ADD COLUMN IF NOT EXISTS feedback_at TIMESTAMPTZ;

DO $$
BEGIN
    ALTER TABLE public.ai_requests ADD CONSTRAINT ai_requests_feedback_check
        CHECK (feedback IS NULL OR feedback IN ('helpful', 'not_helpful', 'wrong', 'unsafe', 'offensive'));
EXCEPTION WHEN duplicate_object THEN NULL;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_ai_requests_flagged ON public.ai_requests (feedback_at DESC)
    WHERE feedback IN ('wrong', 'unsafe', 'offensive');
CREATE INDEX IF NOT EXISTS idx_ai_requests_created ON public.ai_requests (created_at);
CREATE INDEX IF NOT EXISTS idx_booking_messages_created ON public.booking_messages (created_at);
CREATE INDEX IF NOT EXISTS idx_customers_cooldown ON public.customers (booking_cooldown_until)
    WHERE booking_cooldown_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mechanics_suspended ON public.mechanics (suspended_until)
    WHERE suspended_until IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Feedback on one of the caller's own AI answers. Returns FALSE when the answer
-- does not exist / belongs to someone else (no information leak either way).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_submit_feedback(
    p_request_id UUID, p_feedback TEXT, p_note TEXT DEFAULT NULL
)
RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_rows INT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF p_request_id IS NULL OR p_feedback IS NULL
       OR p_feedback NOT IN ('helpful', 'not_helpful', 'wrong', 'unsafe', 'offensive') THEN
        RAISE EXCEPTION 'Invalid feedback.' USING ERRCODE = '22023';
    END IF;
    IF NOT private.hit_rate_limit('aifb:' || v_uid::TEXT, 30, 3600) THEN
        RAISE EXCEPTION 'Too many reports in a short time. Please try again later.';
    END IF;

    UPDATE public.ai_requests
       SET feedback = p_feedback,
           feedback_note = private.clean_text(p_note, 300),
           feedback_at = now()
     WHERE id = p_request_id AND user_id = v_uid AND output IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.ai_submit_feedback(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ai_submit_feedback(UUID, TEXT, TEXT) TO authenticated;

-- -----------------------------------------------------------------------------
-- Maintenance (every 10 min, scheduled in 000006): same as before + retention.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.maintenance()
RETURNS VOID LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    DELETE FROM private.rate_limits WHERE expires_at < now();
    DELETE FROM private.security_events WHERE created_at < now() - INTERVAL '180 days';
    UPDATE public.customers SET booking_cooldown_until = NULL
     WHERE booking_cooldown_until IS NOT NULL AND booking_cooldown_until < now();
    UPDATE public.mechanics SET suspended_until = NULL, suspension_reason = NULL
     WHERE suspended_until IS NOT NULL AND suspended_until < now();
    -- Refunds stuck in PROCESSING for 30 min go back to the queue.
    UPDATE public.bookings SET refund_status = 'REQUESTED'
     WHERE refund_status = 'PROCESSING' AND updated_at < now() - INTERVAL '30 minutes';
    -- Retention: AI questions/answers and chat messages, 180 days (batched).
    DELETE FROM public.ai_requests WHERE id IN (
        SELECT id FROM public.ai_requests
         WHERE created_at < now() - INTERVAL '180 days' LIMIT 5000);
    DELETE FROM public.booking_messages WHERE id IN (
        SELECT id FROM public.booking_messages
         WHERE created_at < now() - INTERVAL '180 days' LIMIT 5000);
END;
$$;
REVOKE ALL ON FUNCTION private.maintenance() FROM PUBLIC, anon, authenticated;
