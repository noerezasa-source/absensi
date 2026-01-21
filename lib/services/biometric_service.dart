import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/biometric_data.dart';
import 'face_recognition_tflite_service.dart';
import 'offline_database_service.dart';
import '../helpers/timezone_helper.dart';

class BiometricService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();

  static const double defaultThreshold = 0.75; 

  // ✅ PERFORMANCE: Static instances to persist across multiple BiometricService creations
  // This prevents reloading the heavy TFLite model and Isolate on every match
  static FaceRecognitionTFLiteService? _persistentFaceService;
  
  // ✅ NEW: Expose shared service to prevent multiple model loads in memory
  Future<FaceRecognitionTFLiteService> getFaceService() async {
    if (_persistentFaceService == null) {
      debugPrint('🚀 Initializing shared persistent face service...');
      _persistentFaceService = FaceRecognitionTFLiteService();
      await _persistentFaceService!.initialize();
    }
    return _persistentFaceService!;
  }
  
  static List<Map<String, dynamic>>? _memoryTemplateCache;
  static Map<int, Map<String, dynamic>>? _parsedTemplateCache;
  static int? _cachedOrganizationId;
  static DateTime? _cacheTimestamp;
  static const Duration _cacheExpiry = Duration(minutes: 30);

  // ✅ LOGGER Helper
  static void _logMatch(String? name, double similarity, double threshold, bool accepted) {
    final emoji = accepted ? '✅' : '❌';
    debugPrint('$emoji MATCH: ${name ?? "Unknown"} (${(similarity*100).toStringAsFixed(1)}% vs ${(threshold*100).toInt()}%)');
  }


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
      
      // \u2705 NEW: Log ISO compliance features for version 3.1
      if (version == 3.1) {
        debugPrint('\u2705 ISO/IEC Compliant Template:');
        debugPrint('  - Biometric Metrics: ${faceTemplate['biometricMetrics'] != null}');
        debugPrint('  - Quality Metrics: ${faceTemplate['qualityMetrics'] != null}');
        debugPrint('  - Liveness Detection: ${faceTemplate['livenessDetection'] != null}');
        debugPrint('  - Pose Information: ${faceTemplate['poseInformation'] != null}');
      }
      
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
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
        // ❌ REMOVED: 'template_version': version,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      debugPrint('✅ Face template registered with version $version');
      
      // ✅ Cache Invalidation: Clear cache so next identification fetches new data
      _memoryTemplateCache = null;
      _parsedTemplateCache = null;

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
  
    // ✅ CHECK MEMORY CACHE EXPIRY
    if (_memoryTemplateCache != null && 
        _cachedOrganizationId == organizationId &&
        _cacheTimestamp != null &&
        DateTime.now().difference(_cacheTimestamp!) < _cacheExpiry) {
      debugPrint('✅ Using fresh memory cache (age: ${DateTime.now().difference(_cacheTimestamp!).inMinutes}min)');
      return _memoryTemplateCache!;
    }

    // Clear stale cache
    if (_cacheTimestamp != null && 
        DateTime.now().difference(_cacheTimestamp!) >= _cacheExpiry) {
      debugPrint('🔄 Cache expired, reloading templates...');
      _memoryTemplateCache = null;
      _parsedTemplateCache = null;
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
      saveToCache(List<Map<String, dynamic>>.from(results)); // Removed unawaited to fix lint if needed, or import dart:async code
      _cacheTimestamp = DateTime.now(); // SET TIMESTAMP
      
      // Log template versions from JSON
      final versions = <int, int>{};
      for (final result in results) {
        try {
          final templateData = jsonDecode(result['template_data']);
          final version = (templateData['version'] as num?)?.toInt() ?? 2; // ✅ FIXED: Safe cast from num
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

  // ✅ NEW: Manual cache refresh
  Future<void> refreshCache(int organizationId) async {
    _memoryTemplateCache = null;
    _parsedTemplateCache = null;
    _cacheTimestamp = null;
    await getAllActiveFaceTemplatesWithUserInfo(organizationId);
  }

  Future<Map<String, dynamic>?> identifyBestMatchWithUserInfo({
    required Map<String, dynamic> capturedTemplate,
    required int organizationId,
    required double threshold,
    bool strict = false,
  }) async {
    try {
      final startTime = DateTime.now();
      debugPrint('=== IDENTIFYING BEST MATCH (OPTIMIZED) ===');

      // 1. Initialize Service ONCE
      final faceService = await getFaceService();

      // 2. Load and Cache Templates ONCE (per session/org)
      if (_memoryTemplateCache == null || _cachedOrganizationId != organizationId) {
        debugPrint('📥 Loading templates into memory cache for Org $organizationId...');
        _memoryTemplateCache = await getAllActiveFaceTemplatesWithUserInfo(organizationId);
        _cachedOrganizationId = organizationId;
        
        // Pre-parse JSON to avoid decoding in the loop
        _parsedTemplateCache = {};
        for (var template in _memoryTemplateCache!) {
          try {
            _parsedTemplateCache![template['id']] = jsonDecode(template['template_data']);
          } catch (e) {
            debugPrint('⚠️ Error parsing template ${template['id']}: $e');
          }
        }
        debugPrint('✅ Cached ${_parsedTemplateCache!.length} parsed templates in memory');
      }

      final capturedVersion = (capturedTemplate['version'] as num?)?.toInt() ?? 3;
      final capturedQuality = (capturedTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;

      // ✅ USE PASSED THRESHOLD: Don't override with hardcoded values
      double effectiveThreshold = threshold;

      // ❌ REMOVED: Threshold penalty for poor quality (prevents distant recognition)
      /*
      if (strict) {
        if (capturedQuality < 0.55) { 
          effectiveThreshold += 0.05; 
        }
      }
      */
      
      // ✅ DYNAMIC GAP: Adjust based on similarity strength and quality
      // Lower similarity or quality = need bigger gap to be confident
      double minSimilarityGap = 0.05; // Base gap
      
      if (strict) {
        // If similarity is low, require bigger gap to avoid ambiguity
        minSimilarityGap = 0.05; // Will be adjusted dynamically per match
      }

      // ✅ IMPROVED: Lowered quality rejection threshold for distance
      if (strict && capturedQuality < 0.40) { // Reduced from 0.55 to 0.40 for faster distant recognition
         debugPrint('❌ Strict match rejected: very low quality (${(capturedQuality*100).toInt()}%)');
         return null;
      }

      if (_memoryTemplateCache!.isEmpty) {
        debugPrint('No registered faces found in cache');
        return null;
      }

      Map<String, dynamic>? bestMatch;
      double highestSimilarity = 0.0;
      double secondHighestSimilarity = 0.0;
      String? secondBestName;
      Map<String, dynamic>? secondBestMatch;

      // 3. Fast Comparison Loop
      for (var template in _memoryTemplateCache!) {
        // Skip calling DB/JSON decode - use memory cache
        final registeredTemplate = _parsedTemplateCache![template['id']];
        if (registeredTemplate == null) continue;

        // --- Core Comparison Logic ---
        final templateVersion = (registeredTemplate['version'] as num?)?.toInt() ?? 2;
        
        // v5 (single-embedding) and v4 (multi-embedding) are based on the same model
        // they must be allowed to match each other. 
        bool isW600K(int v) => v == 5 || v == 4;
        
        if (isW600K(capturedVersion) && !isW600K(templateVersion)) continue;
        if (isW600K(templateVersion) && !isW600K(capturedVersion)) continue;

        // Legacy compatibility
        if (!isW600K(capturedVersion) && !isW600K(templateVersion)) {
          if (capturedVersion != templateVersion && 
              !(capturedVersion == 3 && templateVersion == 2)) {
             continue; 
          }
        }

        double similarity = 0.0;
        int bestTemplateIdx = -1;

        if (templateVersion == 4 && registeredTemplate['templates'] != null) {
            final templates = registeredTemplate['templates'] as List;
            double maxSimilarity = 0.0;
            for (int i = 0; i < templates.length; i++) {
              final storedTemplate = templates[i];
              final templateSim = faceService.compareFaces(capturedTemplate, storedTemplate);
              if (templateSim > maxSimilarity) {
                maxSimilarity = templateSim;
                bestTemplateIdx = i;
              }
            }
            similarity = maxSimilarity;
        } else if (capturedVersion == 4 && capturedTemplate['templates'] != null) {
            final capturedTemplates = capturedTemplate['templates'] as List;
            double totalSimilarity = 0.0;
            double totalWeight = 0.0;
            for (int i = 0; i < capturedTemplates.length; i++) {
              final capTemplate = capturedTemplates[i];
              final templateSim = faceService.compareFaces(capTemplate, registeredTemplate);
              final weight = i == 0 ? 0.5 : 0.25;
              totalSimilarity += templateSim * weight;
              totalWeight += weight;
            }
            similarity = totalWeight > 0 ? totalSimilarity / totalWeight : 0.0;
        } else {
            similarity = faceService.compareFaces(capturedTemplate, registeredTemplate);
        }
        
        // Debug Log only for reasonable matches to reduce noise
        if (similarity > 0.3) {
           String angleInfo = '';
           if (bestTemplateIdx != -1) {
             final angles = ['Front', 'Left', 'Right', 'Up', 'Down'];
             final angleName = bestTemplateIdx < angles.length ? angles[bestTemplateIdx] : 'Angle $bestTemplateIdx';
             angleInfo = ' [$angleName]';
           } 
           debugPrint('🔍 Match Candidate: ${template['id']} (V$templateVersion)$angleInfo - Sim: ${similarity.toStringAsFixed(3)} vs Thr: $effectiveThreshold');
        }

        if (similarity > highestSimilarity) {
          secondHighestSimilarity = highestSimilarity;
          secondBestName = bestMatch?['user_name'];
          highestSimilarity = similarity;
          
          if (similarity >= effectiveThreshold) {
             final orgMember = template['organization_members'];
             final userProfile = orgMember['user_profiles'];
             final dept = orgMember['departments'];
             
             final angles = ['Front', 'Left', 'Right', 'Up', 'Down'];
             final matchedAngle = bestTemplateIdx != -1 && bestTemplateIdx < angles.length 
                 ? angles[bestTemplateIdx] 
                 : (bestTemplateIdx != -1 ? 'Angle $bestTemplateIdx' : 'Single');

             bestMatch = {
                'organization_member_id': template['organization_member_id'],
                'biometric_id': template['id'],
                'similarity': similarity,
                'organization_id': orgMember['organization_id'],
                'user_id': orgMember['user_id'],
                'employee_id': orgMember['employee_id'],
                'user_name': (userProfile['display_name'] ?? '').toString().isEmpty 
                    ? '${userProfile['first_name']} ${userProfile['last_name']}' 
                    : userProfile['display_name'],
                'first_name': userProfile['first_name'],
                'last_name': userProfile['last_name'],
                'profile_photo_url': userProfile['profile_photo_url'],
                'department_name': dept != null ? dept['name'] : null,
                'template_version': templateVersion,
                'threshold': effectiveThreshold,
                'matched_angle': matchedAngle, // ✅ Pass matched angle to UI/Logs
             };
          }
        } else if (similarity > secondHighestSimilarity) {
           secondHighestSimilarity = similarity;
           final orgMember = template['organization_members'];
           final userProfile = orgMember['user_profiles'];
           secondBestName = userProfile['display_name'] ?? '${userProfile['first_name']}';
           // Populate secondBestMatch with details of the current template
           final dept = orgMember['departments'];
           secondBestMatch = {
              'organization_member_id': template['organization_member_id'],
              'biometric_id': template['id'],
              'similarity': similarity,
              'organization_id': orgMember['organization_id'],
              'user_id': orgMember['user_id'],
              'employee_id': orgMember['employee_id'],
              'user_name': (userProfile['display_name'] ?? '').toString().isEmpty 
                  ? '${userProfile['first_name']} ${userProfile['last_name']}' 
                  : userProfile['display_name'],
              'first_name': userProfile['first_name'],
              'last_name': userProfile['last_name'],
              'profile_photo_url': userProfile['profile_photo_url'],
              'department_name': dept != null ? dept['name'] : null,
              'template_version': templateVersion,
              'threshold': effectiveThreshold,
              'matched_angle': 'Single', // Default for second best if not explicitly tracked
           };
        }
      }

      // 4. Final Verification
      if (bestMatch != null) {
        _logMatch(bestMatch['user_name'], highestSimilarity, effectiveThreshold, true);
        if (secondBestName != null) {
           debugPrint('🥈 Runner Up: $secondBestName (${(secondHighestSimilarity*100).toStringAsFixed(1)}%)');
        }
        
        if (highestSimilarity < effectiveThreshold) {
          debugPrint('❌ Rejected: Below threshold');
          return null;
        }

        // ✅ IMPROVED AMBIGUITY CHECK: Dynamic gap based on similarity & quality
        if (secondHighestSimilarity > 0.0) {
          final similarityGap = highestSimilarity - secondHighestSimilarity;
          
          // ✅ DYNAMIC GAP: Adjust based on both quality AND similarity strength
          double adjustedGap = minSimilarityGap;
          
          // Rule 1: Low quality needs bigger gap
          if (capturedQuality < 0.65) {
            adjustedGap = 0.10; // 10% gap for poor quality
          } else if (capturedQuality < 0.75) {
            adjustedGap = 0.08; // 8% gap for medium quality
          } else {
            adjustedGap = 0.06; // 6% gap for good quality
          }
          
          // Rule 2: Low similarity needs even bigger gap
          if (highestSimilarity < 0.80) {
            adjustedGap = math.max(adjustedGap, 0.10); // At least 10% gap
          } else if (highestSimilarity < 0.85) {
            adjustedGap = math.max(adjustedGap, 0.08); // At least 8% gap
          }
          
          if (similarityGap < adjustedGap) {
            debugPrint('❌ Ambiguous match rejected:');
            debugPrint('   Top match: ${bestMatch['user_name']} (${(highestSimilarity*100).toStringAsFixed(1)}%)');
            debugPrint('   Second match: ${secondBestMatch?['user_name']} (${(secondHighestSimilarity*100).toStringAsFixed(1)}%)');
            debugPrint('   Gap: ${(similarityGap*100).toStringAsFixed(2)}% < required ${(adjustedGap*100).toStringAsFixed(2)}%');
            debugPrint('   Quality: ${(capturedQuality*100).toInt()}%');
            debugPrint('   Similarity: ${(highestSimilarity*100).toStringAsFixed(1)}%');
            debugPrint('💡 Suggestion: Try again with better lighting or different angle');
            
            // Log for monitoring
            _logAmbiguousMatch(
              bestMatch['user_name'],
              secondBestMatch?['user_name'],
              highestSimilarity,
              secondHighestSimilarity,
              capturedQuality,
            );
            return null;
          }
          
          debugPrint('✅ Clear match: gap ${(similarityGap*100).toStringAsFixed(2)}% >= ${(adjustedGap*100).toStringAsFixed(2)}%');
        }
      } else {
         debugPrint('❌ No match found.');
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
            'last_used_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
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
          final version = (templateData['version'] as num?)?.toInt() ?? 2;
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
        'w600k_templates': versionCounts[5] ?? 0,
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
          final version = (templateData['version'] as num?)?.toInt() ?? 2;
          
          if (version != 5) {
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

      debugPrint('Found $oldCount old templates (version != 5)');
      return oldCount;
    } catch (e) {
      debugPrint('Error in migration check: $e');
      return 0;
    }
  }

  void dispose() {
    debugPrint('BiometricService disposed');
  }

  // ✅ MONITORING: Log ambiguous matches for analysis
  void _logAmbiguousMatch(
    String? topMatch,
    String? secondMatch,
    double topSimilarity,
    double secondSimilarity,
    double quality,
  ) {
    debugPrint('📊 AMBIGUOUS MATCH LOG:');
    debugPrint('   Candidates: $topMatch vs $secondMatch');
    debugPrint('   Scores: ${(topSimilarity * 100).toStringAsFixed(1)}% vs ${(secondSimilarity * 100).toStringAsFixed(1)}%');
    debugPrint('   Gap: ${((topSimilarity - secondSimilarity) * 100).toStringAsFixed(2)}%');
    debugPrint('   Quality: ${(quality * 100).toInt()}%');
    debugPrint('   Timestamp: ${DateTime.now().toIso8601String()}');
  }
}