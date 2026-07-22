-- ============================================================
-- SCRIPT UNTUK MEMBUAT DATA DUMMY CEPAT
-- Jalankan script ini di Supabase SQL Editor
-- ============================================================

-- 1. Buat Organisasi Dummy
INSERT INTO public.organizations (name, address, email, is_active)
VALUES ('PT Absensi Cepat', 'Jl. Sudirman No 1', 'admin@absensicepat.com', true)
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  v_org_id INTEGER;
  v_my_user_id UUID;
  v_role_petugas INTEGER;
  v_role_user INTEGER;
  v_dummy_id_1 UUID := gen_random_uuid();
  v_dummy_id_2 UUID := gen_random_uuid();
  v_dummy_id_3 UUID := gen_random_uuid();
BEGIN
  -- Ambil ID Organisasi yang baru dibuat
  SELECT id INTO v_org_id FROM public.organizations WHERE name = 'PT Absensi Cepat' LIMIT 1;

  -- Ambil ID Role
  SELECT id INTO v_role_petugas FROM public.system_roles WHERE code = 'P001' LIMIT 1;
  SELECT id INTO v_role_user FROM public.system_roles WHERE code = 'US001' LIMIT 1;

  -- Ambil user asli Anda yang sudah register di aplikasi
  SELECT id INTO v_my_user_id FROM auth.users ORDER BY created_at ASC LIMIT 1;

  -- Tambahkan user asli Anda sebagai Petugas (Admin) di organisasi ini
  IF v_my_user_id IS NOT NULL THEN
    INSERT INTO public.organization_members (organization_id, user_id, role_id, employee_id, is_active)
    VALUES (v_org_id, v_my_user_id, v_role_petugas, 'EMP-001', true)
    ON CONFLICT (organization_id, user_id) DO NOTHING;
  END IF;

  -- Buat 3 akun dummy di auth.users (tanpa password, cuma buat list)
  INSERT INTO auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  VALUES 
    (v_dummy_id_1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dummy1@test.com', NOW(), NOW()),
    (v_dummy_id_2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dummy2@test.com', NOW(), NOW()),
    (v_dummy_id_3, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dummy3@test.com', NOW(), NOW());

  -- Buat profil dummy (gunakan ON CONFLICT karena trigger auth.users mungkin sudah membuatnya)
  INSERT INTO public.user_profiles (id, email, display_name, first_name, is_active)
  VALUES 
    (v_dummy_id_1, 'dummy1@test.com', 'Budi Santoso', 'Budi', true),
    (v_dummy_id_2, 'dummy2@test.com', 'Siti Aminah', 'Siti', true),
    (v_dummy_id_3, 'dummy3@test.com', 'Ahmad Faisal', 'Ahmad', true)
  ON CONFLICT (id) DO UPDATE SET 
    display_name = EXCLUDED.display_name,
    first_name = EXCLUDED.first_name;

  -- Masukkan dummy ke organization_members (gunakan ON CONFLICT DO NOTHING)
  INSERT INTO public.organization_members (organization_id, user_id, role_id, employee_id, is_active)
  VALUES 
    (v_org_id, v_dummy_id_1, v_role_user, 'EMP-002', true),
    (v_org_id, v_dummy_id_2, v_role_user, 'EMP-003', true),
    (v_org_id, v_dummy_id_3, v_role_user, 'EMP-004', true)
  ON CONFLICT (organization_id, user_id) DO NOTHING;
    
END $$;
