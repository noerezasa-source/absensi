-- ============================================================
-- QUICK FIX: Fix biometric_data schema
-- Jalankan di Supabase SQL Editor
-- ============================================================

-- Lihat schema tabel biometric_data yang ada sekarang
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'biometric_data'
ORDER BY ordinal_position;

-- FIX: Hapus NOT NULL constraint pada organization_id
-- (karena organization_member_id sudah menyimpan FK ke organization_members
--  yang sudah memiliki organization_id — jadi redundant)
ALTER TABLE public.biometric_data
  ALTER COLUMN organization_id DROP NOT NULL;

-- Verifikasi hasilnya
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' 
  AND table_name = 'biometric_data'
  AND column_name = 'organization_id';
