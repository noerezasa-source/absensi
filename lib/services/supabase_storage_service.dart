import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseStorageService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Upload foto attendance
  Future<String> uploadAttendancePhoto(
    File imageFile,
    int organizationMemberId,
    String type, // 'check_in' atau 'check_out'
  ) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${organizationMemberId}_${type}_$timestamp.jpg';
      
      // Path dengan user ID di depan untuk RLS policy
      final filePath = '${user.id}/$fileName';

      await _supabase.storage
          .from('photo-attendance')
          .upload(filePath, imageFile);

      final publicUrl = _supabase.storage
          .from('photo-attendance')
          .getPublicUrl(filePath);

      return publicUrl;
    } catch (e) {
      throw Exception('Failed to upload attendance photo: $e');
    }
  }

  // Upload face template
  Future<String> uploadFaceTemplate(
    File imageFile,
    int organizationMemberId,
  ) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${organizationMemberId}_template_$timestamp.jpg';
      
      // FIX: Use organizationMemberId folder so photos are grouped by member, not by the petugas who registered them.
      // This assumes RLS allows writing to folders based on member_id (or is public/service role).
      final filePath = '$organizationMemberId/$fileName';

      await _supabase.storage
          .from('face-templates')
          .upload(filePath, imageFile);

      final publicUrl = _supabase.storage
          .from('face-templates')
          .getPublicUrl(filePath);

      return publicUrl;
    } catch (e) {
      throw Exception('Failed to upload face template: $e');
    }
  }

  // Delete file dari storage
  Future<void> deleteFile(String bucketName, String filePath) async {
    try {
      await _supabase.storage.from(bucketName).remove([filePath]);
    } catch (e) {
      throw Exception('Failed to delete file: $e');
    }
  }

  // Get file URL dari storage
  String getPublicUrl(String bucketName, String filePath) {
    return _supabase.storage.from(bucketName).getPublicUrl(filePath);
  }
}