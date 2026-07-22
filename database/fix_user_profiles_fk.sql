-- ============================================================
-- SAFE FIX: Tambahkan FK user_profiles tanpa hapus FK lama
-- Jalankan di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- STEP 1: Lihat semua FK yang ada di organization_members sekarang
SELECT
  tc.constraint_name,
  kcu.column_name,
  ccu.table_schema || '.' || ccu.table_name AS foreign_table,
  ccu.column_name AS foreign_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name = 'organization_members';

-- STEP 2: Buat user_profiles untuk semua member yang belum punya
INSERT INTO public.user_profiles (id, email, created_at, updated_at)
SELECT DISTINCT
  om.user_id,
  au.email,
  NOW(),
  NOW()
FROM public.organization_members om
JOIN auth.users au ON au.id = om.user_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_profiles up WHERE up.id = om.user_id
);

-- STEP 3: Tambahkan FK baru (TANPA menghapus FK lama ke auth.users)
-- Hapus dulu jika sudah ada (idempotent)
ALTER TABLE public.organization_members
  DROP CONSTRAINT IF EXISTS organization_members_user_profiles_fkey;

ALTER TABLE public.organization_members
  ADD CONSTRAINT organization_members_user_profiles_fkey
  FOREIGN KEY (user_id) REFERENCES public.user_profiles(id) ON DELETE CASCADE;

-- STEP 4: Reload schema cache PostgREST
NOTIFY pgrst, 'reload schema';

-- STEP 5: Verifikasi FK baru ada
SELECT
  tc.constraint_name,
  kcu.column_name,
  ccu.table_schema || '.' || ccu.table_name AS foreign_table,
  ccu.column_name AS foreign_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_name = 'organization_members';

-- STEP 6: Lihat berapa banyak anggota dan user_profiles yang ada
SELECT
  'organization_members' AS tabel, COUNT(*) FROM public.organization_members
UNION ALL
SELECT
  'user_profiles', COUNT(*) FROM public.user_profiles;
