-- ============================================================
-- AUTOMATIC BACKFILL: LINK LATEST FRONT FACE PHOTOS TO USER PROFILES
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- STEP 1: Pastikan tabel user_profiles ada
CREATE TABLE IF NOT EXISTS public.user_profiles (
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

-- STEP 2: Buat row user_profiles untuk semua member yang belum punya row profil
INSERT INTO public.user_profiles (id, email, created_at, updated_at)
SELECT DISTINCT
  om.user_id,
  au.email,
  NOW(),
  NOW()
FROM public.organization_members om
JOIN auth.users au ON au.id = om.user_id
WHERE om.user_id IS NOT NULL
ON CONFLICT (id) DO NOTHING;

-- STEP 3: Update profile_photo_url dengan foto FRONT terbaru dari storage bucket
UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Ardyansa/1_template_front_1784474305125.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 1);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Amri/15_template_front_1784169940793.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 15);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Jordi/20_template_front_1784106269259.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 20);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Juhri/21_template_front_1784166960652.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 21);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Fawwas%20Sigma/22_template_front_1784166834075.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 22);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Erlangga/23_template_front_1784166638980.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 23);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Ragung/24_template_front_1784516110993.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 24);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Lazuardi/25_template_front_1784166706104.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 25);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Kahfi/26_template_front_1784163922115.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 26);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Reza/27_template_front_1784164720589.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 27);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Bagas/28_template_front_1784164767717.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 28);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Rafa/29_template_front_1784518928763.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 29);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Alwan/30_template_front_1784107879533.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 30);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Harits/31_template_front_1784107514279.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 31);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Fortun/32_template_front_1784163864452.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 32);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Kuba/33_template_front_1784164478387.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 33);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Meira/34_template_front_1784165131867.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 34);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Sulianto/35_template_front_1784165493856.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 35);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Bima/36_template_front_1784518884963.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 36);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Panji%20Petualang/37_template_front_1784538151924.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 37);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Putra/38_template_front_1784538388230.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 38);

UPDATE public.user_profiles
SET profile_photo_url = 'https://oovtwiioyejefifsgrtj.supabase.co/storage/v1/object/public/face-templates/Andika/39_template_front_1784538593705.jpg', updated_at = NOW()
WHERE id = (SELECT user_id FROM public.organization_members WHERE id = 39);

-- STEP 4: Reload schema cache PostgREST
NOTIFY pgrst, 'reload schema';

SELECT 'OK: Synchronized member profile photos successfully' AS status;