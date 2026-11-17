-- =============================================================================
-- 8SpeedyService — Complete Production Backend (Supabase / PostgreSQL + PostGIS)
-- =============================================================================
-- Run this ONCE in Supabase Dashboard -> SQL Editor (or `supabase db push`).
-- It is idempotent: safe to re-run, and safe to run even if you already
-- created the basic tables from the blueprint.
--
-- What this file sets up:
--   1. Tables (app_config, customers, mechanics, bookings) + extra safety columns
--   2. Auto customer profile creation on phone signup (5 free credits + referral code)
--   3. Row Level Security (RLS) — users can only see/modify their own data
--   4. Secure RPC functions — ALL writes go through server-side functions
--   5. Mechanic-side RPCs (for the future Mechanic Partner app)
--   6. Realtime publication for bookings & mechanics
--   7. Auto-expiry of stale bookings (pg_cron, every 5 minutes)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- 1. TABLES
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.app_config (
    id INT PRIMARY KEY DEFAULT 1,
    launch_offer_active BOOLEAN DEFAULT TRUE,
    default_free_credits INT DEFAULT 5,
    min_visit_charge INT DEFAULT 49,
    min_android_version TEXT DEFAULT '1.0.0',
    fees_by_vehicle JSONB DEFAULT '{
        "cycle_toto": 10,
        "two_wheeler": 15,
        "four_wheeler": 25,
        "heavy_vehicle": 40
    }'::jsonb,
    CONSTRAINT single_row CHECK (id = 1)
);

INSERT INTO public.app_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.customers (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    phone TEXT UNIQUE NOT NULL,
    full_name TEXT,
    free_bookings_left INT DEFAULT 5 CHECK (free_bookings_left >= 0),
    referral_code TEXT UNIQUE NOT NULL,
    referred_by TEXT,
    is_blocked BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS referral_rewarded BOOLEAN DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS public.mechanics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name TEXT NOT NULL,
    phone TEXT UNIQUE NOT NULL,
    shop_name TEXT,
    avatar_url TEXT,
    vehicle_specialties TEXT[] DEFAULT ARRAY['two_wheeler', 'four_wheeler'],
    is_verified BOOLEAN DEFAULT FALSE,
    is_online BOOLEAN DEFAULT FALSE,
    current_lat DOUBLE PRECISION,
    current_lng DOUBLE PRECISION,
    current_location GEOGRAPHY(Point, 4326),
    rating NUMERIC(2,1) DEFAULT 5.0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- Links a mechanic row to the auth account used in the Mechanic Partner app.
ALTER TABLE public.mechanics ADD COLUMN IF NOT EXISTS user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.mechanics ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW();

CREATE TABLE IF NOT EXISTS public.bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES public.customers(id),
    mechanic_id UUID REFERENCES public.mechanics(id),
    vehicle_type TEXT NOT NULL,
    issue_tags TEXT[] NOT NULL,
    issue_note TEXT,
    pickup_address TEXT NOT NULL,
    pickup_lat DOUBLE PRECISION NOT NULL,
    pickup_lng DOUBLE PRECISION NOT NULL,
    pickup_location GEOGRAPHY(Point, 4326),
    status TEXT NOT NULL DEFAULT 'SEARCHING'
        CHECK (status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
    start_otp TEXT NOT NULL,
    platform_fee INT NOT NULL DEFAULT 0,
    is_free_offer_used BOOLEAN DEFAULT FALSE,
    payment_status TEXT NOT NULL DEFAULT 'FREE_OFFER'
        CHECK (payment_status IN ('FREE_OFFER', 'PENDING', 'PAID')),
    razorpay_order_id TEXT,
    rating INT CHECK (rating >= 1 AND rating <= 5),
    review_text TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
-- Extra production columns (audit, refunds, OTP brute-force protection)
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS razorpay_payment_id TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS accepted_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS arrived_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS cancelled_by TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS credit_refunded BOOLEAN DEFAULT FALSE;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS refund_status TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS otp_attempts INT DEFAULT 0;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_bookings_customer ON public.bookings (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookings_mechanic ON public.bookings (mechanic_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON public.bookings (status, payment_status);
CREATE INDEX IF NOT EXISTS idx_bookings_pickup_geo ON public.bookings USING GIST (pickup_location);
CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_rzp_order ON public.bookings (razorpay_order_id) WHERE razorpay_order_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_rzp_payment ON public.bookings (razorpay_payment_id) WHERE razorpay_payment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mechanics_geo ON public.mechanics USING GIST (current_location);
CREATE INDEX IF NOT EXISTS idx_mechanics_online ON public.mechanics (is_online, is_verified);

-- -----------------------------------------------------------------------------
-- 2. GENERIC TRIGGERS (updated_at + geography sync)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.tg_sync_booking_geo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.pickup_location := ST_SetSRID(ST_MakePoint(NEW.pickup_lng, NEW.pickup_lat), 4326)::geography;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.tg_sync_mechanic_geo()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_lat IS NOT NULL AND NEW.current_lng IS NOT NULL THEN
        NEW.current_location := ST_SetSRID(ST_MakePoint(NEW.current_lng, NEW.current_lat), 4326)::geography;
    ELSE
        NEW.current_location := NULL;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bookings_updated_at ON public.bookings;
CREATE TRIGGER trg_bookings_updated_at BEFORE UPDATE ON public.bookings
    FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_bookings_geo ON public.bookings;
CREATE TRIGGER trg_bookings_geo BEFORE INSERT OR UPDATE OF pickup_lat, pickup_lng ON public.bookings
    FOR EACH ROW EXECUTE FUNCTION public.tg_sync_booking_geo();

DROP TRIGGER IF EXISTS trg_mechanics_updated_at ON public.mechanics;
CREATE TRIGGER trg_mechanics_updated_at BEFORE UPDATE ON public.mechanics
    FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

DROP TRIGGER IF EXISTS trg_mechanics_geo ON public.mechanics;
CREATE TRIGGER trg_mechanics_geo BEFORE INSERT OR UPDATE OF current_lat, current_lng ON public.mechanics
    FOR EACH ROW EXECUTE FUNCTION public.tg_sync_mechanic_geo();

-- -----------------------------------------------------------------------------
-- 3. AUTO-CREATE CUSTOMER PROFILE ON PHONE SIGNUP
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.generate_referral_code()
RETURNS TEXT LANGUAGE plpgsql SET search_path = public, extensions AS $$
DECLARE
    v_code TEXT;
    v_alphabet CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    i INT;
BEGIN
    LOOP
        v_code := '8SP';
        FOR i IN 1..6 LOOP
            v_code := v_code || substr(v_alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % length(v_alphabet)), 1);
        END LOOP;
        EXIT WHEN NOT EXISTS (SELECT 1 FROM public.customers WHERE referral_code = v_code);
    END LOOP;
    RETURN v_code;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_cfg public.app_config%ROWTYPE;
    v_phone TEXT;
BEGIN
    -- Only phone-based signups are customers (mechanic app may use other auth).
    IF NEW.phone IS NULL OR NEW.phone = '' THEN
        RETURN NEW;
    END IF;

    v_phone := CASE WHEN left(NEW.phone, 1) = '+' THEN NEW.phone ELSE '+' || NEW.phone END;

    -- Phone already registered as mechanic -> do not create customer row.
    IF EXISTS (SELECT 1 FROM public.mechanics m WHERE m.phone = v_phone OR m.user_id = NEW.id) THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_cfg FROM public.app_config WHERE id = 1;

    INSERT INTO public.customers (id, phone, free_bookings_left, referral_code)
    VALUES (
        NEW.id,
        v_phone,
        CASE WHEN COALESCE(v_cfg.launch_offer_active, TRUE) THEN COALESCE(v_cfg.default_free_credits, 5) ELSE 0 END,
        public.generate_referral_code()
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
EXCEPTION WHEN unique_violation THEN
    -- Same phone re-created under a new auth id (e.g. account deleted & re-registered):
    -- never block signup. Profile will be re-linked by ensure_customer_profile().
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

-- Safety net called by the app after login: creates the profile if the trigger
-- was skipped (e.g. users created before this migration was installed).
CREATE OR REPLACE FUNCTION public.ensure_customer_profile()
RETURNS public.customers LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_phone TEXT;
    v_cfg public.app_config%ROWTYPE;
    v_row public.customers%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO v_row FROM public.customers WHERE id = v_uid;
    IF FOUND THEN
        RETURN v_row;
    END IF;

    SELECT CASE WHEN left(u.phone, 1) = '+' THEN u.phone ELSE '+' || u.phone END
      INTO v_phone FROM auth.users u WHERE u.id = v_uid;

    IF v_phone IS NULL OR v_phone = '+' THEN
        RAISE EXCEPTION 'Phone number not found for this account.';
    END IF;

    SELECT * INTO v_cfg FROM public.app_config WHERE id = 1;

    -- If an old orphan row holds this phone (deleted auth user), free the phone.
    UPDATE public.customers SET phone = phone || '-old-' || substr(id::text, 1, 8)
     WHERE phone = v_phone AND id <> v_uid;

    INSERT INTO public.customers (id, phone, free_bookings_left, referral_code)
    VALUES (
        v_uid, v_phone,
        CASE WHEN COALESCE(v_cfg.launch_offer_active, TRUE) THEN COALESCE(v_cfg.default_free_credits, 5) ELSE 0 END,
        public.generate_referral_code()
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING * INTO v_row;

    IF v_row.id IS NULL THEN
        SELECT * INTO v_row FROM public.customers WHERE id = v_uid;
    END IF;
    RETURN v_row;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. SECURITY HELPERS (SECURITY DEFINER avoids RLS recursion)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.current_mechanic_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT id FROM public.mechanics WHERE user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.customer_can_view_mechanic(p_mechanic_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.bookings b
         WHERE b.mechanic_id = p_mechanic_id
           AND b.customer_id = auth.uid()
           AND (
                b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
                OR (b.status = 'COMPLETED' AND b.updated_at > NOW() - INTERVAL '1 day')
           )
    );
$$;

-- -----------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- -----------------------------------------------------------------------------
-- Rule of thumb: the app can READ its own rows; every WRITE goes through a
-- SECURITY DEFINER RPC below, which validates business rules on the server.

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mechanics  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bookings   ENABLE ROW LEVEL SECURITY;

-- Lock down table privileges first (RLS + privileges = defense in depth)
REVOKE ALL ON public.app_config, public.customers, public.mechanics, public.bookings FROM anon, authenticated;
GRANT SELECT ON public.app_config TO anon, authenticated;
GRANT SELECT ON public.customers, public.mechanics, public.bookings TO authenticated;
-- Customers may only edit their own display name directly.
GRANT UPDATE (full_name) ON public.customers TO authenticated;
GRANT ALL ON public.app_config, public.customers, public.mechanics, public.bookings TO service_role;

-- app_config: readable by everyone (needed before login for fees display)
DROP POLICY IF EXISTS app_config_read ON public.app_config;
CREATE POLICY app_config_read ON public.app_config FOR SELECT TO anon, authenticated USING (TRUE);

-- customers: own row only
DROP POLICY IF EXISTS customers_select_own ON public.customers;
CREATE POLICY customers_select_own ON public.customers FOR SELECT TO authenticated
    USING (id = auth.uid());
DROP POLICY IF EXISTS customers_update_own ON public.customers;
CREATE POLICY customers_update_own ON public.customers FOR UPDATE TO authenticated
    USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- mechanics: a customer sees only the mechanic assigned to their active booking;
-- a mechanic sees their own row. (Nearby pins come via get_nearby_mechanics RPC.)
DROP POLICY IF EXISTS mechanics_select_assigned ON public.mechanics;
CREATE POLICY mechanics_select_assigned ON public.mechanics FOR SELECT TO authenticated
    USING (public.customer_can_view_mechanic(id) OR user_id = auth.uid());

-- bookings: customers see their own bookings only. Mechanics never read this
-- table directly (they would see the start OTP) — they use mechanic_* RPCs.
DROP POLICY IF EXISTS bookings_select_own ON public.bookings;
CREATE POLICY bookings_select_own ON public.bookings FOR SELECT TO authenticated
    USING (customer_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 6. CUSTOMER RPC FUNCTIONS
-- -----------------------------------------------------------------------------

-- 6.1 create_booking_secure — the ONLY way to create a booking.
CREATE OR REPLACE FUNCTION public.create_booking_secure(
    p_vehicle_type TEXT,
    p_issue_tags TEXT[],
    p_issue_note TEXT,
    p_pickup_address TEXT,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_customer public.customers%ROWTYPE;
    v_cfg public.app_config%ROWTYPE;
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

    -- Input validation
    IF p_vehicle_type NOT IN ('cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle') THEN
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

    -- India bounding box sanity check (prevents garbage / spoofed coordinates)
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98 THEN
        RAISE EXCEPTION 'Pickup location is outside our service area.';
    END IF;

    -- Lock the customer row so two taps can't spend the same free credit twice.
    SELECT * INTO v_customer FROM public.customers WHERE id = v_uid FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM public.ensure_customer_profile();
        SELECT * INTO v_customer FROM public.customers WHERE id = v_uid FOR UPDATE;
    END IF;
    IF v_customer.is_blocked THEN
        RAISE EXCEPTION 'Your account has been restricted. Please contact support.';
    END IF;

    -- Only one live (free/paid) booking at a time.
    IF EXISTS (
        SELECT 1 FROM public.bookings
         WHERE customer_id = v_uid
           AND status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
           AND payment_status IN ('FREE_OFFER', 'PAID')
    ) THEN
        RAISE EXCEPTION 'You already have an active booking. Please finish or cancel it first.';
    END IF;

    -- Abuse protection: max 6 booking attempts per 15 minutes.
    SELECT count(*) INTO v_recent FROM public.bookings
     WHERE customer_id = v_uid AND created_at > NOW() - INTERVAL '15 minutes';
    IF v_recent >= 6 THEN
        RAISE EXCEPTION 'Too many booking attempts. Please wait a few minutes and retry.';
    END IF;

    -- Abandon older unpaid attempts (user went back from payment screen).
    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = NOW(), cancelled_by = 'SYSTEM_UNPAID'
     WHERE customer_id = v_uid AND status = 'SEARCHING' AND payment_status = 'PENDING';

    SELECT * INTO v_cfg FROM public.app_config WHERE id = 1;

    IF COALESCE(v_cfg.launch_offer_active, TRUE) AND v_customer.free_bookings_left > 0 THEN
        UPDATE public.customers SET free_bookings_left = free_bookings_left - 1 WHERE id = v_uid;
        v_fee := 0;
        v_free := TRUE;
        v_payment_status := 'FREE_OFFER';
        v_payment_required := FALSE;
    ELSE
        v_fee := COALESCE((v_cfg.fees_by_vehicle ->> p_vehicle_type)::INT,
                          CASE p_vehicle_type
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

    -- Cryptographically random 4-digit OTP
    v_otp := lpad(((get_byte(gen_random_bytes(2), 0) * 256 + get_byte(gen_random_bytes(2), 1)) % 10000)::TEXT, 4, '0');

    INSERT INTO public.bookings (
        customer_id, vehicle_type, issue_tags, issue_note, pickup_address,
        pickup_lat, pickup_lng, status, start_otp, platform_fee,
        is_free_offer_used, payment_status
    ) VALUES (
        v_uid, p_vehicle_type, v_tags, NULLIF(left(trim(COALESCE(p_issue_note, '')), 500), ''),
        left(trim(p_pickup_address), 300), p_lat, p_lng, 'SEARCHING', v_otp, v_fee,
        v_free, v_payment_status
    ) RETURNING id INTO v_booking_id;

    RETURN jsonb_build_object(
        'booking_id', v_booking_id,
        'payment_required', v_payment_required,
        'otp', v_otp,
        'amount', v_fee
    );
END;
$$;

-- 6.2 get_nearby_mechanics — pins on the radar map (no phone numbers exposed).
DROP FUNCTION IF EXISTS public.get_nearby_mechanics(DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT);
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
    v_point GEOGRAPHY := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;

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

-- 6.3 cancel_booking — refunds the free credit when cancelled before acceptance.
CREATE OR REPLACE FUNCTION public.cancel_booking(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_refund_credit BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_b FROM public.bookings
     WHERE id = p_booking_id AND customer_id = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;

    IF v_b.status = 'CANCELLED' THEN
        RETURN jsonb_build_object('cancelled', TRUE, 'credit_refunded', v_b.credit_refunded);
    END IF;

    IF v_b.status NOT IN ('SEARCHING', 'ACCEPTED') THEN
        RAISE EXCEPTION 'Mechanic has already reached. Please contact support to cancel.';
    END IF;

    IF v_b.status = 'SEARCHING' AND v_b.is_free_offer_used AND NOT COALESCE(v_b.credit_refunded, FALSE) THEN
        UPDATE public.customers SET free_bookings_left = free_bookings_left + 1 WHERE id = v_b.customer_id;
        v_refund_credit := TRUE;
    END IF;

    UPDATE public.bookings
       SET status = 'CANCELLED',
           cancelled_at = NOW(),
           cancelled_by = 'CUSTOMER',
           credit_refunded = COALESCE(credit_refunded, FALSE) OR v_refund_credit,
           refund_status = CASE WHEN v_b.status = 'SEARCHING' AND v_b.payment_status = 'PAID'
                                THEN 'REQUESTED' ELSE refund_status END
     WHERE id = p_booking_id;

    RETURN jsonb_build_object('cancelled', TRUE, 'credit_refunded', v_refund_credit);
END;
$$;

-- 6.4 submit_booking_review — once per completed booking; updates mechanic rating.
CREATE OR REPLACE FUNCTION public.submit_booking_review(
    p_booking_id UUID,
    p_rating INT,
    p_review_text TEXT
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
BEGIN
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Please select a 1 to 5 star rating.';
    END IF;

    SELECT * INTO v_b FROM public.bookings
     WHERE id = p_booking_id AND customer_id = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    IF v_b.status <> 'COMPLETED' THEN
        RAISE EXCEPTION 'You can rate only after the job is completed.';
    END IF;
    IF v_b.rating IS NOT NULL THEN
        RAISE EXCEPTION 'You have already rated this booking.';
    END IF;

    UPDATE public.bookings
       SET rating = p_rating,
           review_text = NULLIF(left(trim(COALESCE(p_review_text, '')), 500), '')
     WHERE id = p_booking_id;

    IF v_b.mechanic_id IS NOT NULL THEN
        UPDATE public.mechanics m
           SET rating = sub.avg_rating
          FROM (
              SELECT round(avg(rating)::numeric, 1) AS avg_rating
                FROM public.bookings
               WHERE mechanic_id = v_b.mechanic_id AND rating IS NOT NULL
          ) sub
         WHERE m.id = v_b.mechanic_id AND sub.avg_rating IS NOT NULL;
    END IF;
END;
$$;

-- 6.5 apply_referral_code — new users only (before their first booking).
-- Reward: the referrer gets +1 free credit when the friend's first job completes.
CREATE OR REPLACE FUNCTION public.apply_referral_code(p_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_me public.customers%ROWTYPE;
    v_code TEXT := upper(trim(COALESCE(p_code, '')));
BEGIN
    SELECT * INTO v_me FROM public.customers WHERE id = v_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Please login again.';
    END IF;
    IF v_me.referred_by IS NOT NULL THEN
        RAISE EXCEPTION 'A referral code is already applied to your account.';
    END IF;
    IF v_code = '' OR v_code = v_me.referral_code THEN
        RAISE EXCEPTION 'Please enter a valid friend''s referral code.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.bookings WHERE customer_id = v_uid AND payment_status IN ('FREE_OFFER', 'PAID')) THEN
        RAISE EXCEPTION 'Referral codes can be applied only before your first booking.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE referral_code = v_code) THEN
        RAISE EXCEPTION 'This referral code does not exist.';
    END IF;

    UPDATE public.customers SET referred_by = v_code WHERE id = v_uid;
    RETURN jsonb_build_object('applied', TRUE, 'referral_code', v_code);
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. PAYMENT (called ONLY by Edge Functions with the service_role key)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mark_booking_paid(
    p_booking_id UUID,
    p_order_id TEXT,
    p_payment_id TEXT
)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    IF v_b.razorpay_order_id IS DISTINCT FROM p_order_id THEN
        RAISE EXCEPTION 'Order mismatch for this booking.';
    END IF;
    IF v_b.payment_status = 'PAID' THEN
        RETURN TRUE; -- idempotent (verify + webhook may both arrive)
    END IF;

    UPDATE public.bookings
       SET payment_status = 'PAID',
           razorpay_payment_id = p_payment_id,
           paid_at = NOW(),
           -- If the unpaid booking had been auto-cancelled while user was paying,
           -- revive it into search (money received = service owed).
           status = CASE WHEN status = 'CANCELLED' AND cancelled_by = 'SYSTEM_UNPAID' AND mechanic_id IS NULL
                         THEN 'SEARCHING' ELSE status END,
           cancelled_at = CASE WHEN status = 'CANCELLED' AND cancelled_by = 'SYSTEM_UNPAID' THEN NULL ELSE cancelled_at END,
           cancelled_by = CASE WHEN status = 'CANCELLED' AND cancelled_by = 'SYSTEM_UNPAID' THEN NULL ELSE cancelled_by END
     WHERE id = p_booking_id;
    RETURN TRUE;
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. MECHANIC PARTNER APP RPCs (for the separate mechanic app)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._require_mechanic()
RETURNS public.mechanics LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE;
BEGIN
    SELECT * INTO v_m FROM public.mechanics WHERE user_id = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mechanic account not found.' USING ERRCODE = '28000';
    END IF;
    IF NOT v_m.is_verified THEN
        RAISE EXCEPTION 'Your mechanic account is not verified yet.';
    END IF;
    RETURN v_m;
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_set_status(
    p_is_online BOOLEAN,
    p_lat DOUBLE PRECISION DEFAULT NULL,
    p_lng DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    UPDATE public.mechanics
       SET is_online = COALESCE(p_is_online, is_online),
           current_lat = COALESCE(p_lat, current_lat),
           current_lng = COALESCE(p_lng, current_lng)
     WHERE id = v_m.id;
END;
$$;

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
       AND ST_DWithin(b.pickup_location, v_m.current_location, LEAST(GREATEST(p_radius_meters, 500), 15000))
     ORDER BY b.created_at ASC
     LIMIT 20;
END;
$$;

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
       AND payment_status IN ('FREE_OFFER', 'PAID');
    GET DIAGNOSTICS v_updated = ROW_COUNT;

    IF v_updated = 0 THEN
        RAISE EXCEPTION 'This request was already taken or cancelled.';
    END IF;
    RETURN public.mechanic_get_active_job();
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

CREATE OR REPLACE FUNCTION public.mechanic_mark_arrived(p_booking_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    UPDATE public.bookings SET status = 'ARRIVED', arrived_at = NOW()
     WHERE id = p_booking_id AND mechanic_id = v_m.id AND status = 'ACCEPTED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking is not in ACCEPTED state.';
    END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.mechanic_start_job(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.mechanic_start_job(p_booking_id UUID, p_otp TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_b public.bookings%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM public.bookings
     WHERE id = p_booking_id AND mechanic_id = v_m.id FOR UPDATE;
    IF NOT FOUND OR v_b.status NOT IN ('ACCEPTED', 'ARRIVED') THEN
        RAISE EXCEPTION 'Booking is not ready to start.';
    END IF;
    IF COALESCE(v_b.otp_attempts, 0) >= 5 THEN
        RAISE EXCEPTION 'Too many wrong OTP attempts. Contact support.';
    END IF;
    IF trim(COALESCE(p_otp, '')) <> v_b.start_otp THEN
        -- Return (not raise) so the attempt counter is actually saved.
        UPDATE public.bookings SET otp_attempts = COALESCE(otp_attempts, 0) + 1 WHERE id = p_booking_id;
        RETURN jsonb_build_object('started', FALSE,
                                  'message', 'Wrong OTP. Please ask the customer again.',
                                  'attempts_left', 4 - COALESCE(v_b.otp_attempts, 0));
    END IF;
    UPDATE public.bookings
       SET status = 'IN_PROGRESS', started_at = NOW(),
           arrived_at = COALESCE(arrived_at, NOW())
     WHERE id = p_booking_id;
    RETURN jsonb_build_object('started', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_complete_job(p_booking_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_b public.bookings%ROWTYPE;
    v_c public.customers%ROWTYPE;
BEGIN
    UPDATE public.bookings SET status = 'COMPLETED', completed_at = NOW()
     WHERE id = p_booking_id AND mechanic_id = v_m.id AND status = 'IN_PROGRESS'
    RETURNING * INTO v_b;
    IF v_b.id IS NULL THEN
        RAISE EXCEPTION 'Job must be IN_PROGRESS (OTP verified) before completing.';
    END IF;

    -- Referral reward: friend's first completed job -> referrer gets +1 free credit.
    SELECT * INTO v_c FROM public.customers WHERE id = v_b.customer_id FOR UPDATE;
    IF v_c.referred_by IS NOT NULL AND NOT COALESCE(v_c.referral_rewarded, FALSE) THEN
        UPDATE public.customers SET free_bookings_left = free_bookings_left + 1
         WHERE referral_code = v_c.referred_by AND id <> v_c.id;
        UPDATE public.customers SET referral_rewarded = TRUE WHERE id = v_c.id;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. AUTO-EXPIRE STALE BOOKINGS (runs every 5 min via pg_cron)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.expire_stale_bookings()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_count INT := 0;
    v_n INT;
BEGIN
    -- Unpaid attempts older than 30 minutes
    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = NOW(), cancelled_by = 'SYSTEM_UNPAID'
     WHERE status = 'SEARCHING' AND payment_status = 'PENDING'
       AND created_at < NOW() - INTERVAL '30 minutes';
    GET DIAGNOSTICS v_n = ROW_COUNT; v_count := v_count + v_n;

    -- No mechanic found within 30 minutes -> refund credit / flag refund
    WITH expired AS (
        UPDATE public.bookings
           SET status = 'CANCELLED', cancelled_at = NOW(), cancelled_by = 'SYSTEM_NO_MECHANIC',
               credit_refunded = is_free_offer_used,
               refund_status = CASE WHEN payment_status = 'PAID' THEN 'REQUESTED' ELSE refund_status END
         WHERE status = 'SEARCHING' AND mechanic_id IS NULL
           AND payment_status IN ('FREE_OFFER', 'PAID')
           AND created_at < NOW() - INTERVAL '30 minutes'
        RETURNING customer_id, is_free_offer_used
    )
    UPDATE public.customers c
       SET free_bookings_left = c.free_bookings_left + e.cnt
      FROM (SELECT customer_id, count(*)::INT AS cnt FROM expired WHERE is_free_offer_used GROUP BY customer_id) e
     WHERE c.id = e.customer_id;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_count := v_count + v_n;

    -- Mechanics whose app stopped sending location for 30 min -> offline
    UPDATE public.mechanics SET is_online = FALSE
     WHERE is_online = TRUE AND updated_at < NOW() - INTERVAL '30 minutes'
       AND NOT EXISTS (SELECT 1 FROM public.bookings b WHERE b.mechanic_id = mechanics.id
                       AND b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS'));
    RETURN v_count;
END;
$$;

DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'expire-stale-bookings';
    PERFORM cron.schedule('expire-stale-bookings', '*/5 * * * *', 'SELECT public.expire_stale_bookings();');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available (%). Enable it in Dashboard -> Database -> Extensions and re-run this block.', SQLERRM;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------
-- Postgres/Supabase grant EXECUTE to everyone by default — revoke, then grant precisely.
REVOKE EXECUTE ON FUNCTION
    public.generate_referral_code(),
    public.handle_new_auth_user(),
    public.ensure_customer_profile(),
    public.current_mechanic_id(),
    public.customer_can_view_mechanic(UUID),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
    public.get_nearby_mechanics(DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT),
    public.cancel_booking(UUID),
    public.submit_booking_review(UUID, INT, TEXT),
    public.apply_referral_code(TEXT),
    public.mark_booking_paid(UUID, TEXT, TEXT),
    public._require_mechanic(),
    public.mechanic_set_status(BOOLEAN, DOUBLE PRECISION, DOUBLE PRECISION),
    public.mechanic_get_open_requests(INT),
    public.mechanic_accept_booking(UUID),
    public.mechanic_get_active_job(),
    public.mechanic_mark_arrived(UUID),
    public.mechanic_start_job(UUID, TEXT),
    public.mechanic_complete_job(UUID),
    public.expire_stale_bookings()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.ensure_customer_profile(),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
    public.get_nearby_mechanics(DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT),
    public.cancel_booking(UUID),
    public.submit_booking_review(UUID, INT, TEXT),
    public.apply_referral_code(TEXT),
    public.mechanic_set_status(BOOLEAN, DOUBLE PRECISION, DOUBLE PRECISION),
    public.mechanic_get_open_requests(INT),
    public.mechanic_accept_booking(UUID),
    public.mechanic_get_active_job(),
    public.mechanic_mark_arrived(UUID),
    public.mechanic_start_job(UUID, TEXT),
    public.mechanic_complete_job(UUID),
    public.current_mechanic_id(),
    public.customer_can_view_mechanic(UUID)
TO authenticated;

-- Payment confirmation & cron: server (Edge Functions / pg_cron) only.
GRANT EXECUTE ON FUNCTION public.mark_booking_paid(UUID, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_stale_bookings() TO service_role;

-- -----------------------------------------------------------------------------
-- 11. REALTIME
-- -----------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        CREATE PUBLICATION supabase_realtime;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                   WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'bookings') THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.bookings;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                   WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'mechanics') THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.mechanics;
    END IF;
END;
$$;

-- =============================================================================
-- DONE. Next: deploy the Razorpay Edge Functions (see PRODUCTION_SETUP.md).
-- =============================================================================
