-- =============================================================================
-- 8SpeedyService — migration 000011: covering indexes for two foreign keys
-- =============================================================================
-- Supabase performance advisor 0001 (unindexed foreign keys):
-- * booking_messages.mechanic_id — delete_account_data() rewrites a deleted
--   partner's messages by mechanic_id, and the FK check on mechanics needs it.
-- * ai_requests.booking_id — ON DELETE SET NULL from bookings + support queries.
-- Small tables today, so a plain CREATE INDEX is instant. Re-runnable.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_booking_messages_mechanic ON public.booking_messages (mechanic_id);
CREATE INDEX IF NOT EXISTS idx_ai_requests_booking ON public.ai_requests (booking_id);
