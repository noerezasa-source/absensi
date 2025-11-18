import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/biometric_data.dart';

class BiometricService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Register face template
  Future<BiometricData> registerFaceTemplate({
    required int organizationMemberId,
    required Map<String, dynamic> faceTemplate,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Convert template to JSON string
      final templateJson = jsonEncode(faceTemplate);

      // Cek apakah sudah ada template aktif
      final existingTemplate = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      if (existingTemplate != null) {
        // Nonaktifkan template lama
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .eq('id', existingTemplate['id']);
      }

      // Insert template baru
      final biometricData = {
        'organization_member_id': organizationMemberId,
        'biometric_type': 'face_recognition',
        'template_data': templateJson,
        'enrollment_date': DateTime.now().toIso8601String(),
        'is_active': true,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      return BiometricData.fromJson(result);
    } catch (e) {
      throw Exception('Failed to register face template: $e');
    }
  }

  // Get active face template
  Future<BiometricData?> getActiveFaceTemplate(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      if (result == null) return null;

      return BiometricData.fromJson(result);
    } catch (e) {
      print('Error getting face template: $e');
      return null;
    }
  }

  // Update last used timestamp
  Future<void> updateLastUsed(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({
            'last_used_at': DateTime.now().toIso8601String(),
          })
          .eq('id', biometricId);
    } catch (e) {
      print('Failed to update last used: $e');
    }
  }

  // Deactivate face template
  Future<void> deactivateFaceTemplate(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({'is_active': false})
          .eq('id', biometricId);
    } catch (e) {
      throw Exception('Failed to deactivate face template: $e');
    }
  }

  // Check if user has registered face
  Future<bool> hasRegisteredFace(int organizationMemberId) async {
    try {
      print('Checking face registration for org member ID: $organizationMemberId');
      
      final result = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      final hasRegistered = result != null;
      print('Has registered face: $hasRegistered');
      
      return hasRegistered;
    } catch (e) {
      print('Error checking face registration: $e');
      return false;
    }
  }
}