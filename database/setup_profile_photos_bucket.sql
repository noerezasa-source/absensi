-- ============================================================
-- SETUP PROFILE PHOTOS BUCKET
-- Jalankan script ini di Supabase SQL Editor -> New Query -> Run
-- ============================================================

-- Create the profile-photos bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('profile-photos', 'profile-photos', true)
ON CONFLICT (id) DO NOTHING;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "profile_photos_select" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_insert" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_update" ON storage.objects;
DROP POLICY IF EXISTS "profile_photos_delete" ON storage.objects;

-- Policy: Allow authenticated users to select (view) profile photos
CREATE POLICY "profile_photos_select" ON storage.objects
  FOR SELECT USING (bucket_id = 'profile-photos');

-- Policy: Allow authenticated users to upload profile photos
CREATE POLICY "profile_photos_insert" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'profile-photos' AND auth.role() = 'authenticated');

-- Policy: Allow users to update their own profile photos
CREATE POLICY "profile_photos_update" ON storage.objects
  FOR UPDATE USING (bucket_id = 'profile-photos' AND auth.role() = 'authenticated');

-- Policy: Allow users to delete their own profile photos
CREATE POLICY "profile_photos_delete" ON storage.objects
  FOR DELETE USING (bucket_id = 'profile-photos' AND auth.role() = 'authenticated');

-- Verification
SELECT 'OK: profile-photos bucket created' AS status, id, name, public
FROM storage.buckets WHERE id = 'profile-photos';
