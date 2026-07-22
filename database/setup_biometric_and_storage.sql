-- ============================================================
-- ABSENSI MASSAL V1 - COMPLETE DATABASE SETUP
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- ============================================================
-- STEP 1: Buat helper Security Definer Functions
-- (Diperlukan sebelum membuat RLS policies)
-- ============================================================

-- Tambahkan kolom department_id & position_id ke organization_members jika belum ada
ALTER TABLE public.organization_members
  ADD COLUMN IF NOT EXISTS department_id INTEGER REFERENCES public.departments(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS position_id INTEGER REFERENCES public.positions(id) ON DELETE SET NULL;

-- Hapus fungsi lama jika ada
DROP FUNCTION IF EXISTS public.get_user_organizations(UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_petugas_of_org(UUID, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.share_organization(UUID, UUID) CASCADE;
DROP FUNCTION IF EXISTS public.is_petugas_of_member(UUID, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS public.is_petugas_of_member(UUID, BIGINT) CASCADE;

-- Fungsi 1: Daftar organisasi tempat user bergabung
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

-- Fungsi 2: Cek apakah user adalah Petugas/Admin di organisasi
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

-- Fungsi 3: Cek apakah dua user berada di organisasi yang sama
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

-- Fungsi 4: Cek apakah user adalah Petugas untuk seorang anggota (support BIGINT untuk kompatibilitas)
CREATE OR REPLACE FUNCTION public.is_petugas_of_member(p_user_id UUID, p_member_id BIGINT)
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
  WHERE id = p_member_id::INTEGER;

  IF v_org_id IS NULL THEN
    RETURN FALSE;
  END IF;

  RETURN public.is_petugas_of_org(p_user_id, v_org_id);
END;
$$;

-- Alias dengan INTEGER juga (untuk backward compatibility)
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

-- ============================================================
-- STEP 2: Isi data system_roles jika kosong
-- ============================================================
INSERT INTO public.system_roles (id, code, name, description)
VALUES
  (1, 'SA001', 'Super Admin', 'Super Administrator dengan akses penuh'),
  (2, 'P001',  'Petugas',     'Petugas / Admin Organisasi'),
  (3, 'US001', 'User',        'Pengguna / Karyawan biasa')
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- STEP 3: Setup RLS pada tabel utama
-- ============================================================
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

-- Drop semua policy lama
DO $$
DECLARE pol RECORD;
BEGIN
  FOR pol IN
    SELECT tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('organization_members', 'user_profiles', 'organizations', 'departments', 'positions')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
  END LOOP;
END;
$$;

-- Organizations: semua bisa lihat
CREATE POLICY "orgs_select" ON public.organizations FOR SELECT USING (true);

-- Departments & Positions: semua bisa lihat
ALTER TABLE public.departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.positions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "departments_select" ON public.departments FOR SELECT USING (true);
CREATE POLICY "positions_select" ON public.positions FOR SELECT USING (true);

-- Organization Members: anggota se-organisasi bisa saling lihat
CREATE POLICY "om_select_same_org" ON public.organization_members FOR SELECT
  USING (organization_id IN (SELECT org_id FROM public.get_user_organizations(auth.uid())));

CREATE POLICY "om_insert_self" ON public.organization_members FOR INSERT
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "om_update_self_or_petugas" ON public.organization_members FOR UPDATE
  USING (user_id = auth.uid() OR public.is_petugas_of_org(auth.uid(), organization_id));

CREATE POLICY "om_delete_petugas" ON public.organization_members FOR DELETE
  USING (public.is_petugas_of_org(auth.uid(), organization_id));

-- User Profiles: lihat profil sendiri atau se-organisasi
CREATE POLICY "profiles_select_same_org" ON public.user_profiles FOR SELECT
  USING (id = auth.uid() OR public.share_organization(auth.uid(), id));

CREATE POLICY "profiles_insert_self" ON public.user_profiles FOR INSERT
  WITH CHECK (id = auth.uid());

CREATE POLICY "profiles_update_self" ON public.user_profiles FOR UPDATE
  USING (id = auth.uid());

-- ============================================================
-- STEP 4: Buat tabel biometric_data
-- ============================================================
CREATE TABLE IF NOT EXISTS public.biometric_data (
  id                     SERIAL       PRIMARY KEY,
  organization_member_id INTEGER      NOT NULL REFERENCES public.organization_members(id) ON DELETE CASCADE,
  biometric_type         VARCHAR(50)  NOT NULL DEFAULT 'face_recognition',
  template_data          TEXT,
  enrollment_date        TIMESTAMPTZ  DEFAULT NOW(),
  last_used_at           TIMESTAMPTZ,
  is_active              BOOLEAN      DEFAULT TRUE,
  created_at             TIMESTAMPTZ  DEFAULT NOW(),
  updated_at             TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_biometric_data_member_id
  ON public.biometric_data(organization_member_id);
CREATE INDEX IF NOT EXISTS idx_biometric_data_active
  ON public.biometric_data(is_active, biometric_type);

-- ============================================================
-- STEP 5: RLS untuk biometric_data
-- ============================================================
ALTER TABLE public.biometric_data ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "biometric_select" ON public.biometric_data;
DROP POLICY IF EXISTS "biometric_insert" ON public.biometric_data;
DROP POLICY IF EXISTS "biometric_update" ON public.biometric_data;
DROP POLICY IF EXISTS "biometric_delete" ON public.biometric_data;

CREATE POLICY "biometric_select" ON public.biometric_data FOR SELECT
  USING (
    organization_member_id IN (
      SELECT id FROM public.organization_members WHERE user_id = auth.uid()
    )
    OR public.is_petugas_of_member(auth.uid(), organization_member_id::BIGINT)
  );

CREATE POLICY "biometric_insert" ON public.biometric_data FOR INSERT
  WITH CHECK (
    organization_member_id IN (
      SELECT id FROM public.organization_members WHERE user_id = auth.uid()
    )
    OR public.is_petugas_of_member(auth.uid(), organization_member_id::BIGINT)
  );

CREATE POLICY "biometric_update" ON public.biometric_data FOR UPDATE
  USING (
    organization_member_id IN (
      SELECT id FROM public.organization_members WHERE user_id = auth.uid()
    )
    OR public.is_petugas_of_member(auth.uid(), organization_member_id::BIGINT)
  );

CREATE POLICY "biometric_delete" ON public.biometric_data FOR DELETE
  USING (public.is_petugas_of_member(auth.uid(), organization_member_id::BIGINT));

-- ============================================================
-- STEP 6: Buat Storage Buckets
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('face-templates', 'face-templates', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO storage.buckets (id, name, public)
VALUES ('photo-attendance', 'photo-attendance', true)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS
DROP POLICY IF EXISTS "face_templates_select" ON storage.objects;
DROP POLICY IF EXISTS "face_templates_insert" ON storage.objects;
DROP POLICY IF EXISTS "photo_attendance_select" ON storage.objects;
DROP POLICY IF EXISTS "photo_attendance_insert" ON storage.objects;

CREATE POLICY "face_templates_select" ON storage.objects
  FOR SELECT USING (bucket_id = 'face-templates');

CREATE POLICY "face_templates_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'face-templates' AND auth.role() = 'authenticated');

CREATE POLICY "photo_attendance_select" ON storage.objects
  FOR SELECT USING (bucket_id = 'photo-attendance');

CREATE POLICY "photo_attendance_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'photo-attendance' AND auth.role() = 'authenticated');

-- ============================================================
-- STEP 7: Verifikasi
-- ============================================================
SELECT 'OK: biometric_data table created' AS status
WHERE EXISTS (SELECT FROM pg_tables WHERE schemaname='public' AND tablename='biometric_data');

SELECT 'OK: is_petugas_of_member function exists' AS status
WHERE EXISTS (SELECT FROM pg_proc WHERE proname='is_petugas_of_member');

SELECT 'OK: face-templates bucket' AS status, id, name, public
FROM storage.buckets WHERE id = 'face-templates';

SELECT 'OK: photo-attendance bucket' AS status, id, name, public
FROM storage.buckets WHERE id = 'photo-attendance';
