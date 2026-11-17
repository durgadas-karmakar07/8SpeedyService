-- =============================================================================
-- 8SpeedyService — Mechanic Partner App backend additions
-- =============================================================================
-- Run AFTER 20261117000001_init_8speedyservice.sql (Supabase SQL Editor -> Run).
-- Idempotent: safe to re-run.
--
-- Adds:
--   1. app_config.min_partner_version  (force-update for the Partner app)
--   2. bookings.released_by            (mechanic who dropped a job can't re-take it)
--   3. mechanic_link_account()         (login -> link auth user to mechanics row by phone)
--   4. mechanic_register(...)          (self sign-up, starts unverified)
--   5. mechanic_release_job(...)       (mechanic drops job before OTP -> back to search)
--   6. mechanic_get_booking_status()   (job screen detects customer cancel)
--   7. mechanic_get_stats() / mechanic_get_job_history()
--   8. mechanic_get_open_requests      (re-defined: hides jobs this mechanic released)
-- =============================================================================

ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS min_partner_version TEXT DEFAULT '1.0.0';
ALTER TABLE public.bookings  ADD COLUMN IF NOT EXISTS released_by UUID[] DEFAULT ARRAY[]::UUID[];

-- -----------------------------------------------------------------------------
-- Helper: verified phone of the logged-in auth user in +91XXXXXXXXXX form
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._auth_phone()
RETURNS TEXT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT CASE
             WHEN u.phone IS NULL OR u.phone = '' THEN NULL
             WHEN left(u.phone, 1) = '+' THEN u.phone
             ELSE '+' || u.phone
           END
      FROM auth.users u
     WHERE u.id = auth.uid();
$$;

-- -----------------------------------------------------------------------------
-- 1. mechanic_link_account — called by the Partner app right after login.
--    The phone is OTP-verified by Supabase Auth, so matching on it is safe.
--    Returns { state: 'NOT_REGISTERED' | 'PENDING' | 'VERIFIED', mechanic: {...} }
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_link_account()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_phone TEXT;
    v_m public.mechanics%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v_m FROM public.mechanics WHERE user_id = v_uid;

    IF NOT FOUND THEN
        v_phone := public._auth_phone();
        IF v_phone IS NULL THEN
            RAISE EXCEPTION 'Phone number not found for this account.';
        END IF;
        -- Admin pre-created the mechanic row from the Dashboard -> link it now.
        UPDATE public.mechanics SET user_id = v_uid
         WHERE phone = v_phone AND user_id IS NULL
        RETURNING * INTO v_m;
    END IF;

    IF v_m.id IS NULL THEN
        RETURN jsonb_build_object('state', 'NOT_REGISTERED');
    END IF;

    RETURN jsonb_build_object(
        'state', CASE WHEN v_m.is_verified THEN 'VERIFIED' ELSE 'PENDING' END,
        'mechanic', to_jsonb(v_m) - 'current_location'
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. mechanic_register — self sign-up from the Partner app (is_verified = FALSE).
--    Admin verifies in Dashboard (Table Editor -> mechanics -> is_verified = true).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_register(
    p_full_name TEXT,
    p_shop_name TEXT,
    p_vehicle_specialties TEXT[]
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_phone TEXT;
    v_name TEXT := trim(COALESCE(p_full_name, ''));
    v_shop TEXT := NULLIF(left(trim(COALESCE(p_shop_name, '')), 80), '');
    v_specs TEXT[];
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF length(v_name) < 2 OR length(v_name) > 60 THEN
        RAISE EXCEPTION 'Please enter your full name.';
    END IF;

    SELECT array_agg(DISTINCT s) INTO v_specs
      FROM unnest(COALESCE(p_vehicle_specialties, ARRAY[]::TEXT[])) AS s
     WHERE s IN ('cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle');
    IF v_specs IS NULL OR array_length(v_specs, 1) = 0 THEN
        RAISE EXCEPTION 'Please select at least one vehicle type you repair.';
    END IF;

    IF EXISTS (SELECT 1 FROM public.mechanics WHERE user_id = v_uid) THEN
        RETURN public.mechanic_link_account();
    END IF;

    v_phone := public._auth_phone();
    IF v_phone IS NULL THEN
        RAISE EXCEPTION 'Phone number not found for this account.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.mechanics WHERE phone = v_phone) THEN
        -- Row exists but is linked to another login (or link failed) -> admin must fix.
        RAISE EXCEPTION 'This number is already registered as a partner. Please contact support.';
    END IF;

    INSERT INTO public.mechanics (full_name, phone, shop_name, vehicle_specialties,
                                  is_verified, is_online, user_id)
    VALUES (v_name, v_phone, v_shop, v_specs, FALSE, FALSE, v_uid);

    RETURN public.mechanic_link_account();
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. mechanic_get_open_requests — same as before, but a mechanic never sees a
--    job they already released.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_get_open_requests(p_radius_meters INT DEFAULT 10000)
RETURNS TABLE (
    booking_id UUID, vehicle_type TEXT, issue_tags TEXT[], issue_note TEXT,
    pickup_address TEXT, pickup_lat DOUBLE PRECISION, pickup_lng DOUBLE PRECISION,
    distance_meters DOUBLE PRECISION, created_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    IF v_m.current_location IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT b.id, b.vehicle_type, b.issue_tags, b.issue_note, b.pickup_address,
           b.pickup_lat, b.pickup_lng,
           ST_Distance(b.pickup_location, v_m.current_location), b.created_at
      FROM public.bookings b
     WHERE b.status = 'SEARCHING'
       AND b.mechanic_id IS NULL
       AND b.payment_status IN ('FREE_OFFER', 'PAID')
       AND b.vehicle_type = ANY (v_m.vehicle_specialties)
       AND NOT (v_m.id = ANY (COALESCE(b.released_by, ARRAY[]::UUID[])))
       AND ST_DWithin(b.pickup_location, v_m.current_location, LEAST(GREATEST(p_radius_meters, 500), 15000))
     ORDER BY b.created_at ASC
     LIMIT 20;
END;
$$;

-- Accept must also refuse a job this mechanic released earlier.
CREATE OR REPLACE FUNCTION public.mechanic_accept_booking(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_updated INT;
BEGIN
    IF EXISTS (SELECT 1 FROM public.bookings WHERE mechanic_id = v_m.id
               AND status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')) THEN
        RAISE EXCEPTION 'Finish your current job before accepting a new one.';
    END IF;

    -- Atomic: only the first mechanic to tap wins.
    UPDATE public.bookings
       SET status = 'ACCEPTED', mechanic_id = v_m.id, accepted_at = NOW()
     WHERE id = p_booking_id AND status = 'SEARCHING' AND mechanic_id IS NULL
       AND payment_status IN ('FREE_OFFER', 'PAID')
       AND vehicle_type = ANY (v_m.vehicle_specialties)
       AND NOT (v_m.id = ANY (COALESCE(released_by, ARRAY[]::UUID[])));
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated = 0 THEN
        RAISE EXCEPTION 'This request was already taken or cancelled.';
    END IF;

    -- Mechanic is busy now; keep them online so the customer sees live location.
    UPDATE public.mechanics SET is_online = TRUE WHERE id = v_m.id;
    RETURN public.mechanic_get_active_job();
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. mechanic_release_job — mechanic can't make it (before OTP start).
--    Booking goes back to SEARCHING for other mechanics; customer's app
--    returns to the radar screen automatically.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_release_job(p_booking_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    UPDATE public.bookings
       SET status = 'SEARCHING',
           mechanic_id = NULL,
           accepted_at = NULL,
           arrived_at = NULL,
           otp_attempts = 0,
           released_by = array_append(COALESCE(released_by, ARRAY[]::UUID[]), v_m.id),
           -- Give the customer a fresh 30-minute search window.
           created_at = NOW()
     WHERE id = p_booking_id AND mechanic_id = v_m.id AND status IN ('ACCEPTED', 'ARRIVED');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This job can no longer be released (already started or closed).';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. mechanic_get_booking_status — lets the job screen detect that the
--    customer cancelled (mechanic_get_active_job then returns NULL).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_get_booking_status(p_booking_id UUID)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM public.bookings
     WHERE id = p_booking_id AND mechanic_id = v_m.id;
    RETURN COALESCE(v_status, 'UNAVAILABLE');
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. Stats & history for the Partner app "My Jobs" screen
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_get_stats()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_today DATE := (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE;
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'today_completed', count(*) FILTER (
                WHERE status = 'COMPLETED'
                  AND (completed_at AT TIME ZONE 'Asia/Kolkata')::DATE = v_today),
            'week_completed', count(*) FILTER (
                WHERE status = 'COMPLETED'
                  AND completed_at > NOW() - INTERVAL '7 days'),
            'total_completed', count(*) FILTER (WHERE status = 'COMPLETED'),
            'rating', v_m.rating,
            'rating_count', count(rating)
        )
        FROM public.bookings
        WHERE mechanic_id = v_m.id
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_get_job_history(p_limit INT DEFAULT 30)
RETURNS TABLE (
    booking_id UUID, status TEXT, vehicle_type TEXT, issue_tags TEXT[],
    pickup_address TEXT, rating INT, review_text TEXT, cancelled_by TEXT,
    accepted_at TIMESTAMPTZ, completed_at TIMESTAMPTZ, cancelled_at TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    RETURN QUERY
    SELECT b.id, b.status, b.vehicle_type, b.issue_tags, b.pickup_address,
           b.rating, b.review_text, b.cancelled_by,
           b.accepted_at, b.completed_at, b.cancelled_at
      FROM public.bookings b
     WHERE b.mechanic_id = v_m.id
       AND b.status IN ('COMPLETED', 'CANCELLED')
     ORDER BY COALESCE(b.completed_at, b.cancelled_at, b.updated_at) DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. Permissions
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
    public._auth_phone(),
    public.mechanic_link_account(),
    public.mechanic_register(TEXT, TEXT, TEXT[]),
    public.mechanic_get_open_requests(INT),
    public.mechanic_accept_booking(UUID),
    public.mechanic_release_job(UUID, TEXT),
    public.mechanic_get_booking_status(UUID),
    public.mechanic_get_stats(),
    public.mechanic_get_job_history(INT)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.mechanic_link_account(),
    public.mechanic_register(TEXT, TEXT, TEXT[]),
    public.mechanic_get_open_requests(INT),
    public.mechanic_accept_booking(UUID),
    public.mechanic_release_job(UUID, TEXT),
    public.mechanic_get_booking_status(UUID),
    public.mechanic_get_stats(),
    public.mechanic_get_job_history(INT)
TO authenticated;

-- =============================================================================
-- DONE. Partner app: see mechanic_app/README.md
-- =============================================================================
