import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/biometric_data.dart';
import 'face_recognition_tflite_service.dart';
import 'offline_database_service.dart';

class BiometricService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();

  static const double defaultThreshold = 0.75; // ✅ Lowered from 0.80 to 0.75 for better recognition

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
      
      // Check if this is multi-template (version 4)
      final isMultiTemplate = version == 4;
      if (isMultiTemplate) {
        final templates = faceTemplate['templates'] as List?;
        debugPrint('Multi-template registration: ${templates?.length ?? 0} templates');
      }

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
    Future<List<Map<String, dynamic>>> loadFromCache() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString('cached_face_templates_org_$organizationId');
        if (cached == null || cached.isEmpty) return [];
        final decoded = jsonDecode(cached);
        if (decoded is List) {
          return List<Map<String, dynamic>>.from(decoded);
        }
      } catch (e) {
        debugPrint('⚠️ Failed to load cached face templates: $e');
      }
      return [];
    }

    Future<void> saveToCache(List<Map<String, dynamic>> templates) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'cached_face_templates_org_$organizationId',
          jsonEncode(templates),
        );
      } catch (e) {
        debugPrint('⚠️ Failed to cache face templates: $e');
      }
    }

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
              department_id,
              user_profiles!inner (
                id,
                first_name,
                last_name,
                display_name,
                profile_photo_url
              ),
              departments!organization_members_department_id_fkey (
                id,
                name
              )
            )
          ''')
          .eq('biometric_type', 'face_recognition')
          .eq('is_active', true)
          .eq('organization_members.organization_id', organizationId);

      debugPrint('Total templates found: ${results.length}');
      // cache for offline usage
      unawaited(saveToCache(List<Map<String, dynamic>>.from(results)));
      
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

      // Cache biometric data for offline validation
      for (var template in results) {
        await _offlineDb.cacheBiometricData(
          organizationMemberId: template['organization_member_id'],
          biometricType: 'face_recognition',
          templateData: template['template_data'],
        );
      }

      return List<Map<String, dynamic>>.from(results);
    } catch (e) {
      debugPrint('!!! ERROR fetching templates: $e');
      debugPrint('📴 Offline mode detected, trying to load from SQLite...');
      
      // ✅ IMPROVED: Try SQLite biometric_data first (more reliable than SharedPreferences)
      try {
        final sqliteData = await _offlineDb.getAllBiometricDataWithUserInfo(
          organizationId: organizationId,
        );
        
        if (sqliteData.isNotEmpty) {
          debugPrint('✅ Using biometric data from SQLite (${sqliteData.length} templates)');
          return sqliteData;
        }
      } catch (sqliteError) {
        debugPrint('⚠️ Failed to load from SQLite: $sqliteError');
      }
      
      // Fallback to SharedPreferences cache
      final cached = await loadFromCache();
      if (cached.isNotEmpty) {
        debugPrint('✅ Using cached face templates from SharedPreferences (${cached.length})');
        return cached;
      }
      
      debugPrint('❌ No biometric data available offline');
      return [];
    }
  }

  Future<Map<String, dynamic>?> identifyBestMatchWithUserInfo({
    required Map<String, dynamic> capturedTemplate,
    required int organizationId,
    required double threshold,
    bool strict = false,
  }) async {
    try {
      debugPrint('=== IDENTIFYING BEST MATCH (TFLite) ===');
      debugPrint('Organization ID: $organizationId');
      debugPrint('Threshold: ${(threshold * 100).toStringAsFixed(0)}%');

      // ✅ STRICT: Higher threshold to prevent false matches
      final effectiveThreshold = strict ? (threshold < 0.80 ? 0.80 : threshold) : (threshold < 0.80 ? 0.80 : threshold);
      final minSimilarityGap = strict ? 0.15 : 0.12; // ✅ INCREASED: Larger gap required to prevent ambiguous matches
      if (strict) {
        debugPrint('Strict matching: ON (threshold ${(effectiveThreshold * 100).toStringAsFixed(0)}%, gap ${(minSimilarityGap * 100).toStringAsFixed(0)}%)');
      }

      final capturedVersion = capturedTemplate['version'] ?? 3;
      debugPrint('Captured template version: $capturedVersion');

      if (strict) {
        final capturedQuality = (capturedTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
        if (capturedQuality < 0.80) {
          debugPrint('❌ Strict match rejected: captured quality too low (${capturedQuality.toStringAsFixed(2)})');
          return null;
        }
      }

      final allTemplates = await getAllActiveFaceTemplatesWithUserInfo(organizationId);

      if (allTemplates.isEmpty) {
        debugPrint('No registered faces found in organization');
        return null;
      }

      final faceService = FaceRecognitionTFLiteService();
      await faceService.initialize();

      Map<String, dynamic>? bestMatch;
      double highestSimilarity = 0.0;
      double secondHighestSimilarity = 0.0;
      String? secondBestName;

      for (var template in allTemplates) {
        try {
          final registeredTemplate = jsonDecode(template['template_data']);
          final templateVersion = registeredTemplate['version'] ?? 2; // Read from JSON
          
          // Check version compatibility
          // Allow: v3 with v3, v4 with v4, v3 captured with v4 stored (multi-template)
          if (capturedVersion != templateVersion && 
              !(capturedVersion == 3 && templateVersion == 4)) {
            // Skip incompatible versions (v2 or others)
            if (capturedVersion < 3 || templateVersion < 3) {
              debugPrint('⚠️  Version mismatch: captured=$capturedVersion, stored=$templateVersion');
              continue;
            }
          }

          // Handle multi-template (version 4 stored template)
          double similarity = 0.0;
          if (templateVersion == 4 && registeredTemplate['templates'] != null) {
            // ✅ IMPROVED: Multi-template matching with max + front boost
            // Compare captured template with all 3 stored templates (front, left, right)
            // Use max similarity but give boost if front template matches well
            final templates = registeredTemplate['templates'] as List;
            double maxSimilarity = 0.0;
            double frontSimilarity = 0.0;
            
            for (int i = 0; i < templates.length; i++) {
              final storedTemplate = templates[i] as Map<String, dynamic>;
              final templateSim = faceService.compareFaces(
                capturedTemplate,
                storedTemplate,
              );
              
              if (i == 0) {
                frontSimilarity = templateSim; // Store front template similarity
              }
              
              if (templateSim > maxSimilarity) {
                maxSimilarity = templateSim;
              }
            }
            
            // ✅ REMOVED BOOST: Use max similarity directly to prevent false positives
            // Boost was causing multiple people to match with high similarity
            similarity = maxSimilarity;
            debugPrint('✅ Multi-template match: ${(similarity * 100).toStringAsFixed(2)}% (max from ${templates.length} templates, front: ${(frontSimilarity * 100).toStringAsFixed(2)}%)');
          } else if (capturedVersion == 4 && capturedTemplate['templates'] != null) {
            // If captured is also multi-template (unlikely but handle it)
            // Compare all captured templates with registered template and take weighted average
            final capturedTemplates = capturedTemplate['templates'] as List;
            double totalSimilarity = 0.0;
            double totalWeight = 0.0;
            
            for (int i = 0; i < capturedTemplates.length; i++) {
              final capTemplate = capturedTemplates[i] as Map<String, dynamic>;
              final templateSim = faceService.compareFaces(
                capTemplate,
                registeredTemplate,
              );
              
              final weight = i == 0 ? 0.5 : 0.25;
              totalSimilarity += templateSim * weight;
              totalWeight += weight;
            }
            
            similarity = totalWeight > 0 ? totalSimilarity / totalWeight : 0.0;
          } else {
            // Single template comparison (version 3 or old version)
            similarity = faceService.compareFaces(
              capturedTemplate,
              registeredTemplate,
            );
          }

          final orgMember = template['organization_members'];
          final userProfile = orgMember['user_profiles'];
          final dept = orgMember['departments'];
          
          final firstName = userProfile['first_name'] ?? '';
          final lastName = userProfile['last_name'] ?? '';
          final displayName = userProfile['display_name'] ?? '$firstName $lastName';
          
          debugPrint('Comparing with: $displayName, Similarity: ${(similarity * 100).toStringAsFixed(2)}%');

          // ✅ CRITICAL FIX: Track ALL similarities (above and below threshold)
          // This ensures we correctly calculate gap even when second best is below threshold
          // Example: top1=80.47%, top2=76.68% (below 80% threshold) -> gap=3.79% (should reject!)
          if (similarity > highestSimilarity) {
            // New best match found - move old best to second
            secondHighestSimilarity = highestSimilarity;
            secondBestName = bestMatch?['user_name'] as String?;

            highestSimilarity = similarity;

            // Only set as bestMatch if above threshold
            if (similarity >= effectiveThreshold) {
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
                'department_name': dept != null ? (dept['name'] as String?) : null,
                'template_version': templateVersion, // From JSON
              };
            }
          } else if (similarity > secondHighestSimilarity) {
            // New second best match (regardless of threshold)
            secondHighestSimilarity = similarity;
            secondBestName = displayName.trim();
          }
        } catch (e) {
          debugPrint('Error processing template: $e');
          continue;
        }
      }

      faceService.dispose();

      if (bestMatch != null) {
        // ✅ STRICT: Reject if gap is too small (multiple people match too closely)
        final similarityGap = highestSimilarity - secondHighestSimilarity;
        
        // ✅ ADDITIONAL CHECK: Require minimum similarity above threshold
        if (highestSimilarity < effectiveThreshold) {
          debugPrint('❌ Match rejected: similarity ${(highestSimilarity * 100).toStringAsFixed(2)}% below threshold ${(effectiveThreshold * 100).toStringAsFixed(0)}%');
          return null;
        }
        
        // ✅ STRICT: Always reject if gap is too small (ambiguous match)
        // This prevents 1 face from matching multiple people
        if (secondHighestSimilarity > 0.0 && similarityGap < minSimilarityGap) {
          debugPrint(
            '⚠️ Ambiguous match rejected: top1=${(highestSimilarity * 100).toStringAsFixed(2)}% (${bestMatch['user_name']}) '
            'top2=${(secondHighestSimilarity * 100).toStringAsFixed(2)}% (${secondBestName ?? "-"}) '
            'gap=${(similarityGap * 100).toStringAsFixed(2)}% (required: ${(minSimilarityGap * 100).toStringAsFixed(0)}%)',
          );
          return null;
        }
        
        // ✅ FINAL CHECK: If second highest is also above threshold and gap is small, reject
        // This is an extra safety check for ambiguous matches
        if (secondHighestSimilarity >= effectiveThreshold && similarityGap < (minSimilarityGap * 1.5)) {
          debugPrint(
            '⚠️ Ambiguous match rejected (both above threshold): top1=${(highestSimilarity * 100).toStringAsFixed(2)}% (${bestMatch['user_name']}) '
            'top2=${(secondHighestSimilarity * 100).toStringAsFixed(2)}% (${secondBestName ?? "-"}) '
            'gap=${(similarityGap * 100).toStringAsFixed(2)}%',
          );
          return null;
        }
        
        debugPrint('✅ Best match found: ${bestMatch['user_name']} with ${(bestMatch['similarity'] * 100).toStringAsFixed(2)}% similarity (gap: ${(similarityGap * 100).toStringAsFixed(2)}%, second: ${(secondHighestSimilarity * 100).toStringAsFixed(2)}%)');
      } else {
        debugPrint('❌ No match found above threshold ${(effectiveThreshold * 100).toStringAsFixed(0)}%');
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