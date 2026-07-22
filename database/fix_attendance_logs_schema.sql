-- ============================================================
-- SCRIPT UNTUK MENAMBAHKAN KOLOM EVENT_TIME
-- ============================================================

-- Tambahkan kolom event_time ke tabel attendance_logs
ALTER TABLE IF EXISTS public.attendance_logs
  ADD COLUMN IF NOT EXISTS event_time TIMESTAMPTZ DEFAULT NOW();

-- Update data lama agar event_time terisi (opsional)
UPDATE public.attendance_logs
SET event_time = created_at
WHERE event_time IS NULL;

-- Reload Schema Cache
NOTIFY pgrst, 'reload schema';
