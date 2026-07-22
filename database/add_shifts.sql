-- ============================================
-- Tambah 3 Shift Baru ke tabel 'shifts'
-- Jalankan di Supabase SQL Editor
-- ============================================

-- Ambil organization_id dari organisasi yang ada
DO $$
DECLARE
  org_id UUID;
BEGIN
  -- Ambil organization_id pertama yang aktif
  SELECT id INTO org_id FROM organizations WHERE is_active = true LIMIT 1;

  IF org_id IS NULL THEN
    RAISE EXCEPTION 'Tidak ada organisasi aktif ditemukan!';
  END IF;

  RAISE NOTICE 'Organization ID: %', org_id;

  -- Shift 1: 11:30 - 12:30
  INSERT INTO shifts (organization_id, code, name, start_time, end_time, overnight, break_duration_minutes, color_code, is_active)
  VALUES (org_id, 'SHIFT1', 'Shift 1', '11:30:00', '12:30:00', false, 0, '#4CAF50', true)
  ON CONFLICT DO NOTHING;

  -- Shift 2: 15:30 - 16:00
  INSERT INTO shifts (organization_id, code, name, start_time, end_time, overnight, break_duration_minutes, color_code, is_active)
  VALUES (org_id, 'SHIFT2', 'Shift 2', '15:30:00', '16:00:00', false, 0, '#2196F3', true)
  ON CONFLICT DO NOTHING;

  -- Shift 3 (Lembur): 16:30 - 20:00
  INSERT INTO shifts (organization_id, code, name, start_time, end_time, overnight, break_duration_minutes, color_code, is_active)
  VALUES (org_id, 'LEMBUR', 'Lembur', '16:30:00', '20:00:00', false, 0, '#FF9800', true)
  ON CONFLICT DO NOTHING;

  RAISE NOTICE 'Berhasil menambahkan 3 shift!';
END $$;

-- Verifikasi hasilnya
SELECT id, code, name, start_time, end_time, color_code, is_active
FROM shifts
ORDER BY start_time;
