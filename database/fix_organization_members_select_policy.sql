-- ============================================================
-- ABSENSI MASSAL V1 - SQL MIGRATION: JOIN ORGANIZATION RLS FIX
-- Run this in your Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- Create policy to allow users to select their own membership records (even if inactive/unapproved)
CREATE POLICY "om_select_own" 
ON public.organization_members 
FOR SELECT 
USING (user_id = auth.uid());

-- Output success message
DO $$
BEGIN
  RAISE NOTICE '✅ Policy "om_select_own" successfully applied to public.organization_members';
END $$;
