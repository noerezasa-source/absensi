-- ============================================================
-- ABSENSI MASSAL V1 - DATABASE SECURITY & SCHEMA MATCH FIX
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- STEP 1: FIX SCHEMA MISMATCH (Tambahkan department_id & position_id jika belum ada)
-- Flutter mengharuskan kolom ini ada di tabel organization_members
ALTER TABLE public.organization_members 
  ADD COLUMN IF NOT EXISTS department_id INTEGER REFERENCES public.departments(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS position_id INTEGER REFERENCES public.positions(id) ON DELETE SET NULL;

-- STEP 2: Hapus helper functions lama jika ada
DROP FUNCTION IF EXISTS public.get_org_member_ids(TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.get_user_organizations(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_petugas_of_org(UUID, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.share_organization(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_petugas_of_member(UUID, INTEGER) CASCADE;

-- STEP 3: Buat Security Definer Helper Functions
-- Fungsi-fungsi ini berjalan dengan hak akses penuh (SECURITY DEFINER)
-- untuk menghindari RLS recursion saat mengecek database.

-- 1. Mendapatkan daftar organization_id tempat user bergabung
CREATE OR REPLACE FUNCTION public.get_user_organizations(p_user_id UUID)
RETURNS TABLE(org_id INTEGER)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT organization_id
  FROM organization_members
  WHERE user_id = p_user_id
    AND is_active = true;
$$;

-- 2. Mengecek apakah user adalah Petugas/Admin di organisasi tersebut
CREATE OR REPLACE FUNCTION public.is_petugas_of_org(p_user_id UUID, p_org_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1
    FROM organization_members om
    JOIN system_roles sr ON sr.id = om.role_id
    WHERE om.user_id = p_user_id
      AND om.organization_id = p_org_id
      AND om.is_active = true
      AND sr.code IN ('P001', 'SA001')
  );
END;
$$;

-- 3. Mengecek apakah User A dan User B berada di organisasi yang sama
CREATE OR REPLACE FUNCTION public.share_organization(p_user_a UUID, p_user_b UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM organization_members a
    JOIN organization_members b ON a.organization_id = b.organization_id
    WHERE a.user_id = p_user_a
      AND b.user_id = p_user_b
      AND a.is_active = true
      AND b.is_active = true
  );
$$;

-- 4. Mengecek apakah user adalah Petugas untuk seorang anggota tertentu
CREATE OR REPLACE FUNCTION public.is_petugas_of_member(p_user_id UUID, p_member_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_org_id INTEGER;
BEGIN
  SELECT organization_id INTO v_org_id
  FROM organization_members
  WHERE id = p_member_id;
  
  IF v_org_id IS NULL THEN
    RETURN FALSE;
  END IF;
  
  RETURN public.is_petugas_of_org(p_user_id, v_org_id);
END;
$$;

-- STEP 4: Hapus SEMUA policy lama pada tabel-tabel utama secara dinamis
DO $$
DECLARE
  pol RECORD;
BEGIN
  FOR pol IN
    SELECT tablename, policyname 
    FROM pg_policies 
    WHERE schemaname = 'public' 
      AND tablename IN ('organization_members', 'user_profiles', 'attendance_records', 'attendance_logs', 'organizations', 'departments', 'positions')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
  END LOOP;
END;
$$;

-- STEP 5: Aktifkan Row Level Security (RLS)
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.positions ENABLE ROW LEVEL SECURITY;

-- STEP 6: Buat RLS Policies BARU menggunakan Security Definer Helpers

-- 1. ORGANIZATIONS
CREATE POLICY "orgs_select" ON public.organizations FOR SELECT USING (true);

-- 2. DEPARTMENTS & POSITIONS
CREATE POLICY "departments_select" ON public.departments FOR SELECT USING (true);
CREATE POLICY "positions_select" ON public.positions FOR SELECT USING (true);

-- 3. ORGANIZATION MEMBERS
-- Anggota boleh melihat semua anggota yang se-organisasi dengan mereka
CREATE POLICY "om_select_same_org" ON public.organization_members FOR SELECT
  USING (organization_id IN (SELECT org_id FROM public.get_user_organizations(auth.uid())));

-- User boleh daftarkan dirinya sendiri
CREATE POLICY "om_insert_self" ON public.organization_members FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- User boleh update datanya sendiri OR Petugas organisasi boleh update data anggotanya
CREATE POLICY "om_update_self_or_petugas" ON public.organization_members FOR UPDATE
  USING (user_id = auth.uid() OR public.is_petugas_of_org(auth.uid(), organization_id));

-- Hanya Petugas organisasi yang boleh mendelete/mengeluarkan anggota
CREATE POLICY "om_delete_petugas" ON public.organization_members FOR DELETE
  USING (public.is_petugas_of_org(auth.uid(), organization_id));

-- 4. USER PROFILES
-- User boleh melihat profilnya sendiri ATAU profil orang lain yang se-organisasi dengannya
CREATE POLICY "profiles_select_same_org" ON public.user_profiles FOR SELECT
  USING (id = auth.uid() OR public.share_organization(auth.uid(), id));

CREATE POLICY "profiles_insert_self" ON public.user_profiles FOR INSERT
  WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update_self" ON public.user_profiles FOR UPDATE
  USING (id = auth.uid());

-- 5. ATTENDANCE RECORDS
-- Karyawan bisa melihat data absennya sendiri, Petugas bisa melihat data absen semua anggota organisasinya
CREATE POLICY "records_select" ON public.attendance_records FOR SELECT
  USING (
    organization_member_id IN (SELECT id FROM public.organization_members WHERE user_id = auth.uid())
    OR public.is_petugas_of_member(auth.uid(), organization_member_id)
  );

CREATE POLICY "records_insert" ON public.attendance_records FOR INSERT
  WITH CHECK (
    organization_member_id IN (SELECT id FROM public.organization_members WHERE user_id = auth.uid())
    OR public.is_petugas_of_member(auth.uid(), organization_member_id)
  );

CREATE POLICY "records_update" ON public.attendance_records FOR UPDATE
  USING (
    organization_member_id IN (SELECT id FROM public.organization_members WHERE user_id = auth.uid())
    OR public.is_petugas_of_member(auth.uid(), organization_member_id)
  );

-- 6. ATTENDANCE LOGS
CREATE POLICY "logs_select" ON public.attendance_logs FOR SELECT
  USING (
    organization_member_id IN (SELECT id FROM public.organization_members WHERE user_id = auth.uid())
    OR public.is_petugas_of_member(auth.uid(), organization_member_id)
  );

CREATE POLICY "logs_insert" ON public.attendance_logs FOR INSERT
  WITH CHECK (
    organization_member_id IN (SELECT id FROM public.organization_members WHERE user_id = auth.uid())
    OR public.is_petugas_of_member(auth.uid(), organization_member_id)
  );

-- STEP 7: Isi data default system_roles jika kosong
INSERT INTO public.system_roles (id, code, name, description)
VALUES
  (1, 'SA001', 'Super Admin', 'Super Administrator dengan akses penuh'),
  (2, 'P001',  'Petugas',     'Petugas / Admin Organisasi'),
  (3, 'US001', 'User',        'Pengguna / Karyawan biasa')
ON CONFLICT (id) DO NOTHING;
