-- ============================================================
-- SCRIPT UNTUK MEMAKSA PERBAIKAN RELASI BIOMETRIC_DATA
-- ============================================================

-- 1. Hapus constraint lama jika ada (mencegah error)
ALTER TABLE IF EXISTS public.biometric_data
  DROP CONSTRAINT IF EXISTS biometric_data_organization_member_id_fkey;

-- 2. Tambahkan ulang Foreign Key yang benar
ALTER TABLE IF EXISTS public.biometric_data
  ADD CONSTRAINT biometric_data_organization_member_id_fkey
  FOREIGN KEY (organization_member_id) REFERENCES public.organization_members(id) ON DELETE CASCADE;

-- 3. RELOAD SCHEMA CACHE (PENTING!)
NOTIFY pgrst, 'reload schema';
