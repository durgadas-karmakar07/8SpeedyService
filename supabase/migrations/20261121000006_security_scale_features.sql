-- =============================================================================
-- 8SpeedyService — Migration 000006: audit #2 fixes, 1M-user scale, new features
-- -----------------------------------------------------------------------------
-- 21 Nov 2026. A second self pen-test (14 attack families, see
-- SECURITY_AUDIT.md) found these problems, all fixed here:
--
--  [HIGH]   Mechanic exact GPS recoverable (≈1 m) by trilateration of the
--           exact `distance_meters` returned by get_nearby_mechanics, plus
--           stable mechanic ids -> stalking. Now: 300 m grid + per-mechanic
--           offset that changes every 15 min, distance from the blurred
--           point rounded to 100 m, random ids, rate limit.
--  [HIGH]   Customer phone harvesting: a verified mechanic could accept ->
--           read customer_phone -> release, over and over. Now: max 3
--           releases / 24 h, then a 12 h suspension; phone is fetched through
--           a logged, rate-limited RPC by new apps (in-app chat as default).
--  [MEDIUM] "Ring bombing": book -> cancel -> book (credit refunded every
--           time) rang every nearby mechanic for free. Now: 3 pre-accept
--           cancellations in 2 h -> 30 min booking cooldown, 15 bookings/day.
--  [MEDIUM] Arbitrary issue tags / notes / names reached mechanics (phishing
--           "pay advance to UPI ...", bidi-override names, HTML). Now: tags
--           must come from `issue_catalog`, text is cleaned, UPI ids / links
--           rejected, names letters-only.
--  [MEDIUM] Paid-but-lost payments: a paid order could be replaced by a new
--           order (webhook then ignored it), a payment that landed after a
--           cancel was not flagged for refund. Now: `payment_orders` keeps
--           every order, mark_booking_paid flags refunds, auto-refunds.
--  [MEDIUM] No API rate limits (location scraping). Now: per-user limits on
--           the sensitive RPCs (private.hit_rate_limit).
--  [LOW]    PostGIS helper functions (postgis_full_version, addauth, ...)
--           callable by anon through /rest/v1/rpc. Now blocked by the API
--           guard (db_pre_request: only our own functions are callable).
--  [LOW]    OTP guesses reset when a job was released (colluding mechanics).
--           Now cumulative; the customer can issue a fresh OTP.
--  [LOW]    Deleted accounts kept exact pickup addresses. Now anonymised.
--
-- Scale: RLS initplan fixes, partial GIST indexes for the hot queries,
-- private Realtime Broadcast topics (booking status, live location, chat)
-- instead of postgres_changes for new app versions.
--
-- Features: issue catalog, in-app chat, repair bill + earnings, cancel with
-- reason, OTP refresh, review tags, mechanic card, saved places, AI
-- diagnosis storage (Edge Function `ai-assistant`), auto refunds.
--
-- Safe to run more than once. No data is dropped. Old RPCs stay for installed
-- app versions (rule 6 in CLAUDE.md).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 0. TEXT HYGIENE HELPERS
-- -----------------------------------------------------------------------------
-- Removes control / invisible / bidi-override characters, collapses spaces.
CREATE OR REPLACE FUNCTION private.clean_text(p_text TEXT, p_max INT DEFAULT 500)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
    SELECT NULLIF(left(btrim(regexp_replace(regexp_replace(COALESCE(p_text, ''),
             '[\x01-\x1F\x7F-\x9F\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]', ' ', 'g'),
             '[[:space:]]+', ' ', 'g')), GREATEST(p_max, 1)), '');
$$;

-- Person / shop names shown to the other side: no digits, links or symbols.
CREATE OR REPLACE FUNCTION private.clean_person_name(p_name TEXT, p_allow_digits BOOLEAN DEFAULT FALSE)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
    v TEXT := private.clean_text(p_name, 60);
BEGIN
    IF v IS NULL THEN
        RETURN NULL;
    END IF;
    IF length(v) < 2 THEN
        RAISE EXCEPTION 'Please enter your full name.' USING ERRCODE = '22023';
    END IF;
    IF v ~* '(https?:|www\.|\.(com|in|net|org|xyz|link|me)\M)'
       OR v ~ '[<>{}\[\]@#$%^*_=+|\\/~"`:;!?]'
       OR (NOT p_allow_digits AND v ~ '[0-9\u0966-\u096F\u09E6-\u09EF]')
       OR v ~ '[0-9\u0966-\u096F\u09E6-\u09EF]{6,}' THEN
        RAISE EXCEPTION 'Please use only letters in the name (no numbers, links or symbols).' USING ERRCODE = '22023';
    END IF;
    RETURN v;
END;
$$;

-- Free text the other side reads (issue note, chat): no payment ids / links.
CREATE OR REPLACE FUNCTION private.clean_message(p_text TEXT, p_max INT DEFAULT 500)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
    v TEXT := private.clean_text(p_text, p_max);
BEGIN
    IF v IS NULL THEN
        RETURN NULL;
    END IF;
    IF v ~* '(https?:|www\.|[a-z0-9]\.(com|in|net|org|xyz|link|me|ly)\M|t\.me/|wa\.me/)' THEN
        RAISE EXCEPTION 'Links are not allowed here.' USING ERRCODE = '22023';
    END IF;
    IF v ~* '[a-z0-9._-]{2,}@[a-z]{2,}' THEN
        RAISE EXCEPTION 'Please do not share UPI / payment IDs or e-mails here. Pay the mechanic only after the job.' USING ERRCODE = '22023';
    END IF;
    RETURN v;
END;
$$;

-- Cryptographically random 4-digit OTP without modulo bias.
CREATE OR REPLACE FUNCTION private.random_otp4()
RETURNS TEXT LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
DECLARE
    v_b BYTEA;
    v_n INT;
BEGIN
    LOOP
        v_b := extensions.gen_random_bytes(2);
        v_n := get_byte(v_b, 0) * 256 + get_byte(v_b, 1);
        EXIT WHEN v_n < 60000;
    END LOOP;
    RETURN lpad((v_n % 10000)::TEXT, 4, '0');
END;
$$;

REVOKE ALL ON FUNCTION private.clean_text(TEXT, INT), private.clean_person_name(TEXT, BOOLEAN),
    private.clean_message(TEXT, INT), private.random_otp4() FROM PUBLIC, anon;
-- Name triggers run as the updating user, so authenticated needs these.
GRANT EXECUTE ON FUNCTION private.clean_text(TEXT, INT), private.clean_person_name(TEXT, BOOLEAN)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION private.clean_message(TEXT, INT), private.random_otp4() TO service_role;

-- Names are cleaned on every write (direct UPDATE of full_name is allowed).
CREATE OR REPLACE FUNCTION private.tg_clean_customer_name()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    NEW.full_name := private.clean_person_name(NEW.full_name);
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_customers_clean_name ON public.customers;
CREATE TRIGGER trg_customers_clean_name BEFORE INSERT OR UPDATE OF full_name ON public.customers
    FOR EACH ROW EXECUTE FUNCTION private.tg_clean_customer_name();

CREATE OR REPLACE FUNCTION private.tg_clean_mechanic_names()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
    IF NEW.full_name IS DISTINCT FROM 'Deleted Partner' THEN
        NEW.full_name := COALESCE(private.clean_person_name(NEW.full_name), 'Partner');
    END IF;
    NEW.shop_name := private.clean_person_name(NEW.shop_name, TRUE);
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_mechanics_clean_names ON public.mechanics;
CREATE TRIGGER trg_mechanics_clean_names BEFORE INSERT OR UPDATE OF full_name, shop_name ON public.mechanics
    FOR EACH ROW EXECUTE FUNCTION private.tg_clean_mechanic_names();
REVOKE ALL ON FUNCTION private.tg_clean_customer_name(), private.tg_clean_mechanic_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.tg_clean_customer_name(), private.tg_clean_mechanic_names() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 1. RATE LIMITS + SECURITY EVENT LOG
-- -----------------------------------------------------------------------------
CREATE UNLOGGED TABLE IF NOT EXISTS private.rate_limits (
    bucket TEXT PRIMARY KEY,
    hits INT NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ NOT NULL
);
REVOKE ALL ON private.rate_limits FROM PUBLIC, anon, authenticated;

-- Fixed-window counter. TRUE = allowed, FALSE = over the limit.
CREATE OR REPLACE FUNCTION private.hit_rate_limit(p_key TEXT, p_max INT, p_window_seconds INT)
RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_window INT := GREATEST(p_window_seconds, 1);
    v_bucket TEXT := p_key || ':' || floor(extract(epoch FROM now()) / v_window)::BIGINT;
    v_hits INT;
BEGIN
    INSERT INTO private.rate_limits AS r (bucket, hits, expires_at)
    VALUES (v_bucket, 1, now() + make_interval(secs => v_window * 2))
    ON CONFLICT (bucket) DO UPDATE SET hits = r.hits + 1
    RETURNING r.hits INTO v_hits;
    RETURN v_hits <= p_max;
END;
$$;

CREATE TABLE IF NOT EXISTS private.security_events (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    user_id UUID,
    kind TEXT NOT NULL,
    detail JSONB
);
CREATE INDEX IF NOT EXISTS idx_security_events_time ON private.security_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_security_events_kind ON private.security_events (kind, created_at DESC);
REVOKE ALL ON private.security_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.log_security_event(p_kind TEXT, p_detail JSONB DEFAULT NULL)
RETURNS VOID LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
    INSERT INTO private.security_events (user_id, kind, detail) VALUES (auth.uid(), p_kind, p_detail);
$$;

-- Booking audit trail (release counting, contact reveals, timeline).
CREATE TABLE IF NOT EXISTS private.booking_events (
    id BIGSERIAL PRIMARY KEY,
    booking_id UUID NOT NULL,
    actor_id UUID,
    actor_role TEXT NOT NULL CHECK (actor_role IN ('customer', 'mechanic', 'system')),
    event TEXT NOT NULL,
    detail JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_booking_events_booking ON private.booking_events (booking_id, created_at);
CREATE INDEX IF NOT EXISTS idx_booking_events_actor ON private.booking_events (actor_id, event, created_at DESC);
REVOKE ALL ON private.booking_events FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.log_booking_event(p_booking_id UUID, p_actor_id UUID, p_role TEXT, p_event TEXT, p_detail JSONB DEFAULT NULL)
RETURNS VOID LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
    INSERT INTO private.booking_events (booking_id, actor_id, actor_role, event, detail)
    VALUES (p_booking_id, p_actor_id, p_role, p_event, p_detail);
$$;

REVOKE ALL ON FUNCTION private.hit_rate_limit(TEXT, INT, INT), private.log_security_event(TEXT, JSONB),
    private.log_booking_event(UUID, UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.hit_rate_limit(TEXT, INT, INT), private.log_security_event(TEXT, JSONB),
    private.log_booking_event(UUID, UUID, TEXT, TEXT, JSONB) TO service_role;

-- -----------------------------------------------------------------------------
-- 2. NEW COLUMNS + CONFIG
-- -----------------------------------------------------------------------------
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS ai_enabled BOOLEAN DEFAULT TRUE;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS ai_daily_limit_customer INT DEFAULT 15;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS ai_daily_limit_mechanic INT DEFAULT 40;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS max_releases_per_day INT DEFAULT 3;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS release_suspension_hours INT DEFAULT 12;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS auto_refunds_enabled BOOLEAN DEFAULT TRUE;
ALTER TABLE public.app_config ADD COLUMN IF NOT EXISTS service_message TEXT;

ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS booking_cooldown_until TIMESTAMPTZ;

ALTER TABLE public.mechanics ADD COLUMN IF NOT EXISTS suspended_until TIMESTAMPTZ;
ALTER TABLE public.mechanics ADD COLUMN IF NOT EXISTS suspension_reason TEXT;

ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS cancel_reason TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS repair_amount INT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS repair_notes TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS otp_refreshes INT DEFAULT 0;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS review_tags TEXT[];
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS ai_diagnosis JSONB;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS refund_id TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS refund_attempts INT DEFAULT 0;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMPTZ;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bookings_repair_amount_range') THEN
        ALTER TABLE public.bookings ADD CONSTRAINT bookings_repair_amount_range
            CHECK (repair_amount IS NULL OR repair_amount BETWEEN 0 AND 200000);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bookings_refund_status_values') THEN
        ALTER TABLE public.bookings ADD CONSTRAINT bookings_refund_status_values
            CHECK (refund_status IS NULL OR refund_status IN ('REQUESTED', 'PROCESSING', 'REFUNDED', 'FAILED')) NOT VALID;
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 3. ISSUE CATALOG (server-driven chips; tags are validated against it)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.issue_catalog (
    code TEXT PRIMARY KEY CHECK (code ~ '^[a-z_]{2,40}$'),
    label TEXT NOT NULL UNIQUE CHECK (length(label) BETWEEN 2 AND 40),
    icon TEXT,
    sort INT NOT NULL DEFAULT 100,
    categories TEXT[] NOT NULL DEFAULT ARRAY['cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle'],
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);
ALTER TABLE public.issue_catalog ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.issue_catalog FROM anon, authenticated;
GRANT SELECT ON public.issue_catalog TO anon, authenticated;
GRANT ALL ON public.issue_catalog TO service_role;
DROP POLICY IF EXISTS issue_catalog_read ON public.issue_catalog;
CREATE POLICY issue_catalog_read ON public.issue_catalog FOR SELECT TO anon, authenticated USING (is_active);

INSERT INTO public.issue_catalog (code, label, icon, sort, categories) VALUES
    ('puncture',    'Puncture / Tyre Flat', 'tire_repair',          10, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('wont_start',  'Won''t Start',         'power_settings_new',   20, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('battery',     'Battery Dead',         'battery_alert',        30, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('chain_brake', 'Chain / Brake',        'settings',             40, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('overheating', 'Overheating',          'thermostat',           50, ARRAY['two_wheeler','four_wheeler','heavy_vehicle']),
    ('fuel',        'Fuel Problem',         'local_gas_station',    60, ARRAY['two_wheeler','four_wheeler','heavy_vehicle']),
    ('electrical',  'Lights / Electrical',  'electrical_services',  70, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('clutch_gear', 'Clutch / Gear',        'tune',                 80, ARRAY['two_wheeler','four_wheeler','heavy_vehicle']),
    ('noise',       'Strange Noise',        'graphic_eq',           90, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('leak',        'Oil / Fluid Leak',     'water_drop',          100, ARRAY['two_wheeler','four_wheeler','heavy_vehicle']),
    ('lockout',     'Key Lost / Lockout',   'key',                 110, ARRAY['two_wheeler','four_wheeler','heavy_vehicle']),
    ('accident',    'Accident / Towing',    'car_crash',           120, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle']),
    ('other',       'Other',                'more_horiz',          999, ARRAY['cycle_toto','two_wheeler','four_wheeler','heavy_vehicle'])
ON CONFLICT (code) DO UPDATE
   SET label = EXCLUDED.label, icon = EXCLUDED.icon, sort = EXCLUDED.sort, categories = EXCLUDED.categories;

-- Only catalog labels survive (case-insensitive); unknown text is dropped.
CREATE OR REPLACE FUNCTION private.normalize_issue_tags(p_tags TEXT[])
RETURNS TEXT[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_tags TEXT[];
BEGIN
    SELECT array_agg(c.label ORDER BY c.sort) INTO v_tags
      FROM public.issue_catalog c
     WHERE c.is_active
       AND lower(c.label) IN (SELECT lower(btrim(t)) FROM unnest((COALESCE(p_tags, ARRAY[]::TEXT[]))[1:20]) AS t);
    IF v_tags IS NULL OR array_length(v_tags, 1) = 0 THEN
        RAISE EXCEPTION 'Please select at least one vehicle issue.' USING ERRCODE = '22023';
    END IF;
    RETURN v_tags[1:8];
END;
$$;
REVOKE ALL ON FUNCTION private.normalize_issue_tags(TEXT[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.normalize_issue_tags(TEXT[]) TO service_role;

-- -----------------------------------------------------------------------------
-- 4. RLS: private helpers + initplan-friendly policies
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.current_mechanic_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT id FROM public.mechanics WHERE user_id = auth.uid() LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION private.customer_can_view_mechanic(p_mechanic_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.bookings b
         WHERE b.mechanic_id = p_mechanic_id
           AND b.customer_id = auth.uid()
           AND (b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
                OR (b.status = 'COMPLETED' AND COALESCE(b.completed_at, b.updated_at) > now() - INTERVAL '2 hours'))
    );
$$;
REVOKE ALL ON FUNCTION private.current_mechanic_id(), private.customer_can_view_mechanic(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.current_mechanic_id(), private.customer_can_view_mechanic(UUID) TO authenticated, service_role;

DROP POLICY IF EXISTS customers_select_own ON public.customers;
CREATE POLICY customers_select_own ON public.customers FOR SELECT TO authenticated
    USING (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS customers_update_own ON public.customers;
CREATE POLICY customers_update_own ON public.customers FOR UPDATE TO authenticated
    USING (id = (SELECT auth.uid())) WITH CHECK (id = (SELECT auth.uid()));
DROP POLICY IF EXISTS mechanics_select_assigned ON public.mechanics;
CREATE POLICY mechanics_select_assigned ON public.mechanics FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()) OR private.customer_can_view_mechanic(id));
DROP POLICY IF EXISTS bookings_select_own ON public.bookings;
CREATE POLICY bookings_select_own ON public.bookings FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()));
DROP POLICY IF EXISTS customer_vehicles_select_own ON public.customer_vehicles;
CREATE POLICY customer_vehicles_select_own ON public.customer_vehicles FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()) AND NOT is_deleted);

-- The old public helper is no longer used by any policy.
REVOKE EXECUTE ON FUNCTION public.customer_can_view_mechanic(UUID) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. SCALE INDEXES
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_bookings_open_geo ON public.bookings USING GIST (pickup_location)
    WHERE status = 'SEARCHING' AND mechanic_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_mechanics_online_geo ON public.mechanics USING GIST (current_location)
    WHERE is_online AND is_verified;
CREATE INDEX IF NOT EXISTS idx_bookings_vehicle ON public.bookings (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_bookings_mechanic_done ON public.bookings (mechanic_id, completed_at DESC)
    WHERE status = 'COMPLETED';
CREATE INDEX IF NOT EXISTS idx_bookings_refunds ON public.bookings (refund_status)
    WHERE refund_status IN ('REQUESTED', 'PROCESSING');

-- -----------------------------------------------------------------------------
-- 6. CUSTOMER BOOKING FLOW
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.create_booking_impl(
    p_vehicle_type TEXT,
    p_issue_tags TEXT[],
    p_issue_note TEXT,
    p_pickup_address TEXT,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_vehicle_id UUID,
    p_ai_request_id UUID
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, extensions AS $$
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
    v_day INT;
    v_tags TEXT[];
    v_note TEXT;
    v_address TEXT;
    v_ai JSONB;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again to book a mechanic.' USING ERRCODE = '28000';
    END IF;

    IF p_vehicle_id IS NOT NULL THEN
        SELECT * INTO v_vehicle FROM public.customer_vehicles
         WHERE id = p_vehicle_id AND customer_id = v_uid AND NOT is_deleted;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Selected vehicle not found. Please select your vehicle again.';
        END IF;
        v_vehicle_type := v_vehicle.category;
        v_body := v_vehicle.body_type;
        v_label := v_vehicle.brand || ' ' || v_vehicle.model || COALESCE(' • ' || v_vehicle.reg_number, '');
    END IF;

    IF v_vehicle_type IS NULL OR v_vehicle_type NOT IN ('cycle_toto', 'two_wheeler', 'four_wheeler', 'heavy_vehicle') THEN
        RAISE EXCEPTION 'Invalid vehicle type selected.';
    END IF;

    v_tags := private.normalize_issue_tags(p_issue_tags);
    v_note := private.clean_message(left(COALESCE(p_issue_note, ''), 2000), 500);
    v_address := private.clean_text(left(COALESCE(p_pickup_address, ''), 2000), 300);
    IF v_address IS NULL OR length(v_address) < 3 THEN
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
    IF v_customer.id IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF v_customer.is_blocked THEN
        RAISE EXCEPTION 'Your account has been restricted. Please contact support.';
    END IF;
    IF v_customer.booking_cooldown_until IS NOT NULL AND v_customer.booking_cooldown_until > now() THEN
        RAISE EXCEPTION 'You cancelled several requests in a short time. You can book again in % min.',
            GREATEST(1, ceil(extract(epoch FROM v_customer.booking_cooldown_until - now()) / 60)::INT);
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.bookings
         WHERE customer_id = v_uid
           AND status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
           AND payment_status IN ('FREE_OFFER', 'PAID')
    ) THEN
        RAISE EXCEPTION 'You already have an active booking. Please finish or cancel it first.';
    END IF;

    SELECT count(*) FILTER (WHERE created_at > now() - INTERVAL '15 minutes'),
           count(*)
      INTO v_recent, v_day
      FROM public.bookings
     WHERE customer_id = v_uid AND created_at > now() - INTERVAL '1 day';
    IF v_recent >= 6 OR v_day >= 15 THEN
        RAISE EXCEPTION 'Too many booking attempts. Please wait a few minutes and retry.';
    END IF;

    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = 'SYSTEM_UNPAID'
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

    -- AI diagnosis made by THIS customer (server-stored, never client text).
    IF p_ai_request_id IS NOT NULL THEN
        SELECT jsonb_build_object(
                   'summary', left(COALESCE(a.output ->> 'summary', ''), 300),
                   'likely_causes', COALESCE((SELECT jsonb_agg(left(x ->> 'title', 80))
                                                FROM jsonb_array_elements(COALESCE(a.output -> 'likely_causes', '[]'::jsonb)) WITH ORDINALITY AS e(x, n)
                                               WHERE n <= 3), '[]'::jsonb),
                   'urgency', a.output ->> 'urgency')
          INTO v_ai
          FROM public.ai_requests a
         WHERE a.id = p_ai_request_id AND a.user_id = v_uid AND a.mode = 'customer'
           AND a.created_at > now() - INTERVAL '6 hours' AND a.output IS NOT NULL;
    END IF;

    v_otp := private.random_otp4();

    INSERT INTO public.bookings (
        customer_id, vehicle_type, issue_tags, issue_note, pickup_address,
        pickup_lat, pickup_lng, status, start_otp, platform_fee,
        is_free_offer_used, payment_status, vehicle_id, vehicle_label, vehicle_body_type, ai_diagnosis
    ) VALUES (
        v_uid, v_vehicle_type, v_tags, v_note, v_address, p_lat, p_lng, 'SEARCHING', v_otp, v_fee,
        v_free, v_payment_status, v_vehicle.id, v_label, v_body, v_ai
    ) RETURNING id INTO v_booking_id;

    IF v_vehicle.id IS NOT NULL THEN
        UPDATE public.customer_vehicles SET last_used_at = now() WHERE id = v_vehicle.id;
    END IF;
    PERFORM private.log_booking_event(v_booking_id, v_uid, 'customer', 'CREATED',
        jsonb_build_object('free', v_free, 'fee', v_fee));

    RETURN jsonb_build_object(
        'booking_id', v_booking_id,
        'payment_required', v_payment_required,
        'otp', v_otp,
        'amount', v_fee,
        'vehicle_type', v_vehicle_type
    );
END;
$$;
REVOKE ALL ON FUNCTION private.create_booking_impl(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- AI requests table must exist before create_booking_impl is first called.
CREATE TABLE IF NOT EXISTS public.ai_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    mode TEXT NOT NULL CHECK (mode IN ('customer', 'mechanic')),
    booking_id UUID REFERENCES public.bookings(id) ON DELETE SET NULL,
    input JSONB NOT NULL,
    output JSONB,
    engine TEXT NOT NULL DEFAULT 'rules',
    input_tokens INT,
    output_tokens INT,
    latency_ms INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ai_requests_user ON public.ai_requests (user_id, created_at DESC);
ALTER TABLE public.ai_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.ai_requests FROM anon, authenticated;
GRANT SELECT ON public.ai_requests TO authenticated;
GRANT ALL ON public.ai_requests TO service_role;
DROP POLICY IF EXISTS ai_requests_select_own ON public.ai_requests;
CREATE POLICY ai_requests_select_own ON public.ai_requests FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()));

-- Old 6-argument signature (oldest installs) and 7-argument signature (current
-- installs) keep working with all the new checks.
CREATE OR REPLACE FUNCTION public.create_booking_secure(
    p_vehicle_type TEXT, p_issue_tags TEXT[], p_issue_note TEXT, p_pickup_address TEXT,
    p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION
)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    SELECT private.create_booking_impl(p_vehicle_type, p_issue_tags, p_issue_note, p_pickup_address, p_lat, p_lng, NULL, NULL);
$$;

CREATE OR REPLACE FUNCTION public.create_booking_secure(
    p_vehicle_type TEXT, p_issue_tags TEXT[], p_issue_note TEXT, p_pickup_address TEXT,
    p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_vehicle_id UUID
)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    SELECT private.create_booking_impl(p_vehicle_type, p_issue_tags, p_issue_note, p_pickup_address, p_lat, p_lng, p_vehicle_id, NULL);
$$;

-- New app versions also link their AI diagnosis.
CREATE OR REPLACE FUNCTION public.create_booking_v2(
    p_vehicle_id UUID, p_issue_tags TEXT[], p_issue_note TEXT, p_pickup_address TEXT,
    p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_ai_request_id UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    SELECT private.create_booking_impl(NULL, p_issue_tags, p_issue_note, p_pickup_address, p_lat, p_lng, p_vehicle_id, p_ai_request_id);
$$;

-- Cancel (old signature kept) + cancel with reason. Repeated cancelling of
-- requests before a mechanic accepts triggers a short booking cooldown.
CREATE OR REPLACE FUNCTION private.cancel_booking_impl(p_booking_id UUID, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_b public.bookings%ROWTYPE;
    v_refund_credit BOOLEAN := FALSE;
    v_recent_cancels INT;
    v_cooldown BOOLEAN := FALSE;
    v_reason TEXT := private.clean_text(p_reason, 120);
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND customer_id = v_uid FOR UPDATE;
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
           cancelled_at = now(),
           cancelled_by = 'CUSTOMER',
           cancel_reason = v_reason,
           credit_refunded = COALESCE(credit_refunded, FALSE) OR v_refund_credit,
           refund_status = CASE WHEN v_b.status = 'SEARCHING' AND v_b.payment_status = 'PAID'
                                THEN 'REQUESTED' ELSE refund_status END
     WHERE id = p_booking_id;

    PERFORM private.log_booking_event(p_booking_id, v_uid, 'customer', 'CANCELLED',
        jsonb_build_object('before_accept', v_b.status = 'SEARCHING', 'reason', v_reason));

    IF v_b.status = 'SEARCHING' AND v_b.payment_status IN ('FREE_OFFER', 'PAID') THEN
        SELECT count(*) INTO v_recent_cancels
          FROM private.booking_events
         WHERE actor_id = v_uid AND event = 'CANCELLED' AND created_at > now() - INTERVAL '2 hours'
           AND (detail ->> 'before_accept')::BOOLEAN;
        IF v_recent_cancels >= 3 THEN
            UPDATE public.customers SET booking_cooldown_until = now() + INTERVAL '30 minutes' WHERE id = v_uid;
            v_cooldown := TRUE;
            PERFORM private.log_security_event('BOOKING_COOLDOWN', jsonb_build_object('cancels_2h', v_recent_cancels));
        END IF;
    END IF;

    RETURN jsonb_build_object('cancelled', TRUE, 'credit_refunded', v_refund_credit, 'cooldown', v_cooldown);
END;
$$;
REVOKE ALL ON FUNCTION private.cancel_booking_impl(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cancel_booking(p_booking_id UUID)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    SELECT private.cancel_booking_impl(p_booking_id, NULL);
$$;

CREATE OR REPLACE FUNCTION public.cancel_booking_v2(p_booking_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    SELECT private.cancel_booking_impl(p_booking_id, p_reason);
$$;

-- Customer issues a fresh start OTP (e.g. after the mechanic typed wrong OTPs).
CREATE OR REPLACE FUNCTION public.customer_refresh_start_otp(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_otp TEXT;
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND customer_id = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    IF v_b.status NOT IN ('SEARCHING', 'ACCEPTED', 'ARRIVED') THEN
        RAISE EXCEPTION 'The OTP can be changed only before the work starts.';
    END IF;
    IF COALESCE(v_b.otp_refreshes, 0) >= 3 THEN
        RAISE EXCEPTION 'OTP was changed too many times. Please contact support.';
    END IF;
    v_otp := private.random_otp4();
    UPDATE public.bookings
       SET start_otp = v_otp, otp_attempts = 0, otp_refreshes = COALESCE(otp_refreshes, 0) + 1
     WHERE id = p_booking_id;
    PERFORM private.log_booking_event(p_booking_id, auth.uid(), 'customer', 'OTP_REFRESHED', NULL);
    RETURN jsonb_build_object('otp', v_otp, 'refreshes_left', 2 - COALESCE(v_b.otp_refreshes, 0));
END;
$$;

-- Review with optional tags ("On time", "Polite", ...).
CREATE OR REPLACE FUNCTION public.submit_booking_review_v2(
    p_booking_id UUID, p_rating INT, p_review_text TEXT DEFAULT NULL, p_tags TEXT[] DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_tags TEXT[];
BEGIN
    IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
        RAISE EXCEPTION 'Please select a 1 to 5 star rating.';
    END IF;
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND customer_id = auth.uid() FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    IF v_b.status <> 'COMPLETED' THEN
        RAISE EXCEPTION 'You can rate only after the job is completed.';
    END IF;
    IF v_b.rating IS NOT NULL THEN
        RAISE EXCEPTION 'You have already rated this booking.';
    END IF;
    SELECT array_agg(DISTINCT t) INTO v_tags
      FROM unnest((COALESCE(p_tags, ARRAY[]::TEXT[]))[1:10]) AS t
     WHERE t IN ('On time', 'Polite', 'Expert work', 'Fair price', 'Clean work', 'Explained the problem',
                 'Late', 'Rude', 'Overcharged', 'Problem not fixed');
    UPDATE public.bookings
       SET rating = p_rating,
           review_text = private.clean_message(left(COALESCE(p_review_text, ''), 2000), 500),
           review_tags = v_tags
     WHERE id = p_booking_id;
    IF v_b.mechanic_id IS NOT NULL THEN
        UPDATE public.mechanics m
           SET rating = sub.avg_rating
          FROM (SELECT round(avg(rating)::numeric, 1) AS avg_rating
                  FROM public.bookings WHERE mechanic_id = v_b.mechanic_id AND rating IS NOT NULL) sub
         WHERE m.id = v_b.mechanic_id AND sub.avg_rating IS NOT NULL;
    END IF;
END;
$$;

-- Mechanic card for the customer during / right after the job.
CREATE OR REPLACE FUNCTION public.customer_get_mechanic_card(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_card JSONB;
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND customer_id = auth.uid();
    IF NOT FOUND OR v_b.mechanic_id IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT jsonb_build_object(
               'mechanic_id', m.id,
               'name', m.full_name,
               'shop_name', m.shop_name,
               'rating', m.rating,
               'jobs_completed', (SELECT count(*) FROM public.bookings x WHERE x.mechanic_id = m.id AND x.status = 'COMPLETED'),
               'member_since', m.created_at,
               'top_tags', COALESCE((SELECT jsonb_agg(t) FROM (
                    SELECT tag AS t FROM public.bookings x, unnest(x.review_tags) AS tag
                     WHERE x.mechanic_id = m.id AND x.review_tags IS NOT NULL
                       AND tag IN ('On time', 'Polite', 'Expert work', 'Fair price', 'Clean work', 'Explained the problem')
                     GROUP BY tag ORDER BY count(*) DESC LIMIT 3) s), '[]'::jsonb)
           ) INTO v_card
      FROM public.mechanics m WHERE m.id = v_b.mechanic_id;
    RETURN v_card;
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. MECHANIC FLOW
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mechanic_accept_booking(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_updated INT;
BEGIN
    IF v_m.suspended_until IS NOT NULL AND v_m.suspended_until > now() THEN
        RAISE EXCEPTION 'Your account is paused until % because of too many released jobs. Please contact support.',
            to_char(v_m.suspended_until AT TIME ZONE 'Asia/Kolkata', 'DD Mon HH12:MI AM');
    END IF;
    IF EXISTS (SELECT 1 FROM public.bookings WHERE mechanic_id = v_m.id
               AND status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')) THEN
        RAISE EXCEPTION 'Finish your current job before accepting a new one.';
    END IF;

    UPDATE public.bookings
       SET status = 'ACCEPTED', mechanic_id = v_m.id, accepted_at = now()
     WHERE id = p_booking_id AND status = 'SEARCHING' AND mechanic_id IS NULL
       AND payment_status IN ('FREE_OFFER', 'PAID')
       AND vehicle_type = ANY (v_m.vehicle_specialties)
       AND NOT (v_m.id = ANY (COALESCE(released_by, ARRAY[]::UUID[])));
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
        RAISE EXCEPTION 'This request was already taken or cancelled.';
    END IF;

    UPDATE public.mechanics SET is_online = TRUE WHERE id = v_m.id;
    PERFORM private.log_booking_event(p_booking_id, v_m.user_id, 'mechanic', 'ACCEPTED', jsonb_build_object('mechanic_id', v_m.id));
    RETURN public.mechanic_get_active_job();
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_release_job(p_booking_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_cfg public.app_config%ROWTYPE;
    v_releases INT;
BEGIN
    UPDATE public.bookings
       SET status = 'SEARCHING',
           mechanic_id = NULL,
           accepted_at = NULL,
           arrived_at = NULL,
           -- Guesses stay counted (no fresh tries for colluding mechanics)
           -- and the OTP changes, so earlier guesses are worthless.
           start_otp = private.random_otp4(),
           released_by = array_append(COALESCE(released_by, ARRAY[]::UUID[]), v_m.id),
           created_at = now()
     WHERE id = p_booking_id AND mechanic_id = v_m.id AND status IN ('ACCEPTED', 'ARRIVED');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'This job can no longer be released (already started or closed).';
    END IF;

    PERFORM private.log_booking_event(p_booking_id, v_m.user_id, 'mechanic', 'RELEASED',
        jsonb_build_object('mechanic_id', v_m.id, 'reason', private.clean_text(p_reason, 120)));

    SELECT * INTO v_cfg FROM public.app_config WHERE id = 1;
    SELECT count(*) INTO v_releases FROM private.booking_events
     WHERE actor_id = v_m.user_id AND event = 'RELEASED' AND created_at > now() - INTERVAL '24 hours';
    IF v_releases >= COALESCE(v_cfg.max_releases_per_day, 3) THEN
        UPDATE public.mechanics
           SET suspended_until = now() + make_interval(hours => COALESCE(v_cfg.release_suspension_hours, 12)),
               suspension_reason = 'Too many released jobs in 24 hours',
               is_online = FALSE
         WHERE id = v_m.id;
        PERFORM private.log_security_event('MECHANIC_SUSPENDED', jsonb_build_object('mechanic_id', v_m.id, 'releases_24h', v_releases));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.mechanic_start_job(p_booking_id UUID, p_otp TEXT)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_b public.bookings%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND mechanic_id = v_m.id FOR UPDATE;
    IF NOT FOUND OR v_b.status NOT IN ('ACCEPTED', 'ARRIVED') THEN
        RAISE EXCEPTION 'Booking is not ready to start.';
    END IF;
    IF COALESCE(v_b.otp_attempts, 0) >= 5 THEN
        RETURN jsonb_build_object('started', FALSE, 'locked', TRUE, 'attempts_left', 0,
            'message', 'Too many wrong OTPs. Ask the customer to tap "New OTP" in their app.');
    END IF;
    IF btrim(COALESCE(p_otp, '')) <> v_b.start_otp THEN
        UPDATE public.bookings SET otp_attempts = COALESCE(otp_attempts, 0) + 1 WHERE id = p_booking_id;
        IF COALESCE(v_b.otp_attempts, 0) + 1 >= 5 THEN
            PERFORM private.log_security_event('OTP_LOCKED', jsonb_build_object('booking_id', p_booking_id, 'mechanic_id', v_m.id));
        END IF;
        RETURN jsonb_build_object('started', FALSE,
                                  'message', 'Wrong OTP. Please ask the customer again.',
                                  'attempts_left', GREATEST(0, 4 - COALESCE(v_b.otp_attempts, 0)));
    END IF;
    UPDATE public.bookings
       SET status = 'IN_PROGRESS', started_at = now(), arrived_at = COALESCE(arrived_at, now())
     WHERE id = p_booking_id;
    PERFORM private.log_booking_event(p_booking_id, v_m.user_id, 'mechanic', 'STARTED', NULL);
    RETURN jsonb_build_object('started', TRUE);
END;
$$;

-- Phone number of the customer, only for the assigned mechanic, logged and
-- rate limited (new Partner app calls this when the mechanic taps "Call").
CREATE OR REPLACE FUNCTION public.mechanic_get_customer_contact(p_booking_id UUID)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_phone TEXT;
BEGIN
    SELECT c.phone INTO v_phone
      FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
     WHERE b.id = p_booking_id AND b.mechanic_id = v_m.id AND b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'You can call the customer only during your active job.';
    END IF;
    IF NOT private.hit_rate_limit('contact:' || v_m.id, 30, 86400) THEN
        PERFORM private.log_security_event('CONTACT_RATE_LIMIT', jsonb_build_object('mechanic_id', v_m.id));
        RAISE EXCEPTION 'Too many contact requests today. Please use the in-app chat.';
    END IF;
    PERFORM private.log_booking_event(p_booking_id, v_m.user_id, 'mechanic', 'CONTACT_REVEAL', NULL);
    RETURN jsonb_build_object('phone', v_phone);
END;
$$;

-- Active job for new Partner app versions: no phone number in the payload.
CREATE OR REPLACE FUNCTION public.mechanic_get_active_job_v2()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_job JSONB;
BEGIN
    SELECT jsonb_build_object(
               'booking_id', b.id, 'status', b.status, 'vehicle_type', b.vehicle_type,
               'vehicle_label', b.vehicle_label, 'vehicle_body_type', b.vehicle_body_type,
               'issue_tags', b.issue_tags, 'issue_note', b.issue_note,
               'voice_note_path', b.voice_note_path, 'voice_note_seconds', b.voice_note_seconds,
               'pickup_address', b.pickup_address, 'pickup_lat', b.pickup_lat, 'pickup_lng', b.pickup_lng,
               'customer_name', COALESCE(split_part(c.full_name, ' ', 1), 'Customer'),
               'ai_diagnosis', b.ai_diagnosis,
               'otp_attempts_left', GREATEST(0, 5 - COALESCE(b.otp_attempts, 0)),
               'accepted_at', b.accepted_at, 'arrived_at', b.arrived_at, 'started_at', b.started_at,
               'platform_fee', b.platform_fee, 'payment_status', b.payment_status,
               'unread_messages', (SELECT count(*) FROM public.booking_messages bm
                                    WHERE bm.booking_id = b.id AND bm.mechanic_id = v_m.id
                                      AND bm.sender_role = 'customer' AND bm.read_at IS NULL),
               'min_visit_charge', (SELECT min_visit_charge FROM public.app_config WHERE id = 1)
           )
      INTO v_job
      FROM public.bookings b JOIN public.customers c ON c.id = b.customer_id
     WHERE b.mechanic_id = v_m.id AND b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
     ORDER BY b.accepted_at DESC NULLS LAST
     LIMIT 1;
    RETURN v_job;
END;
$$;

-- Complete with the repair bill (labour + parts the customer paid directly).
CREATE OR REPLACE FUNCTION public.mechanic_complete_job_v2(
    p_booking_id UUID, p_repair_amount INT DEFAULT NULL, p_repair_notes TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    IF p_repair_amount IS NOT NULL AND (p_repair_amount < 0 OR p_repair_amount > 200000) THEN
        RAISE EXCEPTION 'Please enter a valid repair amount (₹0 – ₹2,00,000).';
    END IF;
    UPDATE public.bookings
       SET repair_amount = p_repair_amount,
           repair_notes = private.clean_message(left(COALESCE(p_repair_notes, ''), 1000), 300)
     WHERE id = p_booking_id AND mechanic_id = v_m.id AND status = 'IN_PROGRESS';
    PERFORM public.mechanic_complete_job(p_booking_id);
    PERFORM private.log_booking_event(p_booking_id, v_m.user_id, 'mechanic', 'COMPLETED',
        jsonb_build_object('repair_amount', p_repair_amount));
    RETURN jsonb_build_object('completed', TRUE);
END;
$$;

-- Earnings dashboard.
CREATE OR REPLACE FUNCTION public.mechanic_get_stats_v2()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
    v_today DATE := (now() AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_stats JSONB;
    v_released INT;
BEGIN
    SELECT count(*) INTO v_released FROM private.booking_events
     WHERE actor_id = v_m.user_id AND event = 'RELEASED' AND created_at > now() - INTERVAL '30 days';
    SELECT jsonb_build_object(
               'today_completed', count(*) FILTER (WHERE (completed_at AT TIME ZONE 'Asia/Kolkata')::DATE = v_today),
               'week_completed', count(*) FILTER (WHERE completed_at > now() - INTERVAL '7 days'),
               'month_completed', count(*) FILTER (WHERE completed_at > now() - INTERVAL '30 days'),
               'total_completed', count(*),
               'today_earnings', COALESCE(sum(repair_amount) FILTER (WHERE (completed_at AT TIME ZONE 'Asia/Kolkata')::DATE = v_today), 0),
               'week_earnings', COALESCE(sum(repair_amount) FILTER (WHERE completed_at > now() - INTERVAL '7 days'), 0),
               'month_earnings', COALESCE(sum(repair_amount) FILTER (WHERE completed_at > now() - INTERVAL '30 days'), 0),
               'total_earnings', COALESCE(sum(repair_amount), 0),
               'rating', v_m.rating,
               'rating_count', count(rating),
               'released_30d', v_released,
               'accepted_30d', count(*) FILTER (WHERE completed_at > now() - INTERVAL '30 days') + v_released,
               'suspended_until', v_m.suspended_until,
               'daily', COALESCE((SELECT jsonb_agg(jsonb_build_object('day', d.day, 'jobs', d.jobs, 'earnings', d.earnings) ORDER BY d.day)
                                    FROM (SELECT (x.completed_at AT TIME ZONE 'Asia/Kolkata')::DATE AS day,
                                                 count(*) AS jobs, COALESCE(sum(x.repair_amount), 0) AS earnings
                                            FROM public.bookings x
                                           WHERE x.mechanic_id = v_m.id AND x.status = 'COMPLETED'
                                             AND x.completed_at > now() - INTERVAL '7 days'
                                           GROUP BY 1) d), '[]'::jsonb)
           ) INTO v_stats
      FROM public.bookings
     WHERE mechanic_id = v_m.id AND status = 'COMPLETED';
    RETURN v_stats;
END;
$$;

-- Open requests v4: adds the customer's AI diagnosis summary (v3/v2 stay).
CREATE OR REPLACE FUNCTION public.mechanic_get_open_requests_v4(p_radius_meters INT DEFAULT 10000)
RETURNS TABLE (
    booking_id UUID, vehicle_type TEXT, issue_tags TEXT[], issue_note TEXT,
    pickup_address TEXT, pickup_lat DOUBLE PRECISION, pickup_lng DOUBLE PRECISION,
    distance_meters DOUBLE PRECISION, created_at TIMESTAMPTZ,
    vehicle_label TEXT, vehicle_body_type TEXT,
    voice_note_path TEXT, voice_note_seconds INT, ai_diagnosis JSONB
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_m public.mechanics%ROWTYPE := public._require_mechanic();
BEGIN
    IF v_m.current_location IS NULL OR (v_m.suspended_until IS NOT NULL AND v_m.suspended_until > now()) THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT b.id, b.vehicle_type, b.issue_tags, b.issue_note, b.pickup_address,
           b.pickup_lat, b.pickup_lng,
           ST_Distance(b.pickup_location, v_m.current_location), b.created_at,
           split_part(b.vehicle_label, ' • ', 1), b.vehicle_body_type,
           b.voice_note_path, b.voice_note_seconds, b.ai_diagnosis
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

-- -----------------------------------------------------------------------------
-- 8. NEARBY MECHANICS — privacy preserving (fixes trilateration / stalking)
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
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_radius INT := LEAST(GREATEST(COALESCE(p_radius_meters, 3000), 500), 15000);
    v_point GEOGRAPHY;
    v_slot TEXT := floor(extract(epoch FROM now()) / 900)::BIGINT::TEXT;  -- 15-minute window
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98 THEN
        RETURN;
    END IF;
    -- Phone-verified customers / partners only (not bare e-mail accounts).
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = v_uid)
       AND NOT EXISTS (SELECT 1 FROM public.mechanics WHERE user_id = v_uid) THEN
        RETURN;
    END IF;
    IF NOT private.hit_rate_limit('nearby:' || v_uid, 40, 600) THEN
        RETURN;
    END IF;
    v_point := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;

    RETURN QUERY
    WITH near AS (
        SELECT m.id, m.current_lat, m.current_lng
          FROM public.mechanics m
         WHERE m.is_verified AND m.is_online
           AND m.current_location IS NOT NULL
           AND (m.suspended_until IS NULL OR m.suspended_until < now())
           AND m.updated_at > now() - INTERVAL '20 minutes'
           AND (p_vehicle_type IS NULL OR p_vehicle_type = ANY (m.vehicle_specialties))
           AND ST_DWithin(m.current_location, v_point, v_radius)
         ORDER BY m.current_location <-> v_point
         LIMIT 20
    ), blurred AS (
        -- Snap to a ~330 m grid cell, then move to a pseudo-random point inside
        -- the cell that stays the same for 15 minutes (markers don't jump,
        -- repeated queries can't average it out to the real position).
        SELECT n.id,
               floor(n.current_lat / 0.003) * 0.003
                 + 0.003 * (('x' || substr(md5(n.id::TEXT || v_slot), 1, 4))::BIT(16)::INT / 65535.0) AS blat,
               floor(n.current_lng / 0.003) * 0.003
                 + 0.003 * (('x' || substr(md5(n.id::TEXT || v_slot), 5, 4))::BIT(16)::INT / 65535.0) AS blng
          FROM near n
    )
    SELECT gen_random_uuid(),
           'Verified partner'::TEXT,
           (round(ST_Distance(ST_SetSRID(ST_MakePoint(b.blng, b.blat), 4326)::geography, v_point) / 100.0) * 100)::DOUBLE PRECISION,
           round(b.blat::NUMERIC, 5)::DOUBLE PRECISION,
           round(b.blng::NUMERIC, 5)::DOUBLE PRECISION
      FROM blurred b
     ORDER BY 3;
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. IN-APP CHAT (customer <-> assigned mechanic, no phone numbers needed)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.booking_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    booking_id UUID NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
    mechanic_id UUID NOT NULL REFERENCES public.mechanics(id) ON DELETE CASCADE,
    sender_id UUID,
    sender_role TEXT NOT NULL CHECK (sender_role IN ('customer', 'mechanic', 'system')),
    body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    read_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_booking_messages_thread ON public.booking_messages (booking_id, mechanic_id, created_at);
ALTER TABLE public.booking_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.booking_messages FROM anon, authenticated;
GRANT ALL ON public.booking_messages TO service_role;
-- No direct table access: everything goes through the RPCs below.

-- Who is in this booking's conversation? Returns the role + current mechanic.
CREATE OR REPLACE FUNCTION private.chat_access(p_booking_id UUID, OUT access_role TEXT, OUT access_mechanic_id UUID, OUT is_open BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_mid UUID := private.current_mechanic_id();
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id;
    IF NOT FOUND OR v_b.mechanic_id IS NULL THEN
        RETURN;
    END IF;
    is_open := v_b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
            OR (v_b.status = 'COMPLETED' AND COALESCE(v_b.completed_at, v_b.updated_at) > now() - INTERVAL '30 minutes');
    IF v_b.customer_id = auth.uid() THEN
        access_role := 'customer';
        access_mechanic_id := v_b.mechanic_id;
    ELSIF v_mid IS NOT NULL AND v_b.mechanic_id = v_mid THEN
        access_role := 'mechanic';
        access_mechanic_id := v_mid;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.chat_access(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.send_booking_message(p_booking_id UUID, p_body TEXT)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_access RECORD;
    v_body TEXT;
    v_row public.booking_messages%ROWTYPE;
BEGIN
    SELECT * INTO v_access FROM private.chat_access(p_booking_id);
    IF v_access.access_role IS NULL THEN
        RAISE EXCEPTION 'Chat is available only between you and your mechanic during the booking.';
    END IF;
    IF NOT v_access.is_open THEN
        RAISE EXCEPTION 'This chat is closed.';
    END IF;
    v_body := private.clean_message(left(COALESCE(p_body, ''), 2000), 500);
    IF v_body IS NULL THEN
        RAISE EXCEPTION 'Message is empty.';
    END IF;
    IF NOT private.hit_rate_limit('chat:' || auth.uid(), 20, 60)
       OR NOT private.hit_rate_limit('chatday:' || auth.uid(), 300, 86400) THEN
        RAISE EXCEPTION 'You are sending messages too fast. Please wait a moment.';
    END IF;
    INSERT INTO public.booking_messages (booking_id, mechanic_id, sender_id, sender_role, body)
    VALUES (p_booking_id, v_access.access_mechanic_id, auth.uid(), v_access.access_role, v_body)
    RETURNING * INTO v_row;
    RETURN jsonb_build_object('id', v_row.id, 'booking_id', v_row.booking_id, 'sender_role', v_row.sender_role,
                              'body', v_row.body, 'created_at', v_row.created_at, 'read_at', v_row.read_at);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_booking_messages(p_booking_id UUID, p_after TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_access RECORD;
    v_rows JSONB;
BEGIN
    SELECT * INTO v_access FROM private.chat_access(p_booking_id);
    IF v_access.access_role IS NULL THEN
        RETURN jsonb_build_object('messages', '[]'::jsonb, 'open', FALSE, 'role', NULL);
    END IF;
    -- Opening the thread marks the other side's messages as read.
    UPDATE public.booking_messages
       SET read_at = now()
     WHERE booking_id = p_booking_id AND mechanic_id = v_access.access_mechanic_id
       AND sender_role <> v_access.access_role AND read_at IS NULL;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', m.id, 'sender_role', m.sender_role, 'body', m.body,
                                                  'created_at', m.created_at, 'read_at', m.read_at)
                              ORDER BY m.created_at), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT * FROM public.booking_messages
             WHERE booking_id = p_booking_id AND mechanic_id = v_access.access_mechanic_id
               AND (p_after IS NULL OR created_at > p_after)
             ORDER BY created_at DESC LIMIT 200) m;
    RETURN jsonb_build_object('messages', v_rows, 'open', v_access.is_open, 'role', v_access.access_role);
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. SAVED PLACES (Home / Work / ...)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_places (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 24),
    address TEXT NOT NULL CHECK (length(address) BETWEEN 3 AND 300),
    lat DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN 6 AND 38),
    lng DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN 68 AND 98),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_customer_places_owner ON public.customer_places (customer_id, updated_at DESC);
ALTER TABLE public.customer_places ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_places FROM anon, authenticated;
GRANT SELECT ON public.customer_places TO authenticated;
GRANT ALL ON public.customer_places TO service_role;
DROP POLICY IF EXISTS customer_places_select_own ON public.customer_places;
CREATE POLICY customer_places_select_own ON public.customer_places FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()));

CREATE OR REPLACE FUNCTION public.customer_save_place(
    p_label TEXT, p_address TEXT, p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION, p_place_id UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_label TEXT := private.clean_text(p_label, 24);
    v_address TEXT := private.clean_text(left(COALESCE(p_address, ''), 1000), 300);
    v_row public.customer_places%ROWTYPE;
BEGIN
    IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM public.customers WHERE id = v_uid) THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    IF v_label IS NULL OR v_address IS NULL OR length(v_address) < 3 THEN
        RAISE EXCEPTION 'Please give the place a name and an address.';
    END IF;
    IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN 6 AND 38 OR p_lng NOT BETWEEN 68 AND 98 THEN
        RAISE EXCEPTION 'This place is outside our service area.';
    END IF;
    IF p_place_id IS NULL THEN
        IF (SELECT count(*) FROM public.customer_places WHERE customer_id = v_uid) >= 10 THEN
            RAISE EXCEPTION 'You can save up to 10 places.';
        END IF;
        INSERT INTO public.customer_places (customer_id, label, address, lat, lng)
        VALUES (v_uid, v_label, v_address, p_lat, p_lng) RETURNING * INTO v_row;
    ELSE
        UPDATE public.customer_places
           SET label = v_label, address = v_address, lat = p_lat, lng = p_lng, updated_at = now()
         WHERE id = p_place_id AND customer_id = v_uid RETURNING * INTO v_row;
        IF v_row.id IS NULL THEN
            RAISE EXCEPTION 'Place not found.';
        END IF;
    END IF;
    RETURN to_jsonb(v_row) - 'customer_id';
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_delete_place(p_place_id UUID)
RETURNS VOID LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = public AS $$
    DELETE FROM public.customer_places WHERE id = p_place_id AND customer_id = auth.uid();
$$;

-- -----------------------------------------------------------------------------
-- 11. VOICE NOTES: reject tiny / fake uploads when linking
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_attach_voice_note(
    p_booking_id UUID,
    p_path TEXT,
    p_seconds INT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_b public.bookings%ROWTYPE;
    v_size BIGINT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id AND customer_id = v_uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    IF v_b.status NOT IN ('SEARCHING', 'ACCEPTED', 'ARRIVED') THEN
        RAISE EXCEPTION 'This booking is no longer active.';
    END IF;
    IF v_b.voice_note_path IS NOT NULL THEN
        RAISE EXCEPTION 'A voice note is already attached to this booking.';
    END IF;
    IF p_path IS NULL
       OR p_path !~ '^[0-9a-f-]{36}/[0-9a-f-]{36}_[0-9]{10,16}\.m4a$'
       OR NOT starts_with(p_path, v_uid::TEXT || '/' || p_booking_id::TEXT || '_') THEN
        RAISE EXCEPTION 'Invalid voice note.';
    END IF;
    SELECT (o.metadata ->> 'size')::BIGINT INTO v_size
      FROM storage.objects o
     WHERE o.bucket_id = 'voice-notes' AND o.name = p_path
       AND (o.owner_id = v_uid::TEXT OR o.owner = v_uid);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voice note upload not found. Please try again.';
    END IF;
    IF v_size IS NOT NULL AND v_size < 1500 THEN
        RAISE EXCEPTION 'The voice note is too short. Please record again.';
    END IF;
    UPDATE public.bookings
       SET voice_note_path = p_path,
           voice_note_seconds = LEAST(GREATEST(COALESCE(p_seconds, 1), 1), 90)
     WHERE id = p_booking_id;
    RETURN jsonb_build_object('attached', TRUE);
END;
$$;

-- -----------------------------------------------------------------------------
-- 12. PAYMENTS: keep every Razorpay order + refund-safe mark_booking_paid
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_orders (
    order_id TEXT PRIMARY KEY,
    booking_id UUID NOT NULL REFERENCES public.bookings(id) ON DELETE CASCADE,
    customer_id UUID NOT NULL,
    amount_paise INT NOT NULL CHECK (amount_paise > 0),
    status TEXT NOT NULL DEFAULT 'CREATED',
    payment_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payment_orders_booking ON public.payment_orders (booking_id, created_at DESC);
ALTER TABLE public.payment_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_orders FROM anon, authenticated;
GRANT ALL ON public.payment_orders TO service_role;

-- Existing orders become known orders.
INSERT INTO public.payment_orders (order_id, booking_id, customer_id, amount_paise, status, payment_id)
SELECT b.razorpay_order_id, b.id, b.customer_id, GREATEST(b.platform_fee, 1) * 100,
       CASE WHEN b.payment_status = 'PAID' THEN 'PAID' ELSE 'CREATED' END, b.razorpay_payment_id
  FROM public.bookings b
 WHERE b.razorpay_order_id IS NOT NULL
ON CONFLICT (order_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.mark_booking_paid(
    p_booking_id UUID,
    p_order_id TEXT,
    p_payment_id TEXT
)
RETURNS BOOLEAN LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_b public.bookings%ROWTYPE;
    v_known BOOLEAN;
    v_other_active BOOLEAN;
BEGIN
    SELECT * INTO v_b FROM public.bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Booking not found.';
    END IF;
    SELECT EXISTS (SELECT 1 FROM public.payment_orders WHERE order_id = p_order_id AND booking_id = p_booking_id)
      INTO v_known;
    IF v_b.razorpay_order_id IS DISTINCT FROM p_order_id AND NOT v_known THEN
        RAISE EXCEPTION 'Order mismatch for this booking.';
    END IF;
    UPDATE public.payment_orders SET status = 'PAID', payment_id = p_payment_id, updated_at = now()
     WHERE order_id = p_order_id;

    IF v_b.payment_status = 'PAID' THEN
        -- A second, different payment for the same booking -> refund it.
        IF v_b.razorpay_payment_id IS DISTINCT FROM p_payment_id THEN
            PERFORM private.log_booking_event(p_booking_id, NULL, 'system', 'DUPLICATE_PAYMENT',
                jsonb_build_object('payment_id', p_payment_id, 'order_id', p_order_id));
        END IF;
        RETURN TRUE;
    END IF;

    SELECT EXISTS (SELECT 1 FROM public.bookings x
                    WHERE x.customer_id = v_b.customer_id AND x.id <> v_b.id
                      AND x.status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
                      AND x.payment_status IN ('FREE_OFFER', 'PAID'))
      INTO v_other_active;

    IF v_b.status = 'CANCELLED' AND v_b.cancelled_by = 'SYSTEM_UNPAID' AND v_b.mechanic_id IS NULL AND NOT v_other_active THEN
        -- Money arrived while the unpaid attempt had expired: revive the search.
        UPDATE public.bookings
           SET payment_status = 'PAID', razorpay_order_id = p_order_id, razorpay_payment_id = p_payment_id,
               paid_at = now(), status = 'SEARCHING', cancelled_at = NULL, cancelled_by = NULL,
               created_at = now()
         WHERE id = p_booking_id;
    ELSIF v_b.status = 'CANCELLED' THEN
        -- Paid after the booking was cancelled -> refund automatically.
        UPDATE public.bookings
           SET payment_status = 'PAID', razorpay_order_id = p_order_id, razorpay_payment_id = p_payment_id,
               paid_at = now(), refund_status = COALESCE(refund_status, 'REQUESTED')
         WHERE id = p_booking_id;
    ELSE
        UPDATE public.bookings
           SET payment_status = 'PAID', razorpay_order_id = p_order_id, razorpay_payment_id = p_payment_id,
               paid_at = now()
         WHERE id = p_booking_id;
    END IF;
    RETURN TRUE;
END;
$$;

-- -----------------------------------------------------------------------------
-- 13. ACCOUNT DELETION: anonymise locations, chat, places, AI history too
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_account_data(p_uid UUID)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
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

    UPDATE public.bookings
       SET status = 'CANCELLED', cancelled_at = now(), cancelled_by = 'ACCOUNT_DELETED',
           refund_status = CASE WHEN payment_status = 'PAID' THEN 'REQUESTED' ELSE refund_status END
     WHERE customer_id = p_uid AND status = 'SEARCHING';

    -- Customer side: bookings stay for payment / tax records without identity.
    UPDATE public.customer_vehicles SET is_deleted = TRUE, reg_number = NULL WHERE customer_id = p_uid;
    UPDATE public.bookings
       SET issue_note = NULL, review_text = NULL,
           voice_note_path = NULL, voice_note_seconds = NULL,
           pickup_address = 'Deleted account',
           pickup_lat = round(pickup_lat::numeric, 2)::DOUBLE PRECISION,
           pickup_lng = round(pickup_lng::numeric, 2)::DOUBLE PRECISION,
           vehicle_label = split_part(vehicle_label, ' • ', 1),
           ai_diagnosis = NULL
     WHERE customer_id = p_uid;
    DELETE FROM public.booking_messages
     WHERE booking_id IN (SELECT id FROM public.bookings WHERE customer_id = p_uid);
    DELETE FROM public.customer_places WHERE customer_id = p_uid;
    DELETE FROM public.ai_requests WHERE user_id = p_uid;
    UPDATE public.customers
       SET phone = 'deleted-' || id::TEXT, full_name = NULL, free_bookings_left = 0, is_blocked = TRUE
     WHERE id = p_uid;

    -- Mechanic side
    IF v_mech.id IS NOT NULL THEN
        UPDATE public.booking_messages SET body = '[deleted]' WHERE mechanic_id = v_mech.id AND sender_role = 'mechanic';
        UPDATE public.mechanics
           SET user_id = NULL, full_name = 'Deleted Partner', phone = 'deleted-' || id::TEXT,
               shop_name = NULL, avatar_url = NULL, is_online = FALSE, is_verified = FALSE,
               current_lat = NULL, current_lng = NULL
         WHERE id = v_mech.id;
    END IF;

    RETURN jsonb_build_object('deleted', TRUE);
END;
$$;

-- -----------------------------------------------------------------------------
-- 14. REALTIME BROADCAST (private topics; scales far better than
--     postgres_changes and nothing sensitive is in the payloads)
-- -----------------------------------------------------------------------------
--   booking:<booking_id>                 status changes (customer + assigned mechanic)
--   booking:<booking_id>:m:<mechanic_id> live location + chat pings for that pair
CREATE OR REPLACE FUNCTION private.can_listen_topic(p_topic TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_parts TEXT[];
    v_booking UUID;
    v_mech UUID;
    v_my_mech UUID;
BEGIN
    IF auth.uid() IS NULL OR p_topic IS NULL THEN
        RETURN FALSE;
    END IF;
    v_parts := regexp_match(p_topic, '^booking:([0-9a-f-]{36})(?::m:([0-9a-f-]{36}))?$');
    IF v_parts IS NULL THEN
        RETURN FALSE;
    END IF;
    v_booking := v_parts[1]::UUID;
    v_mech := v_parts[2]::UUID;
    v_my_mech := private.current_mechanic_id();
    RETURN EXISTS (
        SELECT 1 FROM public.bookings b
         WHERE b.id = v_booking
           AND (
                (b.customer_id = auth.uid() AND (v_mech IS NULL OR v_mech = b.mechanic_id))
             OR (v_my_mech IS NOT NULL AND b.mechanic_id = v_my_mech AND (v_mech IS NULL OR v_mech = v_my_mech))
           )
    );
EXCEPTION WHEN invalid_text_representation THEN
    RETURN FALSE;
END;
$$;
REVOKE ALL ON FUNCTION private.can_listen_topic(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_listen_topic(TEXT) TO authenticated, service_role;

DROP POLICY IF EXISTS speedy_booking_topics_read ON realtime.messages;
CREATE POLICY speedy_booking_topics_read ON realtime.messages FOR SELECT TO authenticated
    USING (realtime.messages.extension = 'broadcast' AND private.can_listen_topic((SELECT realtime.topic())));
-- No INSERT policy: only the server (triggers below) can broadcast.

CREATE OR REPLACE FUNCTION private.tg_booking_broadcast()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.status IS NOT DISTINCT FROM OLD.status
       AND NEW.mechanic_id IS NOT DISTINCT FROM OLD.mechanic_id
       AND NEW.payment_status IS NOT DISTINCT FROM OLD.payment_status
       AND NEW.otp_attempts IS NOT DISTINCT FROM OLD.otp_attempts
       AND NEW.otp_refreshes IS NOT DISTINCT FROM OLD.otp_refreshes
       AND NEW.voice_note_path IS NOT DISTINCT FROM OLD.voice_note_path THEN
        RETURN NEW;
    END IF;
    PERFORM realtime.send(
        jsonb_build_object('booking_id', NEW.id, 'status', NEW.status, 'mechanic_id', NEW.mechanic_id,
                           'payment_status', NEW.payment_status, 'updated_at', NEW.updated_at),
        'booking', 'booking:' || NEW.id::TEXT, TRUE);
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;  -- realtime must never block a booking write
END;
$$;
DROP TRIGGER IF EXISTS trg_bookings_broadcast ON public.bookings;
CREATE TRIGGER trg_bookings_broadcast AFTER INSERT OR UPDATE ON public.bookings
    FOR EACH ROW EXECUTE FUNCTION private.tg_booking_broadcast();

CREATE OR REPLACE FUNCTION private.tg_mechanic_location_broadcast()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    v_booking UUID;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL
       OR (NEW.current_lat IS NOT DISTINCT FROM OLD.current_lat AND NEW.current_lng IS NOT DISTINCT FROM OLD.current_lng) THEN
        RETURN NEW;
    END IF;
    SELECT b.id INTO v_booking FROM public.bookings b
     WHERE b.mechanic_id = NEW.id AND b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS')
     ORDER BY b.accepted_at DESC NULLS LAST LIMIT 1;
    IF v_booking IS NOT NULL THEN
        PERFORM realtime.send(
            jsonb_build_object('lat', NEW.current_lat, 'lng', NEW.current_lng, 'at', now()),
            'location', 'booking:' || v_booking::TEXT || ':m:' || NEW.id::TEXT, TRUE);
    END IF;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_mechanics_location_broadcast ON public.mechanics;
CREATE TRIGGER trg_mechanics_location_broadcast AFTER UPDATE OF current_lat, current_lng ON public.mechanics
    FOR EACH ROW EXECUTE FUNCTION private.tg_mechanic_location_broadcast();

CREATE OR REPLACE FUNCTION private.tg_chat_broadcast()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    -- Ping only; the app fetches the thread through get_booking_messages.
    PERFORM realtime.send(
        jsonb_build_object('message_id', NEW.id, 'sender_role', NEW.sender_role, 'at', NEW.created_at),
        'chat', 'booking:' || NEW.booking_id::TEXT || ':m:' || NEW.mechanic_id::TEXT, TRUE);
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_booking_messages_broadcast ON public.booking_messages;
CREATE TRIGGER trg_booking_messages_broadcast AFTER INSERT ON public.booking_messages
    FOR EACH ROW EXECUTE FUNCTION private.tg_chat_broadcast();

REVOKE ALL ON FUNCTION private.tg_booking_broadcast(), private.tg_mechanic_location_broadcast(),
    private.tg_chat_broadcast() FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 15. MAINTENANCE (every 10 min): expired rate limits, old security events
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
END;
$$;
REVOKE ALL ON FUNCTION private.maintenance() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'speedy-maintenance';
    PERFORM cron.schedule('speedy-maintenance', '*/10 * * * *', 'SELECT private.maintenance();');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available (%).', SQLERRM;
END;
$$;

-- -----------------------------------------------------------------------------
-- 16. FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.create_booking_v2(UUID, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.cancel_booking(UUID),
    public.cancel_booking_v2(UUID, TEXT),
    public.customer_refresh_start_otp(UUID),
    public.submit_booking_review_v2(UUID, INT, TEXT, TEXT[]),
    public.customer_get_mechanic_card(UUID),
    public.mechanic_accept_booking(UUID),
    public.mechanic_release_job(UUID, TEXT),
    public.mechanic_start_job(UUID, TEXT),
    public.mechanic_get_customer_contact(UUID),
    public.mechanic_get_active_job_v2(),
    public.mechanic_complete_job_v2(UUID, INT, TEXT),
    public.mechanic_get_stats_v2(),
    public.mechanic_get_open_requests_v4(INT),
    public.get_nearby_mechanics(DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT),
    public.send_booking_message(UUID, TEXT),
    public.get_booking_messages(UUID, TIMESTAMPTZ),
    public.customer_save_place(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.customer_delete_place(UUID),
    public.customer_attach_voice_note(UUID, TEXT, INT),
    public.mark_booking_paid(UUID, TEXT, TEXT),
    public.delete_account_data(UUID)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
    public.create_booking_secure(TEXT, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.create_booking_v2(UUID, TEXT[], TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.cancel_booking(UUID),
    public.cancel_booking_v2(UUID, TEXT),
    public.customer_refresh_start_otp(UUID),
    public.submit_booking_review_v2(UUID, INT, TEXT, TEXT[]),
    public.customer_get_mechanic_card(UUID),
    public.mechanic_accept_booking(UUID),
    public.mechanic_release_job(UUID, TEXT),
    public.mechanic_start_job(UUID, TEXT),
    public.mechanic_get_customer_contact(UUID),
    public.mechanic_get_active_job_v2(),
    public.mechanic_complete_job_v2(UUID, INT, TEXT),
    public.mechanic_get_stats_v2(),
    public.mechanic_get_open_requests_v4(INT),
    public.get_nearby_mechanics(DOUBLE PRECISION, DOUBLE PRECISION, INT, TEXT),
    public.send_booking_message(UUID, TEXT),
    public.get_booking_messages(UUID, TIMESTAMPTZ),
    public.customer_save_place(TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, UUID),
    public.customer_delete_place(UUID),
    public.customer_attach_voice_note(UUID, TEXT, INT)
TO authenticated;

REVOKE EXECUTE ON FUNCTION public.mark_booking_paid(UUID, TEXT, TEXT), public.delete_account_data(UUID) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.mark_booking_paid(UUID, TEXT, TEXT), public.delete_account_data(UUID) TO service_role;

-- Trigger functions are never called directly.
REVOKE EXECUTE ON FUNCTION public.tg_set_updated_at(), public.tg_sync_booking_geo(), public.tg_sync_mechanic_geo()
    FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
