-- ============================================================
-- ADD MISSING COLUMNS TO ATTENDANCE_LOGS TABLE
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- Tambahkan kolom is_verified (default false)
ALTER TABLE public.attendance_logs
  ADD COLUMN IF NOT EXISTS is_verified BOOLEAN DEFAULT FALSE;

-- Tambahkan kolom verification_method (varchar)
ALTER TABLE public.attendance_logs
  ADD COLUMN IF NOT EXISTS verification_method VARCHAR(50);

-- Reload Schema Cache
NOTIFY pgrst, 'reload schema';

SELECT 'OK: Added is_verified and verification_method successfully' AS status;
