// BiometricService handles both face recognition and fingerprint templates in Supabase.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:objectbox/objectbox.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/biometric_data.dart';
import 'face_recognition_tflite_service.dart';
import '../../services/offline_database_service.dart';
import '../../services/objectbox_service.dart';
import '../../models/karyawan_wajah.dart';
import '../../helpers/timezone_helper.dart';

class BiometricService {
  static final BiometricService _instance = BiometricService._internal();
  factory BiometricService() => _instance;
  BiometricService._internal();

  final SupabaseClient _supabase = Supabase.instance.client;
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();

  static const double defaultThreshold =
      0.3; // ✅ Aligned with Wajah project (was 0.65)
  // ✅ PERFORMANCE: Static instances to persist across multiple BiometricService creations
  // This prevents reloading the heavy TFLite model and Isolate on every match
  static FaceRecognitionTFLiteService? _persistentFaceService;

  // ✅ NEW: Expose shared service to prevent multiple model loads in memory
  Future<FaceRecognitionTFLiteService> getFaceService() async {
    if (_persistentFaceService == null) {
      // debugPrint('🚀 Initializing shared persistent face service...');
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
  static void _logMatch(
    String? name,
    double similarity,
    double threshold,
    bool accepted,
  ) {
    final emoji = accepted ? '✅' : '❌';
    debugPrint(
      '$emoji MATCH: ${name ?? "Unknown"} (${(similarity * 100).toStringAsFixed(1)}% vs ${(threshold * 100).toInt()}%)',
    );
  }

  /// ✅ NEW: Safely get template from cache for evolution
  Map<String, dynamic>? getParsedTemplateFromCache(int biometricId) {
    return _parsedTemplateCache?[biometricId];
  }

  /// ✅ DUPLICATE GUARD: Check if captured face matches an existing DIFFERENT member.
  /// Returns a warning map if the face is already registered to someone else,
  /// or null if it's safe to register.
  Future<Map<String, dynamic>?> verifyFaceAgainstExisting({
    required Map<String, dynamic> faceTemplate,
    required int intendedMemberId,
    required int organizationId,
  }) async {
    try {
      List<double>? queryVector;
      if (faceTemplate['embedding'] != null) {
        queryVector = (faceTemplate['embedding'] as List)
            .map((e) => (e as num).toDouble())
            .toList();
      } else if (faceTemplate['templates'] != null &&
          (faceTemplate['templates'] as List).isNotEmpty) {
        final firstTemp = (faceTemplate['templates'] as List).first;
        if (firstTemp is Map && firstTemp['embedding'] != null) {
          queryVector = (firstTemp['embedding'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
        }
      }

      if (queryVector == null || queryVector.length != 512) return null;

      final nearest = ObjectBoxService().searchNearestNeighbors(
        queryVector,
        maxResultCount: 1,
        organizationId: organizationId,
      );

      if (nearest.isEmpty) return null;

      final best = nearest.first;
      final similarity = 1.0 - best.score;
      final matchedMemberId = best.object.organizationMemberId;
      final matchedName = best.object.namaLengkap;

      // Only warn if it matches a DIFFERENT member with high confidence
      if (matchedMemberId != intendedMemberId && similarity >= 0.50) {
        debugPrint('⚠️ DUPLICATE GUARD: Face matches existing member '
            '$matchedName (ID: $matchedMemberId) at '
            '${(similarity * 100).toStringAsFixed(1)}% — '
            'intended for member ID $intendedMemberId');
        return {
          'matched_member_id': matchedMemberId,
          'matched_name': matchedName,
          'similarity': similarity,
        };
      }

      return null;
    } catch (e) {
      debugPrint('⚠️ verifyFaceAgainstExisting error: $e');
      return null;
    }
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

      // Version is stored INSIDE the JSON template_data, not as a separate column
      // Lookup organization_id dari organization_members (diperlukan oleh beberapa schema DB)
      int? organizationId;
      try {
        final memberRow = await _supabase
            .from('organization_members')
            .select('organization_id')
            .eq('id', organizationMemberId)
            .maybeSingle();
        organizationId = memberRow?['organization_id'] as int?;
      } catch (_) {
        // Jika gagal lookup, biarkan null (jika kolom sudah nullable)
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

      // Insert new template — include organization_id if available
      final biometricData = <String, dynamic>{
        'organization_member_id': organizationMemberId,
        'biometric_type': 'face_recognition',
        'template_data': templateJson,
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
      };
      if (organizationId != null) {
        biometricData['organization_id'] = organizationId;
      }

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      // Save/Update in ObjectBox too
      try {
        final cachedMember = await _offlineDb.findMemberByOrgIdInCache(organizationMemberId);
        final Map<String, dynamic> fullMap = Map.from(result);
        if (cachedMember != null) {
          fullMap['organization_members'] = cachedMember['organization_members'];
        }
        final kw = KaryawanWajah.fromSupabase(fullMap);
        ObjectBoxService().putKaryawanWajah(kw);
        debugPrint('✅ ObjectBox: Registered face template for member ID $organizationMemberId');
      } catch (e) {
        debugPrint('⚠️ ObjectBox failed to save registered face: $e');
      }

      // Cache Invalidation: Clear cache so next identification fetches new data
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

  // === FINGERPRINT METHODS ===

  Future<BiometricData> registerFingerprintTemplate({
    required int organizationMemberId,
    required String templateBase64,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Deactivate old fingerprint templates
      final existingTemplate = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      if (existingTemplate != null) {
        await _supabase
            .from('biometric_data')
            .update({'is_active': false})
            .eq('id', existingTemplate['id']);
      }

      // Insert new template
      final biometricData = {
        'organization_member_id': organizationMemberId,
        'biometric_type': 'fingerprint',
        'template_data': templateBase64,
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      return BiometricData.fromJson(result);
    } catch (e) {
      throw Exception('Failed to register fingerprint template: $e');
    }
  }

  Future<BiometricData?> getActiveFingerprintTemplate(
    int organizationMemberId,
  ) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      if (result == null) return null;

      return BiometricData.fromJson(result);
    } catch (e) {
      debugPrint('Error getting fingerprint template: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllActiveFingerprintTemplates(
    int organizationId,
  ) async {
    // Step 1: Try to load from local SQLite cache first (instant, works offline)
    List<Map<String, dynamic>> cachedTemplates = [];
    try {
      cachedTemplates = await _offlineDb.getAllBiometricDataWithUserInfo(
        organizationId: organizationId,
        biometricType: 'fingerprint',
      );
      if (cachedTemplates.isNotEmpty) {
        debugPrint(
          '📦 Loaded ${cachedTemplates.length} fingerprint templates from SQLite cache',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Failed to read SQLite cache: $e');
    }

    // Step 2: Background sync from Supabase to keep cache fresh
    _syncFingerprintsFromSupabase(organizationId);

    // Step 3: Return cached data immediately if available
    if (cachedTemplates.isNotEmpty) {
      return cachedTemplates;
    }

    // Step 4: If cache is empty (first run), wait for the Supabase fetch
    debugPrint('📴 SQLite cache empty, waiting for Supabase fetch...');
    try {
      final results = await _fetchFingerprintsFromSupabase(organizationId);
      return results;
    } catch (e) {
      debugPrint('❌ Supabase fetch also failed: $e');
      return [];
    }
  }

  /// Fetch fingerprints from Supabase and sync to SQLite
  Future<List<Map<String, dynamic>>> _fetchFingerprintsFromSupabase(
    int organizationId,
  ) async {
    final results = await _supabase
        .from('biometric_data')
        .select('''
          id,
          organization_member_id,
          template_data,
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
        .eq('biometric_type', 'fingerprint')
        .eq('is_active', true)
        .eq('organization_members.organization_id', organizationId);

    return List<Map<String, dynamic>>.from(results);
  }

  /// Background sync: fetch from Supabase and update SQLite (handles deletions)
  void _syncFingerprintsFromSupabase(int organizationId) {
    Future(() async {
      try {
        debugPrint('🔄 Background fingerprint sync for org $organizationId...');
        final templates = await _fetchFingerprintsFromSupabase(organizationId);

        // Full replace: removes deleted entries from SQLite too
        await _offlineDb.syncBiometricData(
          templates,
          biometricType: 'fingerprint',
          organizationId: organizationId,
        );

        // Cache member info for name/photo display
        for (var template in templates) {
          unawaited(
            _offlineDb.cacheMemberData({
              'organization_member_id': template['organization_member_id'],
              'card_number': 'FINGER_${template['organization_member_id']}',
              'organization_members': template['organization_members'],
            }),
          );
        }

        debugPrint(
          '✅ Background fingerprint sync done: ${templates.length} templates cached',
        );
      } catch (e) {
        debugPrint('⚠️ Background sync skipped (offline?): $e');
      }
    });
  }

  Future<bool> hasRegisteredFingerprint(int organizationMemberId) async {
    try {
      final result = await _supabase
          .from('biometric_data')
          .select('id')
          .eq('organization_member_id', organizationMemberId)
          .eq('biometric_type', 'fingerprint')
          .eq('is_active', true)
          .maybeSingle();

      return result != null;
    } catch (e) {
      debugPrint('Error checking fingerprint registration: $e');
      return false;
    }
  }

  Future<void> deactivateFingerprintTemplate(int biometricId) async {
    try {
      await _supabase
          .from('biometric_data')
          .update({'is_active': false})
          .eq('id', biometricId);
    } catch (e) {
      throw Exception('Failed to deactivate fingerprint template: $e');
    }
  }

  // === FACE RECOGNITION METHODS ===

  Future<List<Map<String, dynamic>>> getAllActiveFaceTemplatesWithUserInfo(
    int organizationId,
  ) async {
    // Step 1: Try to load from local SQLite cache first (instant, works offline)
    List<Map<String, dynamic>> cachedTemplates = [];
    try {
      cachedTemplates = await _offlineDb.getAllBiometricDataWithUserInfo(
        organizationId: organizationId,
        biometricType: 'face_recognition',
      );
      if (cachedTemplates.isNotEmpty) {
        debugPrint(
          '📦 Loaded ${cachedTemplates.length} face templates from SQLite cache',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Failed to read SQLite cache: $e');
    }

    // Step 2: Background sync from Supabase to keep cache fresh
    _syncFacesFromSupabase(organizationId);

    // Step 3: Return cached data immediately if available
    if (cachedTemplates.isNotEmpty) {
      // Fill RAM Cache so that identifying works immediately
      _memoryTemplateCache = cachedTemplates;
      _cachedOrganizationId = organizationId;
      
      // Pre-parse JSON to avoid decoding in the loop
      _parsedTemplateCache = {};
      for (var template in cachedTemplates) {
        try {
          final Map<String, dynamic> parsed = jsonDecode(
            template['template_data'],
          );
          // Pre-convert embedding to List<double> for speed
          if (parsed['embedding'] != null) {
            parsed['embedding'] = (parsed['embedding'] as List)
                .map((e) => (e as num).toDouble())
                .toList();
          }
          if (parsed['templates'] != null) {
            final subTemplates = parsed['templates'] as List;
            for (var sub in subTemplates) {
              if (sub is Map && sub['embedding'] != null) {
                sub['embedding'] = (sub['embedding'] as List)
                    .map((e) => (e as num).toDouble())
                    .toList();
              }
            }
          }
          _parsedTemplateCache![template['id']] = parsed;
        } catch (e) {
          debugPrint('⚠️ Error parsing template ${template['id']}: $e');
        }
      }
      _cacheTimestamp = DateTime.now();
      
      // Sync SQLite cache to ObjectBox asynchronously
      unawaited(Future(() => _syncObjectBox(cachedTemplates, organizationId)));
      
      return cachedTemplates;
    }

    // Step 4: If cache is empty (first run), wait for the Supabase fetch
    debugPrint('📴 SQLite cache empty, waiting for Supabase fetch...');
    try {
      final results = await _fetchFacesFromSupabase(organizationId);
      
      // Update memory cache and parse
      _memoryTemplateCache = results;
      _cachedOrganizationId = organizationId;
      _parsedTemplateCache = {};
      for (var template in results) {
        try {
          final Map<String, dynamic> parsed = jsonDecode(
            template['template_data'],
          );
          // Pre-convert embedding to List<double> for speed
          if (parsed['embedding'] != null) {
            parsed['embedding'] = (parsed['embedding'] as List)
                .map((e) => (e as num).toDouble())
                .toList();
          }
          if (parsed['templates'] != null) {
            final subTemplates = parsed['templates'] as List;
            for (var sub in subTemplates) {
              if (sub is Map && sub['embedding'] != null) {
                sub['embedding'] = (sub['embedding'] as List)
                    .map((e) => (e as num).toDouble())
                    .toList();
              }
            }
          }
          _parsedTemplateCache![template['id']] = parsed;
        } catch (e) {
          debugPrint('⚠️ Error parsing template ${template['id']}: $e');
        }
      }
      _cacheTimestamp = DateTime.now();

      // Sync to ObjectBox asynchronously
      unawaited(Future(() => _syncObjectBox(results, organizationId)));

      // Persist to offline DB asynchronously
      unawaited(Future(() async {
        try {
          await _offlineDb.syncBiometricData(
            results,
            biometricType: 'face_recognition',
            organizationId: organizationId,
          );
          for (var template in results) {
            unawaited(
              _offlineDb.cacheMemberData({
                'organization_member_id': template['organization_member_id'],
                'card_number': 'FACE_${template['organization_member_id']}',
                'organization_members': template['organization_members'],
              }),
            );
          }
        } catch (e) {
          debugPrint('⚠️ Offline DB write failed: $e');
        }
      }));

      return results;
    } catch (e) {
      debugPrint('❌ Supabase fetch also failed: $e');
      return [];
    }
  }

  /// Fetch faces from Supabase
  Future<List<Map<String, dynamic>>> _fetchFacesFromSupabase(
    int organizationId,
  ) async {
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

    return List<Map<String, dynamic>>.from(results);
  }

  /// Background sync faces
  void _syncFacesFromSupabase(int organizationId) {
    if (_cacheTimestamp != null &&
        _cachedOrganizationId == organizationId &&
        DateTime.now().difference(_cacheTimestamp!) < _cacheExpiry) {
      return;
    }
    Future(() async {
      try {
        debugPrint('🔄 Background face sync for org $organizationId...');
        final templates = await _fetchFacesFromSupabase(organizationId);

        // Update local database (full replacement)
        await _offlineDb.syncBiometricData(
          templates,
          biometricType: 'face_recognition',
          organizationId: organizationId,
        );

        // Cache member profiles
        for (var template in templates) {
          unawaited(
            _offlineDb.cacheMemberData({
              'organization_member_id': template['organization_member_id'],
              'card_number': 'FACE_${template['organization_member_id']}',
              'organization_members': template['organization_members'],
            }),
          );
        }

        // Keep RAM Cache fresh & pre-parsed
        _memoryTemplateCache = templates;
        _cachedOrganizationId = organizationId;
        final newParsedCache = <int, Map<String, dynamic>>{};
        for (var template in templates) {
          try {
            final Map<String, dynamic> parsed = jsonDecode(
              template['template_data'],
            );
            // Pre-convert embedding to List<double> for speed
            if (parsed['embedding'] != null) {
              parsed['embedding'] = (parsed['embedding'] as List)
                  .map((e) => (e as num).toDouble())
                  .toList();
            }
            if (parsed['templates'] != null) {
              final subTemplates = parsed['templates'] as List;
              for (var sub in subTemplates) {
                if (sub is Map && sub['embedding'] != null) {
                  sub['embedding'] = (sub['embedding'] as List)
                      .map((e) => (e as num).toDouble())
                      .toList();
                }
              }
            }
            newParsedCache[template['id']] = parsed;
          } catch (e) {
            debugPrint('⚠️ Error parsing template ${template['id']}: $e');
          }
        }
        _parsedTemplateCache = newParsedCache;
        _cacheTimestamp = DateTime.now();

        // Sync to ObjectBox too
        _syncObjectBox(templates, organizationId);

        debugPrint(
          '✅ Background face sync done: ${templates.length} templates cached & RAM Cache refreshed',
        );
      } catch (e) {
        debugPrint('⚠️ Background face sync skipped (offline?): $e');
      }
    });
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
      final faceService = await getFaceService();

      // Ensure local cache list is loaded as backup / database info lookup
      if (_memoryTemplateCache == null || _cachedOrganizationId != organizationId) {
        _memoryTemplateCache = await getAllActiveFaceTemplatesWithUserInfo(organizationId);
        _cachedOrganizationId = organizationId;
        // ✅ DIAGNOSTIC: Dump ObjectBox registry on first load for debugging
        ObjectBoxService().dumpAllRegisteredFaces();
      }

      // Pre-convert captured embedding to List<double>
      List<double>? queryVector;
      if (capturedTemplate['embedding'] != null) {
        queryVector = (capturedTemplate['embedding'] as List)
            .map((e) => (e as num).toDouble())
            .toList();
      } else if (capturedTemplate['templates'] != null && (capturedTemplate['templates'] as List).isNotEmpty) {
        final capTemplates = capturedTemplate['templates'] as List;
        final firstTemp = capTemplates.first;
        if (firstTemp is Map && firstTemp['embedding'] != null) {
          queryVector = (firstTemp['embedding'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
        }
      }

      if (queryVector == null || queryVector.length != 512) {
        debugPrint('⚠️ ObjectBox: invalid query vector length');
        return null;
      }

      final capturedVersion = (capturedTemplate['version'] as num?)?.toInt() ?? 3;
      final capturedQuality = (capturedTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
      double effectiveThreshold = threshold;

      if (capturedQuality < 0.50) {
        if (capturedQuality < 0.35) {
          debugPrint(
            '❌ Strict match rejected: very low quality (${(capturedQuality * 100).toInt()}%)',
          );
          return null;
        }
      }

      // Perform HNSW Vector Search using ObjectBox Service (extremely fast!)
      final nearest = ObjectBoxService().searchNearestNeighbors(
        queryVector,
        maxResultCount: 2, // get top 2 to report second similarity
        organizationId: organizationId,
      );

      if (nearest.isEmpty) {
        debugPrint('❌ ObjectBox: No matches found.');
        return null;
      }

      final bestCandidate = nearest.first;
      final double distance = bestCandidate.score;
      final double similarity = 1.0 - distance; // Cosine similarity: [-1.0, 1.0]
      
      double secondHighestSimilarity = -1.0;
      String? secondCandidateName;
      int? secondCandidateMemberId;
      if (nearest.length > 1) {
        secondHighestSimilarity = 1.0 - nearest[1].score;
        secondCandidateName = nearest[1].object.namaLengkap;
        secondCandidateMemberId = nearest[1].object.organizationMemberId;
      }

      // ✅ COMPACT LOGGING: Single line to avoid FPS drops from excessive debug output
      final String secondInfo = secondCandidateName != null
          ? ' | #2: $secondCandidateName ${(secondHighestSimilarity * 100).toStringAsFixed(0)}%'
          : '';
      debugPrint('🔍 MATCH: ${bestCandidate.object.namaLengkap} '
          '${(similarity * 100).toStringAsFixed(1)}% '
          '(thr:${(effectiveThreshold * 100).toInt()}%)$secondInfo');

      if (similarity < effectiveThreshold) {
        return null;
      }

      // ✅ MARGIN-OF-VICTORY CHECK: Reject ambiguous matches (gap < 5%)
      if (secondHighestSimilarity > 0 && secondHighestSimilarity >= effectiveThreshold) {
        final double margin = similarity - secondHighestSimilarity;
        // ONLY reject if the top 2 candidates are DIFFERENT people
        if (margin < 0.05 && secondCandidateMemberId != bestCandidate.object.organizationMemberId) {
          debugPrint('⚠️ AMBIGUOUS: margin ${(margin * 100).toStringAsFixed(1)}% < 5% between DIFFERENT members');
          return null;
        }
      }

      // Map matching member's full profile details from local database cache
      final matchedMemberId = bestCandidate.object.organizationMemberId;
      final memberData = await _offlineDb.findMemberByOrgIdInCache(matchedMemberId);
      
      final orgMember = memberData != null ? memberData['organization_members'] : null;
      final userProfile = orgMember != null ? orgMember['user_profiles'] : null;
      final dept = orgMember != null
          ? (orgMember['departments'] is List
              ? (orgMember['departments'].isNotEmpty
                  ? orgMember['departments'].first
                  : null)
              : orgMember['departments'])
          : null;
      String? combinedDept = dept?['name'];

      // Find original biometric ID (for logs / sync tasks)
      int? biometricId;
      if (_memoryTemplateCache != null) {
        final t = _memoryTemplateCache!.firstWhere(
          (x) => x['organization_member_id'] == matchedMemberId,
          orElse: () => <String, dynamic>{},
        );
        if (t.isNotEmpty) biometricId = t['id'] as int?;
      }

      if (biometricId == null) {
        final db = await _offlineDb.database;
        final dbResult = await db.query(
          'biometric_data',
          columns: ['id'],
          where: 'organization_member_id = ? AND biometric_type = ? AND is_active = 1',
          whereArgs: [matchedMemberId, 'face_recognition'],
          limit: 1,
        );
        if (dbResult.isNotEmpty) {
          biometricId = dbResult.first['id'] as int?;
        }
      }

      final fallbackName = bestCandidate.object.namaLengkap;
      final fallbackProfilePhoto = bestCandidate.object.profilePhotoUrl;

      return {
        'organization_member_id': matchedMemberId,
        'biometric_id': biometricId ?? 0,
        'similarity': similarity,
        'organization_id': orgMember != null ? orgMember['organization_id'] : (bestCandidate.object.organizationId ?? organizationId),
        'user_id': orgMember != null ? orgMember['user_id'] : null,
        'employee_id': orgMember != null ? orgMember['employee_id'] : null,
        'user_name': (fallbackName != null && fallbackName.isNotEmpty)
            ? fallbackName
            : (userProfile != null
                ? ((userProfile['display_name'] ?? '').toString().isEmpty
                    ? '${userProfile['first_name'] ?? ''} ${userProfile['last_name'] ?? ''}'.trim()
                    : userProfile['display_name'])
                : 'Karyawan #$matchedMemberId'),
        'first_name': userProfile != null ? userProfile['first_name'] : null,
        'last_name': userProfile != null ? userProfile['last_name'] : null,
        'profile_photo_url': fallbackProfilePhoto ?? (userProfile != null ? userProfile['profile_photo_url'] : null),
        'department_name': combinedDept,
        'template_version': capturedVersion,
        'threshold': effectiveThreshold,
        'matched_angle': 'Single',
        'second_similarity': secondHighestSimilarity,
      };
    } catch (e, stack) {
      debugPrint('!!! ERROR in identifyBestMatchWithUserInfo: $e\n$stack');
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

      // debugPrint('✅ Updated last_used_at for biometric_id: $biometricId');
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

      // debugPrint('✅ Deactivated biometric template: $biometricId');
    } catch (e) {
      throw Exception('Failed to deactivate face template: $e');
    }
  }

  /// ✅ NEW: Adaptive Learning (Template Evolution)
  /// Merges new high-confidence embedding into the existing profile.
  Future<void> evolveTemplate({
    required int biometricId,
    required Map<String, dynamic> currentTemplate,
    required Map<String, dynamic> capturedTemplate,
    double learningRate = 0.1, // 10% new data, 90% old data
  }) async {
    try {
      final currentEmbedding = List<double>.from(
        currentTemplate['embedding'] ?? [],
      );
      final newEmbedding = List<double>.from(
        capturedTemplate['embedding'] ?? [],
      );

      if (currentEmbedding.isEmpty || newEmbedding.isEmpty) return;
      if (currentEmbedding.length != newEmbedding.length) return;

      // debugPrint('🧬 Evolving template $biometricId (LR: $learningRate)...');

      // 1. Weighted Average Evolution
      final nextEmbedding = List<double>.filled(currentEmbedding.length, 0.0);
      for (int i = 0; i < currentEmbedding.length; i++) {
        nextEmbedding[i] =
            (currentEmbedding[i] * (1.0 - learningRate)) +
            (newEmbedding[i] * learningRate);
      }

      // 2. Normalize unit vector (Very Important for Cosine Similarity)
      double sumSquares = 0.0;
      for (var value in nextEmbedding) {
        sumSquares += value * value;
      }
      final magnitude = math.sqrt(sumSquares);
      final normalizedEmbedding = magnitude < 1e-6
          ? nextEmbedding
          : nextEmbedding.map((v) => v / magnitude).toList();

      // 3. Prepare updated JSON data
      final updatedTemplate = Map<String, dynamic>.from(currentTemplate);
      updatedTemplate['embedding'] = normalizedEmbedding;
      updatedTemplate['evolution_count'] =
          (updatedTemplate['evolution_count'] ?? 0) + 1;
      updatedTemplate['last_evolved_at'] = DateTime.now().toIso8601String();

      final jsonString = jsonEncode(updatedTemplate);

      // 4. Update Database (Supabase) - Fire and forget for speed
      _supabase
          .from('biometric_data')
          .update({
            'template_data': jsonString,
            'last_used_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
          })
          .eq('id', biometricId)
          .then((_) {
            // debugPrint('✅ Supabase template evolved successfully');
          })
          .catchError((e) {
            debugPrint('⚠️ Supabase evolution update failed: $e');
          });

      // 5. Update Local Cache (Fire and forget)
      _offlineDb
          .updateBiometricTemplate(
            biometricId: biometricId,
            templateData: jsonString,
          )
          .then((_) {
            // debugPrint('✅ Local cache template evolved successfully');
            // Update in-memory cache too
            _parsedTemplateCache?[biometricId] = updatedTemplate;
          });
    } catch (e) {
      debugPrint('⚠️ Failed to evolve template: $e');
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
      // debugPrint('=== FETCHING ORGANIZATION STATS ===');

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

      /*
      debugPrint('Registered faces: $registeredCount');
      debugPrint('Version breakdown: $versionCounts');
      debugPrint('Total members: $totalMembers');
      */

      return {
        'registered_faces': registeredCount,
        'total_members': totalMembers,
        'pending_registration': totalMembers - registeredCount,
        'w600k_templates':
            (versionCounts[4] ?? 0) +
            (versionCounts[5] ?? 0) +
            (versionCounts[6] ?? 0) +
            (versionCounts[7] ?? 0) +
            (versionCounts[8] ?? 0),
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
      // debugPrint('=== CHECKING OLD TEMPLATES ===');

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
          // v4 through v8 are considered modern W600K templates
          bool isModern = version >= 4 && version <= 8;

          if (!isModern) {
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

      // debugPrint('Found $oldCount old templates (version != 5)');
      return oldCount;
    } catch (e) {
      debugPrint('Error in migration check: $e');
      return 0;
    }
  }

  void _syncObjectBox(List<Map<String, dynamic>> templates, int organizationId) {
    try {
      final List<KaryawanWajah> faces = [];
      for (var t in templates) {
        try {
          faces.add(KaryawanWajah.fromSupabase(t));
        } catch (e) {
          debugPrint('⚠️ Error converting template to KaryawanWajah: $e');
        }
      }
      ObjectBoxService().syncOrganizationFaces(organizationId, faces);
    } catch (e) {
      debugPrint('⚠️ ObjectBox sync error: $e');
    }
  }

  void dispose() {
    debugPrint('BiometricService disposed');
  }
}
