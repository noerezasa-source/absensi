-- ============================================================
-- FIX: PERIZINAN UPDATE USER_PROFILES OLEH PETUGAS/ADMIN
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- Grant UPDATE permission ke Petugas yang berada di organisasi yang sama
DROP POLICY IF EXISTS "profiles_update_self" ON public.user_profiles;
DROP POLICY IF EXISTS "profiles_update_self_or_petugas" ON public.user_profiles;

CREATE POLICY "profiles_update_self_or_petugas" ON public.user_profiles
  FOR UPDATE
  USING (
    id = auth.uid() 
    OR public.share_organization(auth.uid(), id)
  );

-- Verifikasi Policy
SELECT policyname, tablename, cmd, qual
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'user_profiles';
