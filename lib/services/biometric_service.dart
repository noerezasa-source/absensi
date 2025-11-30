import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/biometric_data.dart';
import 'face_recognition_tflite_service.dart';

class BiometricService {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const double defaultThreshold = 0.80;

  Future<BiometricData> registerFaceTemplate({
    required int organizationMemberId,
    required Map<String, dynamic> faceTemplate,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      final templateJson = jsonEncode(faceTemplate);

      // Version is stored INSIDE the JSON, not as separate column
      final version = faceTemplate['version'] ?? 3;
      debugPrint('Registering face template version: $version');

      // Deactivate old templates
      final existingTemplate = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      if (existingTemplate != null) {
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .eq('id', existingTemplate['id']);
      }

      // Insert new template (NO template_version column)
      final biometricData = {
        'organization_member_id': organizationMemberId,
        'biometric_type': 'face_recognition',
        'template_data': templateJson, // Version is inside this JSON
        'enrollment_date': DateTime.now().toIso8601String(),
        'is_active': true,
        // ❌ REMOVED: 'template_version': version,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      debugPrint('✅ Face template registered with version $version');
      return BiometricData.fromJson(result);
    } catch (e) {
      throw Exception('Failed to register face template: $e');
    }
  }

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
      debugPrint('Error getting face template: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllActiveFaceTemplatesWithUserInfo(
    int organizationId,
  ) async {
    try {
      debugPrint('=== FETCHING FACE TEMPLATES (TFLite) ===');
      debugPrint('Organization ID: $organizationId');

      final results = await _supabase
          .from('biometric_data')
          .select('''
            id,
            organization_member_id,
            template_data,
            enrollment_date,
            last_used_at,
            organization_members!inner (
              id,
              user_id,
              organization_id,
              employee_id,
              user_profiles!inner (
                id,
                first_name,
                last_name,
                display_name,
                profile_photo_url
              )
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      debugPrint('Total templates found: ${results.length}');
      
      // Log template versions from JSON
      final versions = <int, int>{};
      for (final result in results) {
        try {
          final templateData = jsonDecode(result['template_data']);
          final version = templateData['version'] ?? 2; // Read from JSON
          versions[version] = (versions[version] ?? 0) + 1;
        } catch (e) {
          debugPrint('Error parsing template: $e');
        }
      }
      debugPrint('Template versions: $versions');

      return List<Map<String, dynamic>>.from(results);
    } catch (e) {
      debugPrint('!!! ERROR fetching templates: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> identifyBestMatchWithUserInfo({
    required Map<String, dynamic> capturedTemplate,
    required int organizationId,
    required double threshold,
  }) async {
    try {
      debugPrint('=== IDENTIFYING BEST MATCH (TFLite) ===');
      debugPrint('Organization ID: $organizationId');
      debugPrint('Threshold: ${(threshold * 100).toStringAsFixed(0)}%');

      final capturedVersion = capturedTemplate['version'] ?? 3;
      debugPrint('Captured template version: $capturedVersion');

      final allTemplates = await getAllActiveFaceTemplatesWithUserInfo(organizationId);

      if (allTemplates.isEmpty) {
        debugPrint('No registered faces found in organization');
        return null;
      }

      final faceService = FaceRecognitionTFLiteService();
      await faceService.initialize();

      Map<String, dynamic>? bestMatch;
      double highestSimilarity = 0.0;

      for (var template in allTemplates) {
        try {
          final registeredTemplate = jsonDecode(template['template_data']);
          final templateVersion = registeredTemplate['version'] ?? 2; // Read from JSON
          
          // Check version compatibility
          if (capturedVersion != templateVersion) {
            debugPrint('⚠️  Version mismatch: captured=$capturedVersion, stored=$templateVersion');
            // Skip incompatible versions (optional - you can try anyway)
            continue;
          }

          final similarity = faceService.compareFaces(
            capturedTemplate,
            registeredTemplate,
          );

          final orgMember = template['organization_members'];
          final userProfile = orgMember['user_profiles'];
          
          final firstName = userProfile['first_name'] ?? '';
          final lastName = userProfile['last_name'] ?? '';
          final displayName = userProfile['display_name'] ?? '$firstName $lastName';
          
          debugPrint('Comparing with: $displayName, Similarity: ${(similarity * 100).toStringAsFixed(2)}%');

          if (similarity >= threshold && similarity > highestSimilarity) {
            highestSimilarity = similarity;
            
            bestMatch = {
              'organization_member_id': template['organization_member_id'],
              'biometric_id': template['id'],
              'similarity': similarity,
              'organization_id': orgMember['organization_id'],
              'user_id': orgMember['user_id'],
              'employee_id': orgMember['employee_id'],
              'user_name': displayName.trim(),
              'first_name': firstName,
              'last_name': lastName,
              'profile_photo_url': userProfile['profile_photo_url'],
              'template_version': templateVersion, // From JSON
            };
          }
        } catch (e) {
          debugPrint('Error processing template: $e');
          continue;
        }
      }

      faceService.dispose();

      if (bestMatch != null) {
        debugPrint('✅ Best match found: ${bestMatch['user_name']} with ${(bestMatch['similarity'] * 100).toStringAsFixed(2)}% similarity');
      } else {
        debugPrint('❌ No match found above threshold ${(threshold * 100).toStringAsFixed(0)}%');
      }

      return bestMatch;
    } catch (e) {
      debugPrint('!!! ERROR in identifyBestMatchWithUserInfo: $e');
      return null;
    }
  }

  Future<void> updateLastUsed(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({
            'last_used_at': DateTime.now().toIso8601String(),
          })
          .eq('id', biometricId);
      
      debugPrint('✅ Updated last_used_at for biometric_id: $biometricId');
    } catch (e) {
      debugPrint('Failed to update last used: $e');
    }
  }

  Future<void> deactivateFaceTemplate(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({'is_active': false})
          .eq('id', biometricId);
      
      debugPrint('✅ Deactivated biometric template: $biometricId');
    } catch (e) {
      throw Exception('Failed to deactivate face template: $e');
    }
  }

  Future<bool> hasRegisteredFace(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .maybeSingle();

      return result != null;
    } catch (e) {
      debugPrint('Error checking face registration: $e');
      return false;
    }
  }

  Future<Map<String, int>> getOrganizationStats(int organizationId) async {
    try {
      debugPrint('=== FETCHING ORGANIZATION STATS ===');

      final registeredData = await _supabase
          .from('biometric_data')
          .select('''
            id,
            template_data,
            organization_members!inner(
              organization_id
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);
      
      final registeredCount = registeredData.length;

      // Count by version (read from JSON)
      final versionCounts = <int, int>{};
      for (final record in registeredData) {
        try {
          final templateData = jsonDecode(record['template_data']);
          final version = templateData['version'] ?? 2;
          versionCounts[version] = (versionCounts[version] ?? 0) + 1;
        } catch (e) {
          debugPrint('Error parsing template: $e');
        }
      }

      final totalMembersData = await _supabase
          .from('organization_members')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('is_active', true);
      
      final totalMembers = totalMembersData.length;

      debugPrint('Registered faces: $registeredCount');
      debugPrint('Version breakdown: $versionCounts');
      debugPrint('Total members: $totalMembers');

      return {
        'registered_faces': registeredCount,
        'total_members': totalMembers,
        'pending_registration': totalMembers - registeredCount,
        'tflite_templates': versionCounts[3] ?? 0,
        'mlkit_templates': versionCounts[2] ?? 0,
      };
    } catch (e) {
      debugPrint('Error getting organization stats: $e');
      return {
        'registered_faces': 0,
        'total_members': 0,
        'pending_registration': 0,
      };
    }
  }

  /// Migrate old templates by marking them as inactive
  Future<int> migrateToTFLite(int organizationId) async {
    try {
      debugPrint('=== CHECKING OLD TEMPLATES ===');
      
      final allData = await _supabase
          .from('biometric_data')
          .select('''
            id,
            organization_member_id,
            template_data,
            organization_members!inner(
              organization_id
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      int oldCount = 0;
      for (final record in allData) {
        try {
          final templateData = jsonDecode(record['template_data']);
          final version = templateData['version'] ?? 2;
          
          if (version != 3) {
            oldCount++;
            // Optionally mark as inactive
            // await _supabase.from('biometric_data')
            //   .update({'is_active': false})
            //   .eq('id', record['id']);
          }
        } catch (e) {
          debugPrint('Error parsing template: $e');
        }
      }

      debugPrint('Found $oldCount old templates (version != 3)');
      return oldCount;
    } catch (e) {
      debugPrint('Error in migration check: $e');
      return 0;
    }
  }

  void dispose() {
    debugPrint('BiometricService disposed');
  }
}