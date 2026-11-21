-- =============================================================================
-- 8SpeedyService — Migration 000009: job history v3 for the Partner earnings screen
-- Adds repair_amount (the bill the mechanic entered) and the customer's review
-- tags. v1 / v2 stay for older Partner installs. Safe to run more than once.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.mechanic_get_job_history_v3(p_limit INT DEFAULT 50)
RETURNS TABLE (
    booking_id UUID, status TEXT, vehicle_type TEXT, issue_tags TEXT[],
    pickup_address TEXT, rating INT, review_text TEXT, review_tags TEXT[], cancelled_by TEXT,
    accepted_at TIMESTAMPTZ, completed_at TIMESTAMPTZ, cancelled_at TIMESTAMPTZ,
    vehicle_label TEXT, vehicle_body_type TEXT, repair_amount INT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    RETURN QUERY
    SELECT b.id, b.status, b.vehicle_type, b.issue_tags, b.pickup_address,
           b.rating, b.review_text, b.review_tags, b.cancelled_by,
           b.accepted_at, b.completed_at, b.cancelled_at,
           b.vehicle_label, b.vehicle_body_type, b.repair_amount
      FROM public.bookings b
     WHERE b.mechanic_id = v_m.id
       AND b.status IN ('COMPLETED', 'CANCELLED')
     ORDER BY COALESCE(b.completed_at, b.cancelled_at, b.updated_at) DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.mechanic_get_job_history_v3(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mechanic_get_job_history_v3(INT) TO authenticated;
NOTIFY pgrst, 'reload schema';
