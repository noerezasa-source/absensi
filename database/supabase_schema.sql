-- ============================================================
-- ABSENSI MASSAL V1 - SUPABASE DATABASE SCHEMA
-- Jalankan script ini di Supabase SQL Editor
-- PERHATIAN: Script ini akan DROP semua tabel lama terlebih dahulu
-- ============================================================

-- ============================================================
-- STEP 1: DROP semua tabel lama (urutan penting: child dulu)
-- ============================================================
DROP TABLE IF EXISTS public.attendance_logs       CASCADE;
DROP TABLE IF EXISTS public.attendance_records    CASCADE;
DROP TABLE IF EXISTS public.shift_assignments     CASCADE;
DROP TABLE IF EXISTS public.member_schedules      CASCADE;
DROP TABLE IF EXISTS public.work_schedule_details CASCADE;
DROP TABLE IF EXISTS public.work_schedules        CASCADE;
DROP TABLE IF EXISTS public.shifts                CASCADE;
DROP TABLE IF EXISTS public.organization_members  CASCADE;
DROP TABLE IF EXISTS public.organizations         CASCADE;
DROP TABLE IF EXISTS public.user_profiles         CASCADE;
DROP TABLE IF EXISTS public.system_roles          CASCADE;

-- Drop trigger lama
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

-- ============================================================
-- STEP 2: BUAT TABEL BARU
-- ============================================================

-- 1. SYSTEM ROLES
CREATE TABLE public.system_roles (
  id          SERIAL PRIMARY KEY,
  code        VARCHAR(20)  NOT NULL UNIQUE,
  name        VARCHAR(100) NOT NULL,
  description TEXT,
  is_system   BOOLEAN      DEFAULT TRUE,
  created_at  TIMESTAMPTZ  DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  DEFAULT NOW()
);

INSERT INTO public.system_roles (code, name, description, is_system) VALUES
  ('SA001', 'Super Admin', 'Super Administrator dengan akses penuh', TRUE),
  ('P001',  'Petugas',     'Petugas / Admin Organisasi',             TRUE),
  ('US001', 'User',        'Pengguna / Karyawan biasa',              TRUE);

-- 2. USER PROFILES
CREATE TABLE public.user_profiles (
  id                UUID         PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  first_name        VARCHAR(100),
  last_name         VARCHAR(100),
  display_name      VARCHAR(200),
  email             VARCHAR(255),
  phone             VARCHAR(20),
  profile_photo_url TEXT,
  bio               TEXT,
  is_active         BOOLEAN      DEFAULT TRUE,
  created_at        TIMESTAMPTZ  DEFAULT NOW(),
  updated_at        TIMESTAMPTZ  DEFAULT NOW()
);

-- 3. ORGANIZATIONS
CREATE TABLE public.organizations (
  id          SERIAL       PRIMARY KEY,
  name        VARCHAR(200) NOT NULL,
  description TEXT,
  logo_url    TEXT,
  address     TEXT,
  phone       VARCHAR(20),
  email       VARCHAR(255),
  website     VARCHAR(255),
  inv_code    VARCHAR(50)  UNIQUE,
  is_active   BOOLEAN      DEFAULT TRUE,
  timezone    VARCHAR(50)  DEFAULT 'Asia/Jakarta',
  created_at  TIMESTAMPTZ  DEFAULT NOW(),
  updated_at  TIMESTAMPTZ  DEFAULT NOW()
);

-- 4. ORGANIZATION MEMBERS
CREATE TABLE public.organization_members (
  id                  SERIAL      PRIMARY KEY,
  organization_id     INTEGER     NOT NULL REFERENCES public.organizations(id)  ON DELETE CASCADE,
  user_id             UUID        NOT NULL REFERENCES auth.users(id)            ON DELETE CASCADE,
  role_id             INTEGER     NOT NULL REFERENCES public.system_roles(id),
  employee_id         VARCHAR(50),
  department          VARCHAR(100),
  position            VARCHAR(100),
  hire_date           DATE,
  employment_status   VARCHAR(50) DEFAULT 'active',
  work_location       VARCHAR(50) DEFAULT 'office',
  is_active           BOOLEAN     DEFAULT TRUE,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(organization_id, user_id)
);

-- 5. SHIFTS
CREATE TABLE public.shifts (
  id              SERIAL       PRIMARY KEY,
  organization_id INTEGER      REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            VARCHAR(100) NOT NULL,
  start_time      TIME         NOT NULL,
  end_time        TIME         NOT NULL,
  break_start     TIME,
  break_end       TIME,
  overnight       BOOLEAN      DEFAULT FALSE,
  is_active       BOOLEAN      DEFAULT TRUE,
  created_at      TIMESTAMPTZ  DEFAULT NOW(),
  updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

-- 6. WORK SCHEDULES
CREATE TABLE public.work_schedules (
  id              SERIAL       PRIMARY KEY,
  organization_id INTEGER      NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name            VARCHAR(100) NOT NULL,
  description     TEXT,
  schedule_type   VARCHAR(50)  DEFAULT 'fixed',
  is_default      BOOLEAN      DEFAULT FALSE,
  is_active       BOOLEAN      DEFAULT TRUE,
  created_at      TIMESTAMPTZ  DEFAULT NOW(),
  updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

-- 7. WORK SCHEDULE DETAILS
CREATE TABLE public.work_schedule_details (
  id               SERIAL      PRIMARY KEY,
  work_schedule_id INTEGER     NOT NULL REFERENCES public.work_schedules(id) ON DELETE CASCADE,
  day_of_week      INTEGER     NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  is_working_day   BOOLEAN     DEFAULT TRUE,
  start_time       TIME,
  end_time         TIME,
  break_start      TIME,
  break_end        TIME,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  updated_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(work_schedule_id, day_of_week)
);

-- 8. SHIFT ASSIGNMENTS
CREATE TABLE public.shift_assignments (
  id                       SERIAL      PRIMARY KEY,
  organization_member_id   INTEGER     NOT NULL REFERENCES public.organization_members(id) ON DELETE CASCADE,
  shift_id                 INTEGER     NOT NULL REFERENCES public.shifts(id),
  assignment_date          DATE        NOT NULL,
  created_at               TIMESTAMPTZ DEFAULT NOW(),
  updated_at               TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(organization_member_id, assignment_date)
);

-- 9. MEMBER SCHEDULES
CREATE TABLE public.member_schedules (
  id                     SERIAL      PRIMARY KEY,
  organization_member_id INTEGER     NOT NULL REFERENCES public.organization_members(id) ON DELETE CASCADE,
  work_schedule_id       INTEGER     REFERENCES public.work_schedules(id),
  shift_id               INTEGER     REFERENCES public.shifts(id),
  effective_date         DATE        NOT NULL,
  end_date               DATE,
  created_at             TIMESTAMPTZ DEFAULT NOW(),
  updated_at             TIMESTAMPTZ DEFAULT NOW()
);

-- 10. ATTENDANCE RECORDS
CREATE TABLE public.attendance_records (
  id                       SERIAL      PRIMARY KEY,
  organization_member_id   INTEGER     NOT NULL REFERENCES public.organization_members(id) ON DELETE CASCADE,
  attendance_date          DATE        NOT NULL,
  status                   VARCHAR(50) DEFAULT 'absent',
  actual_check_in          TIMESTAMPTZ,
  actual_check_out         TIMESTAMPTZ,
  actual_break_start       TIMESTAMPTZ,
  actual_break_end         TIMESTAMPTZ,
  check_in_method          VARCHAR(50),
  check_out_method         VARCHAR(50),
  break_out_method         VARCHAR(50),
  break_in_method          VARCHAR(50),
  check_in_photo_url       TEXT,
  check_out_photo_url      TEXT,
  check_in_location        JSONB,
  check_out_location       JSONB,
  late_minutes             INTEGER     DEFAULT 0,
  early_leave_minutes      INTEGER     DEFAULT 0,
  overtime_minutes         INTEGER     DEFAULT 0,
  work_duration_minutes    INTEGER     DEFAULT 0,
  break_out_device_id      INTEGER,
  break_in_device_id       INTEGER,
  validation_status        VARCHAR(50) DEFAULT 'pending',
  notes                    TEXT,
  created_at               TIMESTAMPTZ DEFAULT NOW(),
  updated_at               TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(organization_member_id, attendance_date)
);

-- 11. ATTENDANCE LOGS
CREATE TABLE public.attendance_logs (
  id                     SERIAL      PRIMARY KEY,
  organization_member_id INTEGER     NOT NULL REFERENCES public.organization_members(id) ON DELETE CASCADE,
  attendance_record_id   INTEGER     REFERENCES public.attendance_records(id) ON DELETE CASCADE,
  event_type             VARCHAR(50) NOT NULL,
  method                 VARCHAR(50),
  location               JSONB,
  device_id              INTEGER,
  ip_address             VARCHAR(50),
  user_agent             TEXT,
  application_id         INTEGER,
  raw_data               JSONB,
  created_at             TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- STEP 3: TRIGGER Auto-create user_profiles saat register
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, email, first_name, display_name, is_active)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    TRUE
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ============================================================
-- STEP 4: ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.user_profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizations         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_members  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_roles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_schedules        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.work_schedule_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_assignments     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.member_schedules      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_records    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.attendance_logs       ENABLE ROW LEVEL SECURITY;

-- ---- user_profiles ----
CREATE POLICY "user_profiles_select_own"
  ON public.user_profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "user_profiles_insert_own"
  ON public.user_profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

CREATE POLICY "user_profiles_update_own"
  ON public.user_profiles FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "user_profiles_select_org_members"
  ON public.user_profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS my_om
      JOIN public.organization_members AS target_om
        ON my_om.organization_id = target_om.organization_id
      WHERE my_om.user_id = auth.uid()
        AND target_om.user_id = user_profiles.id
        AND my_om.is_active = TRUE
        AND target_om.is_active = TRUE
    )
  );

-- ---- system_roles ----
CREATE POLICY "system_roles_read"
  ON public.system_roles FOR SELECT
  USING (auth.role() = 'authenticated');

-- ---- organizations ----
CREATE POLICY "organizations_read"
  ON public.organizations FOR SELECT
  USING (auth.role() = 'authenticated' AND is_active = TRUE);

CREATE POLICY "organizations_update_petugas"
  ON public.organizations FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      JOIN public.system_roles AS sr ON sr.id = om.role_id
      WHERE om.organization_id = organizations.id
        AND om.user_id = auth.uid()
        AND om.is_active = TRUE
        AND sr.code IN ('P001', 'SA001')
    )
  );

-- ---- organization_members ----
CREATE POLICY "org_members_select_own"
  ON public.organization_members FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY "org_members_select_same_org"
  ON public.organization_members FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS my_om
      WHERE my_om.organization_id = organization_members.organization_id
        AND my_om.user_id = auth.uid()
        AND my_om.is_active = TRUE
    )
  );

CREATE POLICY "org_members_insert_self"
  ON public.organization_members FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "org_members_update_self"
  ON public.organization_members FOR UPDATE
  USING (user_id = auth.uid());

CREATE POLICY "org_members_petugas_all"
  ON public.organization_members FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS admin_om
      JOIN public.system_roles AS sr ON sr.id = admin_om.role_id
      WHERE admin_om.organization_id = organization_members.organization_id
        AND admin_om.user_id = auth.uid()
        AND admin_om.is_active = TRUE
        AND sr.code IN ('P001', 'SA001')
    )
  );

-- ---- shifts ----
CREATE POLICY "shifts_read_org_members"
  ON public.shifts FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.organization_id = shifts.organization_id
        AND om.user_id = auth.uid()
        AND om.is_active = TRUE
    )
  );

-- ---- work_schedules ----
CREATE POLICY "work_schedules_read"
  ON public.work_schedules FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.organization_id = work_schedules.organization_id
        AND om.user_id = auth.uid()
        AND om.is_active = TRUE
    )
  );

-- ---- work_schedule_details ----
CREATE POLICY "work_schedule_details_read"
  ON public.work_schedule_details FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.work_schedules AS ws
      JOIN public.organization_members AS om ON om.organization_id = ws.organization_id
      WHERE ws.id = work_schedule_details.work_schedule_id
        AND om.user_id = auth.uid()
        AND om.is_active = TRUE
    )
  );

-- ---- shift_assignments ----
CREATE POLICY "shift_assignments_read"
  ON public.shift_assignments FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = shift_assignments.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

-- ---- member_schedules ----
CREATE POLICY "member_schedules_read"
  ON public.member_schedules FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = member_schedules.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

-- ---- attendance_records ----
CREATE POLICY "attendance_records_select"
  ON public.attendance_records FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = attendance_records.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

CREATE POLICY "attendance_records_insert"
  ON public.attendance_records FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = attendance_records.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

CREATE POLICY "attendance_records_update"
  ON public.attendance_records FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = attendance_records.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

CREATE POLICY "attendance_records_petugas"
  ON public.attendance_records FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS admin_om
      JOIN public.system_roles AS sr ON sr.id = admin_om.role_id
      JOIN public.organization_members AS member_om
        ON member_om.id = attendance_records.organization_member_id
      WHERE admin_om.organization_id = member_om.organization_id
        AND admin_om.user_id = auth.uid()
        AND admin_om.is_active = TRUE
        AND sr.code IN ('P001', 'SA001')
    )
  );

-- ---- attendance_logs ----
CREATE POLICY "attendance_logs_insert"
  ON public.attendance_logs FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = attendance_logs.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

CREATE POLICY "attendance_logs_select"
  ON public.attendance_logs FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.organization_members AS om
      WHERE om.id = attendance_logs.organization_member_id
        AND om.user_id = auth.uid()
    )
  );

-- ============================================================
-- SELESAI! Cek Table Editor untuk memastikan tabel sudah muncul.
-- ============================================================
