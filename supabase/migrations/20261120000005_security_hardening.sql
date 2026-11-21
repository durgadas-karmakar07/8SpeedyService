-- =============================================================================
-- 8SpeedyService — Migration 000005: security hardening (20 Nov 2026 audit)
-- -----------------------------------------------------------------------------
-- Fixes found while trying to "hack" the backend with the app's public key:
--
--  [HIGH]   public.spatial_ref_sys (PostGIS) was writable by anon/authenticated
--           (DELETE/UPDATE/INSERT/TRUNCATE granted by supabase_admin, no RLS).
--           Anyone with the APK key could wipe it -> every distance query fails
--           -> both apps stop working. Blocked with write-guard triggers
--           (the grants themselves belong to supabase_admin).
--  [MEDIUM] Start-OTP guessing: a mechanic could try 4 OTPs, release the job,
--           and the next mechanic got 5 fresh tries on the SAME OTP.
--           -> A new OTP is generated whenever a job is released.
--  [MEDIUM] Mechanic location spoofing / garbage coordinates were accepted.
--           -> Coordinates must be inside India and come as a pair.
--  [MEDIUM] A past customer could keep watching the mechanic's LIVE location
--           for 24 h after the job. -> Visible only while the job is active
--           and for 2 h after completion (enough to rate).
--  [LOW]    Helper current_mechanic_id() callable through the REST API.
--  [LOW]    get_nearby_mechanics accepted any coordinates (map scraping).
--  [PRIVACY] Account deletion now also unlinks voice notes (files are removed
--           by the delete-account Edge Function).
-- Safe to run more than once.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 1. [HIGH] spatial_ref_sys: block writes coming from the API roles
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.block_api_writes()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF current_user IN ('anon', 'authenticated') THEN
        RAISE EXCEPTION 'This table is read-only.' USING ERRCODE = '42501';
    END IF;
    IF TG_LEVEL = 'STATEMENT' THEN
        RETURN NULL;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;
REVOKE ALL ON FUNCTION private.block_api_writes() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zz_block_api_writes ON public.spatial_ref_sys;
CREATE TRIGGER zz_block_api_writes
    BEFORE INSERT OR UPDATE OR DELETE ON public.spatial_ref_sys
    FOR EACH ROW EXECUTE FUNCTION private.block_api_writes();

DROP TRIGGER IF EXISTS zz_block_api_truncate ON public.spatial_ref_sys;
CREATE TRIGGER zz_block_api_truncate
    BEFORE TRUNCATE ON public.spatial_ref_sys
    FOR EACH STATEMENT EXECUTE FUNCTION private.block_api_writes();

-- -----------------------------------------------------------------------------
-- 2. [MEDIUM] New start OTP whenever a mechanic releases a job
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_release_job(p_booking_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_bytes BYTEA := gen_random_bytes(2);
BEGIN
    UPDATE public.bookings
       SET status = 'SEARCHING',
           mechanic_id = NULL,
           accepted_at = NULL,
           arrived_at = NULL,
           otp_attempts = 0,
           -- Earlier wrong guesses are worthless for the next mechanic.
           start_otp = lpad(((get_byte(v_bytes, 0) * 256 + get_byte(v_bytes, 1)) % 10000)::TEXT, 4, '0'),
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
-- 3. [MEDIUM] Validate mechanic coordinates
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_set_status(
    p_is_online BOOLEAN,
    p_lat DOUBLE PRECISION DEFAULT NULL,
    p_lng DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    IF (p_lat IS NULL) <> (p_lng IS NULL) THEN
        RAISE EXCEPTION 'Location must include latitude and longitude.';
    END IF;
    IF p_lat IS NOT NULL AND (p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98) THEN
        RAISE EXCEPTION 'Your location is outside our service area.';
    END IF;
    UPDATE public.mechanics
       SET is_online = COALESCE(p_is_online, is_online),
           current_lat = COALESCE(p_lat, current_lat),
           current_lng = COALESCE(p_lng, current_lng)
     WHERE id = v_m.id;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. [MEDIUM] Mechanic row (incl. live location) visible to the customer only
--    during the job and for 2 hours after completion.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_can_view_mechanic(p_mechanic_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.bookings b
         WHERE b.mechanic_id = p_mechanic_id
           AND b.customer_id = auth.uid()
           AND (
                b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
                OR (b.status = 'COMPLETED' AND COALESCE(b.completed_at, b.updated_at) > NOW() - INTERVAL '2 hours')
           )
    );
$$;

-- -----------------------------------------------------------------------------
-- 5. [LOW] get_nearby_mechanics: only real coordinates
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_nearby_mechanics(
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_radius_meters INT,
    p_vehicle_type TEXT
)
RETURNS TABLE (
    mechanic_id UUID,
    full_name TEXT,
    distance_meters DOUBLE PRECISION,
    lat DOUBLE PRECISION,
    lng DOUBLE PRECISION
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_radius INT := LEAST(GREATEST(COALESCE(p_radius_meters, 3000), 500), 15000);
    v_point GEOGRAPHY;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98 THEN
        RETURN;
    END IF;
    v_point := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;

    RETURN QUERY
    SELECT m.id,
           split_part(m.full_name, ' ', 1),           -- first name only on the radar
           ST_Distance(m.current_location, v_point),
           round(m.current_lat::numeric, 3)::DOUBLE PRECISION,  -- ~100 m privacy blur
           round(m.current_lng::numeric, 3)::DOUBLE PRECISION
      FROM public.mechanics m
     WHERE m.is_verified = TRUE
       AND m.is_online = TRUE
       AND m.current_location IS NOT NULL
       AND m.updated_at > NOW() - INTERVAL '20 minutes'
       AND (p_vehicle_type IS NULL OR p_vehicle_type = ANY (m.vehicle_specialties))
       AND ST_DWithin(m.current_location, v_point, v_radius)
     ORDER BY ST_Distance(m.current_location, v_point)
     LIMIT 30;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. [LOW] Internal helper not callable through the REST API
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.current_mechanic_id() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 7. [PRIVACY] Account deletion unlinks voice notes too
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_account_data(p_uid UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_mech public.mechanics%ROWTYPE;
BEGIN
    IF p_uid IS NULL THEN
        RAISE EXCEPTION 'Missing user.';
    END IF;

    SELECT * INTO v_mech FROM public.mechanics WHERE user_id = p_uid;

    IF v_mech.id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.bookings WHERE mechanic_id = v_mech.id
           AND status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')) THEN
        RAISE EXCEPTION 'Please finish your current job before deleting the account.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.bookings WHERE customer_id = p_uid
           AND status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
           AND payment_status IN ('FREE_OFFER', 'PAID')) THEN
        RAISE EXCEPTION 'A mechanic is on the way. Please finish or cancel the booking first.';
    END IF;

    -- Bookings still searching are cancelled (paid ones flagged for refund).
    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = NOW(), cancelled_by = 'ACCOUNT_DELETED',
           refund_status = CASE WHEN payment_status = 'PAID' THEN 'REQUESTED' ELSE refund_status END
     WHERE customer_id = p_uid AND status = 'SEARCHING';

    -- Customer profile -> anonymous
    UPDATE public.customer_vehicles
       SET is_deleted = TRUE, reg_number = NULL
     WHERE customer_id = p_uid;
    UPDATE public.bookings
       SET issue_note = NULL, review_text = NULL,
           voice_note_path = NULL, voice_note_seconds = NULL
     WHERE customer_id = p_uid;
    UPDATE public.customers
       SET phone = 'deleted-' || id::TEXT,
           full_name = NULL,
           free_bookings_left = 0,
           is_blocked = TRUE
     WHERE id = p_uid;

    -- Mechanic profile -> anonymous, unlinked, offline
    IF v_mech.id IS NOT NULL THEN
        UPDATE public.mechanics
           SET user_id = NULL,
               full_name = 'Deleted Partner',
               phone = 'deleted-' || id::TEXT,
               shop_name = NULL,
               avatar_url = NULL,
               is_online = FALSE,
               is_verified = FALSE,
               current_lat = NULL,
               current_lng = NULL
         WHERE id = v_mech.id;
    END IF;

    RETURN jsonb_build_object('deleted', TRUE);
END;
$$;
