-- =============================================================================
-- 8SpeedyService — My Vehicles (brand + model) & Play Store account deletion
-- =============================================================================
-- Run AFTER migrations 000001 and 000002 (Supabase SQL Editor -> paste -> Run).
-- Idempotent and purely additive (no DROP statements): safe to re-run on live data.
--
-- Adds:
--   1. customer_vehicles table + customer_save_vehicle / customer_delete_vehicle
--   2. bookings.vehicle_id / vehicle_label / vehicle_body_type
--   3. create_booking_secure(..., p_vehicle_id)  — price taken from the saved
--      vehicle's category on the server
--   4. mechanic_get_open_requests_v2 / mechanic_get_job_history_v2 return the
--      vehicle name ("Honda Activa 6G • WB38AB1234"); old versions stay for old app builds
--   5. delete_account_data(uid) — used by the `delete-account` Edge Function
--      (Google Play requires in-app account deletion)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. CUSTOMER VEHICLES
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.customer_vehicles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    category TEXT NOT NULL
        CHECK (category IN ('cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle')),
    body_type TEXT NOT NULL CHECK (body_type ~ '^[a-z_]{2,30}$'),
    brand TEXT NOT NULL CHECK (length(brand) BETWEEN 1 AND 40),
    model TEXT NOT NULL CHECK (length(model) BETWEEN 1 AND 60),
    reg_number TEXT CHECK (reg_number IS NULL OR reg_number ~ '^[A-Z0-9]{4,12}$'),
    fuel_type TEXT CHECK (fuel_type IS NULL OR fuel_type IN ('PETROL', 'DIESEL', 'CNG', 'ELECTRIC', 'NONE')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_used_at TIMESTAMPTZ
);
-- Removed vehicles are soft-deleted (old bookings keep pointing at them).
ALTER TABLE public.customer_vehicles ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_customer_vehicles_owner
    ON public.customer_vehicles (customer_id, last_used_at DESC NULLS LAST);

ALTER TABLE public.customer_vehicles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_vehicles FROM anon, authenticated;
GRANT SELECT ON public.customer_vehicles TO authenticated;
GRANT ALL ON public.customer_vehicles TO service_role;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                   AND tablename = 'customer_vehicles' AND policyname = 'customer_vehicles_select_own') THEN
        CREATE POLICY customer_vehicles_select_own ON public.customer_vehicles
            FOR SELECT TO authenticated USING (customer_id = auth.uid() AND NOT is_deleted);
    ELSE
        ALTER POLICY customer_vehicles_select_own ON public.customer_vehicles
            USING (customer_id = auth.uid() AND NOT is_deleted);
    END IF;
END;
$$;

-- Body type (what the app shows) -> pricing category (what fees use).
CREATE OR REPLACE FUNCTION public.vehicle_category_for_body(p_body_type TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = public AS $$
    SELECT CASE p_body_type
        WHEN 'cycle'         THEN 'cycle_toto'
        WHEN 'e_rickshaw'    THEN 'cycle_toto'
        WHEN 'scooter'       THEN 'two_wheeler'
        WHEN 'motorcycle'    THEN 'two_wheeler'
        WHEN 'auto_rickshaw' THEN 'four_wheeler'
        WHEN 'hatchback'     THEN 'four_wheeler'
        WHEN 'sedan'         THEN 'four_wheeler'
        WHEN 'suv'           THEN 'four_wheeler'
        WHEN 'pickup'        THEN 'heavy_vehicle'
        WHEN 'truck'         THEN 'heavy_vehicle'
        ELSE NULL
    END;
$$;

-- Add or edit a saved vehicle. Pass p_vehicle_id to edit an existing one.
CREATE OR REPLACE FUNCTION public.customer_save_vehicle(
    p_body_type TEXT,
    p_brand TEXT,
    p_model TEXT,
    p_reg_number TEXT DEFAULT NULL,
    p_fuel_type TEXT DEFAULT NULL,
    p_vehicle_id UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_category TEXT := public.vehicle_category_for_body(p_body_type);
    v_brand TEXT := left(trim(COALESCE(p_brand, '')), 40);
    v_model TEXT := left(trim(COALESCE(p_model, '')), 60);
    v_reg TEXT := NULLIF(upper(regexp_replace(COALESCE(p_reg_number, ''), '[^A-Za-z0-9]', '', 'g')), '');
    v_fuel TEXT := NULLIF(upper(trim(COALESCE(p_fuel_type, ''))), '');
    v_row public.customer_vehicles%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = v_uid) THEN
        PERFORM public.ensure_customer_profile();
    END IF;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'Please select a valid vehicle type.';
    END IF;
    IF v_brand = '' OR v_model = '' THEN
        RAISE EXCEPTION 'Please select the brand and model of your vehicle.';
    END IF;
    IF v_reg IS NOT NULL AND v_reg !~ '^([A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{1,4}|[0-9]{2}BH[0-9]{4}[A-Z]{1,2})$' THEN
        RAISE EXCEPTION 'Please enter a valid vehicle number, e.g. WB 38 AB 1234.';
    END IF;
    IF v_fuel IS NOT NULL AND v_fuel NOT IN ('PETROL', 'DIESEL', 'CNG', 'ELECTRIC', 'NONE') THEN
        v_fuel := NULL;
    END IF;

    IF p_vehicle_id IS NULL THEN
        IF (SELECT count(*) FROM public.customer_vehicles
             WHERE customer_id = v_uid AND NOT is_deleted) >= 10 THEN
            RAISE EXCEPTION 'You can save up to 10 vehicles. Please remove an old one first.';
        END IF;
        INSERT INTO public.customer_vehicles (customer_id, category, body_type, brand, model, reg_number, fuel_type, last_used_at)
        VALUES (v_uid, v_category, p_body_type, v_brand, v_model, v_reg, v_fuel, NOW())
        RETURNING * INTO v_row;
    ELSE
        UPDATE public.customer_vehicles
           SET category = v_category, body_type = p_body_type, brand = v_brand,
               model = v_model, reg_number = v_reg, fuel_type = v_fuel
         WHERE id = p_vehicle_id AND customer_id = v_uid AND NOT is_deleted
        RETURNING * INTO v_row;
        IF v_row.id IS NULL THEN
            RAISE EXCEPTION 'Vehicle not found.';
        END IF;
    END IF;

    RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_vehicle(p_vehicle_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE public.customer_vehicles
       SET is_deleted = TRUE, last_used_at = NULL
     WHERE id = p_vehicle_id AND customer_id = auth.uid();
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. BOOKING VEHICLE SNAPSHOT (kept even if the saved vehicle is deleted)
-- -----------------------------------------------------------------------------

ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS vehicle_id UUID
    REFERENCES public.customer_vehicles(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS vehicle_label TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS vehicle_body_type TEXT;

-- -----------------------------------------------------------------------------
-- 3. create_booking_secure with p_vehicle_id
-- -----------------------------------------------------------------------------
-- New 7-argument overload. p_vehicle_id has NO default, so PostgREST picks this
-- one when the app sends p_vehicle_id and the old 6-argument one otherwise.

CREATE OR REPLACE FUNCTION public.create_booking_secure(
    p_vehicle_type TEXT,
    p_issue_tags TEXT[],
    p_issue_note TEXT,
    p_pickup_address TEXT,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_vehicle_id UUID
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_customer public.customers%ROWTYPE;
    v_cfg public.app_config%ROWTYPE;
    v_vehicle public.customer_vehicles%ROWTYPE;
    v_vehicle_type TEXT := p_vehicle_type;
    v_label TEXT;
    v_body TEXT;
    v_fee INT := 0;
    v_free BOOLEAN := FALSE;
    v_payment_status TEXT;
    v_payment_required BOOLEAN := FALSE;
    v_otp TEXT;
    v_booking_id UUID;
    v_recent INT;
    v_tags TEXT[];
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again to book a mechanic.' USING ERRCODE = '28000';
    END IF;

    -- Saved vehicle decides the pricing category (never trusted from the app).
    IF p_vehicle_id IS NOT NULL THEN
        SELECT * INTO v_vehicle FROM public.customer_vehicles
         WHERE id = p_vehicle_id AND customer_id = v_uid AND NOT is_deleted;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected vehicle not found. Please select your vehicle again.';
        END IF;
        v_vehicle_type := v_vehicle.category;
        v_body := v_vehicle.body_type;
        v_label := v_vehicle.brand || ' ' || v_vehicle.model
                   || COALESCE(' • ' || v_vehicle.reg_number, '');
    END IF;

    IF v_vehicle_type NOT IN ('cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle') THEN
        RAISE EXCEPTION 'Invalid vehicle type selected.';
    END IF;

    SELECT array_agg(DISTINCT left(trim(t), 40)) INTO v_tags
      FROM unnest(COALESCE(p_issue_tags, ARRAY[]::TEXT[])) AS t
     WHERE trim(t) <> '';
    IF v_tags IS NULL OR array_length(v_tags, 1) = 0 THEN
        RAISE EXCEPTION 'Please select at least one vehicle issue.';
    END IF;
    IF array_length(v_tags, 1) > 8 THEN
        RAISE EXCEPTION 'Too many issues selected.';
    END IF;

    IF p_pickup_address IS NULL OR length(trim(p_pickup_address)) < 3 THEN
        RAISE EXCEPTION 'Pickup address is missing. Please move the map pin and retry.';
    END IF;

    IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98 THEN
        RAISE EXCEPTION 'Pickup location is outside our service area.';
    END IF;

    SELECT * INTO v_customer FROM public.customers WHERE id = v_uid FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM public.ensure_customer_profile();
        SELECT * INTO v_customer FROM public.customers WHERE id = v_uid FOR UPDATE;
    END IF;
    IF v_customer.is_blocked THEN
        RAISE EXCEPTION 'Your account has been restricted. Please contact support.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.bookings
         WHERE customer_id = v_uid
           AND status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
           AND payment_status IN ('FREE_OFFER', 'PAID')
    ) THEN
        RAISE EXCEPTION 'You already have an active booking. Please finish or cancel it first.';
    END IF;

    SELECT count(*) INTO v_recent FROM public.bookings
     WHERE customer_id = v_uid AND created_at > NOW() - INTERVAL '15 minutes';
    IF v_recent >= 6 THEN
        RAISE EXCEPTION 'Too many booking attempts. Please wait a few minutes and retry.';
    END IF;

    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = NOW(), cancelled_by = 'SYSTEM_UNPAID'
     WHERE customer_id = v_uid AND status = 'SEARCHING' AND payment_status = 'PENDING';

    SELECT * INTO v_cfg FROM public.app_config WHERE id = 1;

    IF COALESCE(v_cfg.launch_offer_active, TRUE) AND v_customer.free_bookings_left > 0 THEN
        UPDATE public.customers SET free_bookings_left = free_bookings_left - 1 WHERE id = v_uid;
        v_fee := 0;
        v_free := TRUE;
        v_payment_status := 'FREE_OFFER';
    ELSE
        v_fee := COALESCE((v_cfg.fees_by_vehicle ->> v_vehicle_type)::INT,
                          CASE v_vehicle_type
                              WHEN 'cycle_toto' THEN 10
                              WHEN 'two_wheeler' THEN 15
                              WHEN 'four_wheeler' THEN 25
                              ELSE 40 END);
        IF v_fee > 0 THEN
            v_payment_status := 'PENDING';
            v_payment_required := TRUE;
        ELSE
            v_payment_status := 'FREE_OFFER';
        END IF;
    END IF;

    v_otp := lpad(((get_byte(gen_random_bytes(2), 0) * 256 + get_byte(gen_random_bytes(2), 1)) % 10000)::TEXT, 4, '0');

    INSERT INTO public.bookings (
        customer_id, vehicle_type, issue_tags, issue_note, pickup_address,
        pickup_lat, pickup_lng, status, start_otp, platform_fee,
        is_free_offer_used, payment_status, vehicle_id, vehicle_label, vehicle_body_type
    ) VALUES (
        v_uid, v_vehicle_type, v_tags, NULLIF(left(trim(COALESCE(p_issue_note, '')), 500), ''),
        left(trim(p_pickup_address), 300), p_lat, p_lng, 'SEARCHING', v_otp, v_fee,
        v_free, v_payment_status, v_vehicle.id, v_label, v_body
    ) RETURNING id INTO v_booking_id;

    IF v_vehicle.id IS NOT NULL THEN
        UPDATE public.customer_vehicles SET last_used_at = NOW() WHERE id = v_vehicle.id;
    END IF;

    RETURN jsonb_build_object(
        'booking_id', v_booking_id,
        'payment_required', v_payment_required,
        'otp', v_otp,
        'amount', v_fee,
        'vehicle_type', v_vehicle_type
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. MECHANIC RPCs — include the vehicle name
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mechanic_get_open_requests_v2(p_radius_meters INT DEFAULT 10000)
RETURNS TABLE (
    booking_id UUID, vehicle_type TEXT, issue_tags TEXT[], issue_note TEXT,
    pickup_address TEXT, pickup_lat DOUBLE PRECISION, pickup_lng DOUBLE PRECISION,
    distance_meters DOUBLE PRECISION, created_at TIMESTAMPTZ,
    vehicle_label TEXT, vehicle_body_type TEXT
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
           ST_Distance(b.pickup_location, v_m.current_location), b.created_at,
           -- Number plate is shown only after the mechanic accepts.
           split_part(b.vehicle_label, ' • ', 1), b.vehicle_body_type
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

CREATE OR REPLACE FUNCTION public.mechanic_get_active_job()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_job JSONB;
BEGIN
    SELECT jsonb_build_object(
               'booking_id', b.id, 'status', b.status, 'vehicle_type', b.vehicle_type,
               'vehicle_label', b.vehicle_label, 'vehicle_body_type', b.vehicle_body_type,
               'issue_tags', b.issue_tags, 'issue_note', b.issue_note,
               'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng,
               'customer_name', COALESCE(c.full_name, 'Customer'), 'customer_phone', c.phone,
               'min_visit_charge', (SELECT min_visit_charge FROM public.app_config WHERE id = 1)
           )   -- NOTE: start_otp is intentionally NOT returned to mechanics.
      INTO v_job
      FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
     WHERE b.mechanic_id = v_m.id AND b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
     ORDER BY b.accepted_at DESC NULLS LAST
     LIMIT 1;
    RETURN v_job;
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_get_job_history_v2(p_limit INT DEFAULT 30)
RETURNS TABLE (
    booking_id UUID, status TEXT, vehicle_type TEXT, issue_tags TEXT[],
    pickup_address TEXT, rating INT, review_text TEXT, cancelled_by TEXT,
    accepted_at TIMESTAMPTZ, completed_at TIMESTAMPTZ, cancelled_at TIMESTAMPTZ,
    vehicle_label TEXT, vehicle_body_type TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    RETURN QUERY
    SELECT b.id, b.status, b.vehicle_type, b.issue_tags, b.pickup_address,
           b.rating, b.review_text, b.cancelled_by,
           b.accepted_at, b.completed_at, b.cancelled_at,
           b.vehicle_label, b.vehicle_body_type
      FROM public.bookings b
     WHERE b.mechanic_id = v_m.id
       AND b.status IN ('COMPLETED', 'CANCELLED')
     ORDER BY COALESCE(b.completed_at, b.cancelled_at, b.updated_at) DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100);
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. ACCOUNT DELETION (called only by the `delete-account` Edge Function)
-- -----------------------------------------------------------------------------
-- Personal data is removed / anonymised. Booking rows are kept without the
-- person's identity (needed for payment & tax records). The Edge Function then
-- soft-deletes the auth user, which frees the phone number for a new signup.
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
    UPDATE public.bookings SET issue_note = NULL, review_text = NULL WHERE customer_id = p_uid;
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

-- -----------------------------------------------------------------------------
-- 6. EXTRA SAFETY: customers can edit only their name -> keep it sane
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'customers_full_name_len') THEN
        ALTER TABLE public.customers ADD CONSTRAINT customers_full_name_len
            CHECK (full_name IS NULL OR length(full_name) BETWEEN 1 AND 60) NOT VALID;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. PERMISSIONS
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
    public.vehicle_category_for_body(TEXT),
    public.customer_save_vehicle(TEXT, TEXT, TEXT, TEXT, TEXT, UUID),
    public.customer_delete_vehicle(UUID),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.mechanic_get_open_requests_v2(INT),
    public.mechanic_get_active_job(),
    public.mechanic_get_job_history_v2(INT),
    public.delete_account_data(UUID)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.vehicle_category_for_body(TEXT),
    public.customer_save_vehicle(TEXT, TEXT, TEXT, TEXT, TEXT, UUID),
    public.customer_delete_vehicle(UUID),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.mechanic_get_open_requests_v2(INT),
    public.mechanic_get_active_job(),
    public.mechanic_get_job_history_v2(INT)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.delete_account_data(UUID) TO service_role;

-- -----------------------------------------------------------------------------
-- 8. HARDENING (Supabase security advisor)
-- -----------------------------------------------------------------------------
ALTER FUNCTION public.tg_set_updated_at() SET search_path = public;
ALTER FUNCTION public.tg_sync_booking_geo() SET search_path = public, extensions;
ALTER FUNCTION public.tg_sync_mechanic_geo() SET search_path = public, extensions;
DO $$
BEGIN
    BEGIN
        REVOKE EXECUTE ON FUNCTION public.st_estimatedextent(text, text) FROM PUBLIC, anon, authenticated;
        REVOKE EXECUTE ON FUNCTION public.st_estimatedextent(text, text, text) FROM PUBLIC, anon, authenticated;
        REVOKE EXECUTE ON FUNCTION public.st_estimatedextent(text, text, text, boolean) FROM PUBLIC, anon, authenticated;
        REVOKE ALL ON public.spatial_ref_sys FROM anon, authenticated;
    EXCEPTION WHEN undefined_function OR undefined_table OR insufficient_privilege THEN
        RAISE NOTICE 'PostGIS hardening skipped: %', SQLERRM;
    END;
END;
$$;

-- Make the new functions visible to the app's API immediately.
NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- DONE. Next: deploy the `delete-account` Edge Function (see PRODUCTION_SETUP.md).
-- =============================================================================
