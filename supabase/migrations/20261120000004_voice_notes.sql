-- =============================================================================
-- 8SpeedyService — Migration 000004: customer voice notes
-- -----------------------------------------------------------------------------
-- The customer can record a short voice note (max ~60 s, AAC/M4A, <= 1 MB)
-- describing the vehicle problem. It is stored in a PRIVATE bucket.
--
-- Who can listen:
--   * the customer who recorded it
--   * verified mechanics who can currently SEE that open request
--     (online, right vehicle type, within 15 km, request still searching)
--   * the mechanic who accepted the job (while the job is active)
--
-- Upload path: <customer uid>/<booking id>_<unix ms>.m4a
-- Safe to run more than once.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. COLUMNS
-- -----------------------------------------------------------------------------
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS voice_note_path TEXT;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS voice_note_seconds INT;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bookings_voice_note_seconds_range') THEN
        ALTER TABLE public.bookings ADD CONSTRAINT bookings_voice_note_seconds_range
            CHECK (voice_note_seconds IS NULL OR voice_note_seconds BETWEEN 1 AND 90);
    END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_bookings_voice_note_path
    ON public.bookings (voice_note_path) WHERE voice_note_path IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 2. PRIVATE BUCKET (audio only, 1 MB max)
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('voice-notes', 'voice-notes', FALSE, 1048576,
        ARRAY['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac'])
ON CONFLICT (id) DO UPDATE
   SET public = FALSE,
       file_size_limit = EXCLUDED.file_size_limit,
       allowed_mime_types = EXCLUDED.allowed_mime_types;

-- -----------------------------------------------------------------------------
-- 3. POLICY HELPERS — in a schema that is NOT exposed through the REST API
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

-- May the caller upload this object? Only into their own folder, only for
-- their own active booking without a voice note, max 3 attempts per booking.
CREATE OR REPLACE FUNCTION private.can_upload_voice_note(p_name TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_parts TEXT[];
    v_booking UUID;
BEGIN
    IF v_uid IS NULL OR p_name IS NULL THEN
        RETURN FALSE;
    END IF;
    v_parts := regexp_match(p_name, '^([0-9a-f-]{36})/([0-9a-f-]{36})_[0-9]{10,16}\.m4a$');
    IF v_parts IS NULL OR v_parts[1] <> v_uid::TEXT THEN
        RETURN FALSE;
    END IF;
    BEGIN
        v_booking := v_parts[2]::UUID;
    EXCEPTION WHEN others THEN
        RETURN FALSE;
    END;
    RETURN EXISTS (
               SELECT 1 FROM public.bookings b
                WHERE b.id = v_booking
                  AND b.customer_id = v_uid
                  AND b.voice_note_path IS NULL
                  AND b.status IN ('SEARCHING', 'ACCEPTED', 'ARRIVED')
                  AND b.created_at > NOW() - INTERVAL '1 day')
       AND (SELECT COUNT(*) FROM storage.objects o
             WHERE o.bucket_id = 'voice-notes'
               AND starts_with(o.name, v_uid::TEXT || '/' || v_booking::TEXT || '_')) < 3;
END;
$$;

-- May the caller listen to this object?
CREATE OR REPLACE FUNCTION private.can_read_voice_note(p_name TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_b public.bookings%ROWTYPE;
    v_m public.mechanics%ROWTYPE;
BEGIN
    IF v_uid IS NULL OR p_name IS NULL THEN
        RETURN FALSE;
    END IF;
    -- The customer's own folder.
    IF starts_with(p_name, v_uid::TEXT || '/') THEN
        RETURN TRUE;
    END IF;

    SELECT * INTO v_b FROM public.bookings WHERE voice_note_path = p_name;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    SELECT * INTO v_m FROM public.mechanics WHERE user_id = v_uid AND is_verified = TRUE;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Mechanic who accepted the job.
    IF v_b.mechanic_id = v_m.id THEN
        RETURN v_b.status IN ('ACCEPTED', 'ARRIVED', 'IN_PROGRESS');
    END IF;

    -- Mechanics who can currently see the open request.
    RETURN v_b.status = 'SEARCHING'
       AND v_b.mechanic_id IS NULL
       AND v_b.payment_status IN ('FREE_OFFER', 'PAID')
       AND v_m.is_online
       AND v_m.current_location IS NOT NULL
       AND v_b.vehicle_type = ANY (v_m.vehicle_specialties)
       AND NOT (v_m.id = ANY (COALESCE(v_b.released_by, ARRAY[]::UUID[])))
       AND ST_DWithin(v_b.pickup_location, v_m.current_location, 15000);
END;
$$;

REVOKE ALL ON FUNCTION private.can_upload_voice_note(TEXT), private.can_read_voice_note(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_upload_voice_note(TEXT), private.can_read_voice_note(TEXT)
    TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. STORAGE POLICIES (no UPDATE / DELETE for app users)
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS voice_notes_insert_own ON storage.objects;
CREATE POLICY voice_notes_insert_own ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'voice-notes' AND private.can_upload_voice_note(name));

DROP POLICY IF EXISTS voice_notes_select_allowed ON storage.objects;
CREATE POLICY voice_notes_select_allowed ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'voice-notes' AND private.can_read_voice_note(name));

-- -----------------------------------------------------------------------------
-- 5. RPCs
-- -----------------------------------------------------------------------------

-- Customer links an uploaded voice note to their booking.
CREATE OR REPLACE FUNCTION public.customer_attach_voice_note(
    p_booking_id UUID,
    p_path TEXT,
    p_seconds INT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_b public.bookings%ROWTYPE;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Please login again.' USING ERRCODE = '28000';
    END IF;
    SELECT * INTO v_b FROM public.bookings
     WHERE id = p_booking_id AND customer_id = v_uid
     FOR UPDATE;
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
    IF NOT EXISTS (
        SELECT 1 FROM storage.objects
         WHERE bucket_id = 'voice-notes' AND name = p_path
           AND (owner_id = v_uid::TEXT OR owner = v_uid)) THEN
        RAISE EXCEPTION 'Voice note upload not found. Please try again.';
    END IF;

    UPDATE public.bookings
       SET voice_note_path = p_path,
           voice_note_seconds = LEAST(GREATEST(COALESCE(p_seconds, 1), 1), 90)
     WHERE id = p_booking_id;

    RETURN jsonb_build_object('attached', TRUE);
END;
$$;

-- Open requests + voice note (v2 stays for older Partner app installs).
CREATE OR REPLACE FUNCTION public.mechanic_get_open_requests_v3(p_radius_meters INT DEFAULT 10000)
RETURNS TABLE (
    booking_id UUID, vehicle_type TEXT, issue_tags TEXT[], issue_note TEXT,
    pickup_address TEXT, pickup_lat DOUBLE PRECISION, pickup_lng DOUBLE PRECISION,
    distance_meters DOUBLE PRECISION, created_at TIMESTAMPTZ,
    vehicle_label TEXT, vehicle_body_type TEXT,
    voice_note_path TEXT, voice_note_seconds INT
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
           split_part(b.vehicle_label, ' • ', 1), b.vehicle_body_type,
           b.voice_note_path, b.voice_note_seconds
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

-- Active job + voice note (same JSON keys as before, two new ones).
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
               'voice_note_path', b.voice_note_path, 'voice_note_seconds', b.voice_note_seconds,
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

REVOKE EXECUTE ON FUNCTION
    public.customer_attach_voice_note(UUID, TEXT, INT),
    public.mechanic_get_open_requests_v3(INT)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
    public.customer_attach_voice_note(UUID, TEXT, INT),
    public.mechanic_get_open_requests_v3(INT)
TO authenticated;
