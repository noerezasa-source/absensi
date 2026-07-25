// BiometricService handles both face recognition and fingerprint templates in Supabase.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
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

  static const double defaultThreshold = 0.3;
  static FaceRecognitionTFLiteService? _persistentFaceService;

  Future<FaceRecognitionTFLiteService> getFaceService() async {
    if (_persistentFaceService == null) {
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

  Map<String, dynamic>? getParsedTemplateFromCache(int biometricId) {
    return _parsedTemplateCache?[biometricId];
  }

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

      if (matchedMemberId != intendedMemberId && similarity >= 0.50) {
        debugPrint('⚠️ DUPLICATE GUARD: Face matches existing member $matchedName (ID: $matchedMemberId) at ${(similarity * 100).toStringAsFixed(1)}% — intended for member ID $intendedMemberId');
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

      final biometricData = <String, dynamic>{
        'organization_member_id': organizationMemberId,
        'biometric_type': 'face_recognition',
        'template_data': templateJson,
        'enrollment_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
        'is_active': true,
      };

      final result = await _supabase
          .from('biometric_data')
          .insert(biometricData)
          .select()
          .single();

      int orgId = 0;
      try {
        final memberRow = await _supabase
            .from('organization_members')
            .select('organization_id')
            .eq('id', organizationMemberId)
            .maybeSingle();
        orgId = (memberRow?['organization_id'] as num?)?.toInt() ?? 0;
      } catch (_) {}

      try {
        final cachedMember = await _offlineDb.findMemberByOrgIdInCache(organizationMemberId);
        final Map<String, dynamic> fullMap = Map.from(result);
        if (cachedMember != null) {
          fullMap['organization_members'] = cachedMember['organization_members'];
        }
        fullMap['organization_id'] = orgId;

        ObjectBoxService().deleteByMemberId(organizationMemberId);

        final templateData = fullMap['template_data'];
        Map<String, dynamic>? parsed;
        if (templateData is String) {
          try {
            parsed = jsonDecode(templateData);
          } catch (_) {}
        } else if (templateData is Map<String, dynamic>) {
          parsed = templateData;
        }

        if (parsed != null && parsed['templates'] != null && (parsed['templates'] as List).isNotEmpty) {
          final subTemplates = parsed['templates'] as List;
          int addedCount = 0;
          for (var sub in subTemplates) {
            if (sub is Map && sub['embedding'] != null) {
              final doubleList = (sub['embedding'] as List)
                  .map((e) => (e as num).toDouble())
                  .toList();
              final embedding = Float32List.fromList(doubleList);

              final base = KaryawanWajah.fromSupabase(fullMap);
              base.faceEmbedding = embedding;
              if (orgId > 0) base.organizationId = orgId;
              ObjectBoxService().box.put(base);
              addedCount++;
            }
          }
          debugPrint('✅ ObjectBox: Registered $addedCount multi-angle face templates for member ID $organizationMemberId (Org: $orgId)');
        } else {
          final kw = KaryawanWajah.fromSupabase(fullMap);
          if (orgId > 0) kw.organizationId = orgId;
          ObjectBoxService().putKaryawanWajah(kw);
          debugPrint('✅ ObjectBox: Registered 1 face template for member ID $organizationMemberId (Org: $orgId)');
        }
      } catch (e) {
        debugPrint('⚠️ ObjectBox failed to save registered face: $e');
      }

      _memoryTemplateCache = null;
      _parsedTemplateCache = null;

      if (orgId > 0) {
        unawaited(refreshCache(orgId));
      }

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

  Future<BiometricData> registerFingerprintTemplate({
    required int organizationMemberId,
    required String templateBase64,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

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
    List<Map<String, dynamic>> cachedTemplates = [];
    try {
      cachedTemplates = await _offlineDb.getAllBiometricDataWithUserInfo(
        organizationId: organizationId,
        biometricType: 'fingerprint',
      );
    } catch (e) {
      debugPrint('⚠️ Failed to read SQLite cache: $e');
    }

    _syncFingerprintsFromSupabase(organizationId);

    if (cachedTemplates.isNotEmpty) {
      return cachedTemplates;
    }

    try {
      final results = await _fetchFingerprintsFromSupabase(organizationId);
      return results;
    } catch (e) {
      debugPrint('❌ Supabase fetch also failed: $e');
      return [];
    }
  }

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

  void _syncFingerprintsFromSupabase(int organizationId) {
    Future(() async {
      try {
        final templates = await _fetchFingerprintsFromSupabase(organizationId);
        await _offlineDb.syncBiometricData(
          templates,
          biometricType: 'fingerprint',
          organizationId: organizationId,
        );

        for (var template in templates) {
          unawaited(
            _offlineDb.cacheMemberData({
              'organization_member_id': template['organization_member_id'],
              'card_number': 'FINGER_${template['organization_member_id']}',
              'organization_members': template['organization_members'],
            }),
          );
        }
      } catch (_) {}
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

  Future<List<Map<String, dynamic>>> getAllActiveFaceTemplatesWithUserInfo(
    int organizationId,
  ) async {
    List<Map<String, dynamic>> cachedTemplates = [];
    try {
      cachedTemplates = await _offlineDb.getAllBiometricDataWithUserInfo(
        organizationId: organizationId,
        biometricType: 'face_recognition',
      );
    } catch (e) {
      debugPrint('⚠️ Failed to read SQLite cache: $e');
    }

    _syncFacesFromSupabase(organizationId);

    if (cachedTemplates.isNotEmpty) {
      _memoryTemplateCache = cachedTemplates;
      _cachedOrganizationId = organizationId;

      _parsedTemplateCache = {};
      for (var template in cachedTemplates) {
        try {
          final Map<String, dynamic> parsed = jsonDecode(
            template['template_data'],
          );
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
        } catch (_) {}
      }
      _cacheTimestamp = DateTime.now();

      unawaited(Future(() => _syncObjectBox(cachedTemplates, organizationId)));

      return cachedTemplates;
    }

    try {
      final results = await _fetchFacesFromSupabase(organizationId);

      _memoryTemplateCache = results;
      _cachedOrganizationId = organizationId;
      _parsedTemplateCache = {};
      for (var template in results) {
        try {
          final Map<String, dynamic> parsed = jsonDecode(
            template['template_data'],
          );
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
        } catch (_) {}
      }
      _cacheTimestamp = DateTime.now();

      unawaited(Future(() => _syncObjectBox(results, organizationId)));

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
        } catch (_) {}
      }));

      return results;
    } catch (e) {
      debugPrint('❌ Supabase fetch also failed: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFacesFromSupabase(
    int organizationId,
  ) async {
    try {
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
              user_profiles (
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
    } catch (e) {
      debugPrint('⚠️ Error fetching faces from Supabase with full joins: $e');
      try {
        final fallback = await _supabase
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
                department_id
              )
            ''')
            .eq('biometric_type', 'face_recognition')
            .eq('is_active', true)
            .eq('organization_members.organization_id', organizationId);

        return List<Map<String, dynamic>>.from(fallback);
      } catch (err) {
        debugPrint('❌ Fallback face fetch also failed: $err');
        return [];
      }
    }
  }

  void _syncFacesFromSupabase(int organizationId) {
    if (_cacheTimestamp != null &&
        _cachedOrganizationId == organizationId &&
        DateTime.now().difference(_cacheTimestamp!) < _cacheExpiry) {
      return;
    }
    Future(() async {
      try {
        final templates = await _fetchFacesFromSupabase(organizationId);
        await _offlineDb.syncBiometricData(
          templates,
          biometricType: 'face_recognition',
          organizationId: organizationId,
        );

        for (var template in templates) {
          unawaited(
            _offlineDb.cacheMemberData({
              'organization_member_id': template['organization_member_id'],
              'card_number': 'FACE_${template['organization_member_id']}',
              'organization_members': template['organization_members'],
            }),
          );
        }

        _memoryTemplateCache = templates;
        _cachedOrganizationId = organizationId;
        final newParsedCache = <int, Map<String, dynamic>>{};
        for (var template in templates) {
          try {
            final Map<String, dynamic> parsed = jsonDecode(
              template['template_data'],
            );
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
          } catch (_) {}
        }
        _parsedTemplateCache = newParsedCache;
        _cacheTimestamp = DateTime.now();

        await _syncObjectBox(templates, organizationId);
      } catch (_) {}
    });
  }

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
      if (_memoryTemplateCache == null || _cachedOrganizationId != organizationId) {
        _memoryTemplateCache = await getAllActiveFaceTemplatesWithUserInfo(organizationId);
        _cachedOrganizationId = organizationId;
        ObjectBoxService().dumpAllRegisteredFaces();
      }

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
        return null;
      }

      final capturedVersion = (capturedTemplate['version'] as num?)?.toInt() ?? 3;
      final capturedQuality = (capturedTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
      double effectiveThreshold = threshold;

      if (strict && capturedQuality < 0.35) {
        return null;
      }

      final nearest = ObjectBoxService().searchNearestNeighbors(
        queryVector,
        maxResultCount: 2,
        organizationId: organizationId,
      );

      if (nearest.isEmpty) {
        debugPrint('❌ ObjectBox: No matches found.');
        return null;
      }

      final bestCandidate = nearest.first;
      final double distance = bestCandidate.score;
      final double similarity = 1.0 - distance;

      double secondHighestSimilarity = -1.0;
      String? secondCandidateName;
      int? secondCandidateMemberId;
      if (nearest.length > 1) {
        secondHighestSimilarity = 1.0 - nearest[1].score;
        secondCandidateName = nearest[1].object.namaLengkap;
        secondCandidateMemberId = nearest[1].object.organizationMemberId;
      }

      final String secondInfo = secondCandidateName != null
          ? ' | #2: $secondCandidateName ${(secondHighestSimilarity * 100).toStringAsFixed(0)}%'
          : '';
      debugPrint('🔍 MATCH: ${bestCandidate.object.namaLengkap} ${(similarity * 100).toStringAsFixed(1)}% (thr:${(effectiveThreshold * 100).toInt()}%)$secondInfo');

      if (similarity < effectiveThreshold) {
        return null;
      }

      if (secondHighestSimilarity > 0 && secondHighestSimilarity >= effectiveThreshold) {
        final double margin = similarity - secondHighestSimilarity;
        final name1 = bestCandidate.object.namaLengkap.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final name2 = (secondCandidateName ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        
        final isSamePerson = name1 == name2 || 
            (name1.length >= 3 && name2.length >= 3 && (name1.contains(name2) || name2.contains(name1)));

        if (margin < 0.08 && 
            secondCandidateMemberId != bestCandidate.object.organizationMemberId &&
            !isSamePerson) {
          debugPrint('⚠️ AMBIGUOUS: margin ${(margin * 100).toStringAsFixed(1)}% < 8% between DIFFERENT people (${bestCandidate.object.namaLengkap} vs $secondCandidateName)');
          return null;
        }
      }

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
        'organization_id': orgMember != null ? orgMember['organization_id'] : (bestCandidate.object.organizationId == 0 ? organizationId : bestCandidate.object.organizationId),
        'user_id': orgMember != null ? orgMember['user_id'] : null,
        'employee_id': orgMember != null ? orgMember['employee_id'] : null,
        'user_name': fallbackName.isNotEmpty
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
    } catch (_) {}
  }

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

  Future<void> evolveTemplate({
    required int biometricId,
    required Map<String, dynamic> currentTemplate,
    required Map<String, dynamic> capturedTemplate,
    double learningRate = 0.1,
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

      final nextEmbedding = List<double>.filled(currentEmbedding.length, 0.0);
      for (int i = 0; i < currentEmbedding.length; i++) {
        nextEmbedding[i] =
            (currentEmbedding[i] * (1.0 - learningRate)) +
            (newEmbedding[i] * learningRate);
      }

      double sumSquares = 0.0;
      for (var value in nextEmbedding) {
        sumSquares += value * value;
      }
      final magnitude = math.sqrt(sumSquares);
      final normalizedEmbedding = magnitude < 1e-6
          ? nextEmbedding
          : nextEmbedding.map((v) => v / magnitude).toList();

      final updatedTemplate = Map<String, dynamic>.from(currentTemplate);
      updatedTemplate['embedding'] = normalizedEmbedding;
      updatedTemplate['evolution_count'] =
          (updatedTemplate['evolution_count'] ?? 0) + 1;
      updatedTemplate['last_evolved_at'] = DateTime.now().toIso8601String();

      final jsonString = jsonEncode(updatedTemplate);

      _supabase
          .from('biometric_data')
          .update({
            'template_data': jsonString,
            'last_used_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
          })
          .eq('id', biometricId)
          .catchError((_) {});

      _offlineDb
          .updateBiometricTemplate(
            biometricId: biometricId,
            templateData: jsonString,
          )
          .then((_) {
            _parsedTemplateCache?[biometricId] = updatedTemplate;

            Future(() async {
              try {
                final db = await _offlineDb.database;
                final dbResult = await db.query(
                  'biometric_data',
                  columns: ['organization_member_id', 'organization_id'],
                  where: 'id = ?',
                  whereArgs: [biometricId],
                  limit: 1,
                );
                if (dbResult.isNotEmpty) {
                  final memberId = dbResult.first['organization_member_id'] as int;
                  final orgId = dbResult.first['organization_id'] as int?;

                  final cachedMember = await _offlineDb.findMemberByOrgIdInCache(memberId);

                  final Map<String, dynamic> fullMap = {
                    'id': biometricId,
                    'organization_member_id': memberId,
                    'organization_id': orgId,
                    'template_data': jsonString,
                    'is_active': true,
                  };
                  if (cachedMember != null) {
                    fullMap['organization_members'] = cachedMember['organization_members'];
                  }

                  ObjectBoxService().deleteByMemberId(memberId);

                  if (updatedTemplate['templates'] != null && (updatedTemplate['templates'] as List).isNotEmpty) {
                    final subTemplates = updatedTemplate['templates'] as List;
                    for (var sub in subTemplates) {
                      if (sub is Map && sub['embedding'] != null) {
                        final doubleList = (sub['embedding'] as List)
                            .map((e) => (e as num).toDouble())
                            .toList();
                        final embedding = Float32List.fromList(doubleList);

                        final base = KaryawanWajah.fromSupabase(fullMap);
                        base.faceEmbedding = embedding;
                        ObjectBoxService().box.put(base);
                      }
                    }
                  } else {
                    final kw = KaryawanWajah.fromSupabase(fullMap);
                    ObjectBoxService().putKaryawanWajah(kw);
                  }
                }
              } catch (_) {}
            });
          });
    } catch (_) {}
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
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, int>> getOrganizationStats(int organizationId) async {
    try {
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

      final versionCounts = <int, int>{};
      for (final record in registeredData) {
        try {
          final templateData = jsonDecode(record['template_data']);
          final version = (templateData['version'] as num?)?.toInt() ?? 2;
          versionCounts[version] = (versionCounts[version] ?? 0) + 1;
        } catch (_) {}
      }

      final totalMembersData = await _supabase
          .from('organization_members')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('is_active', true);

      final totalMembers = totalMembersData.length;

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
    } catch (_) {
      return {
        'registered_faces': 0,
        'total_members': 0,
        'pending_registration': 0,
      };
    }
  }

  Future<int> migrateToTFLite(int organizationId) async {
    try {
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
          bool isModern = version >= 4 && version <= 8;

          if (!isModern) {
            oldCount++;
          }
        } catch (_) {}
      }

      return oldCount;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _syncObjectBox(List<Map<String, dynamic>> templates, int organizationId) async {
    try {
      if (!ObjectBoxService().isInitialized) {
        await ObjectBoxService().init();
      }
      final List<KaryawanWajah> faces = [];
      for (var t in templates) {
        try {
          final templateData = t['template_data'];
          Map<String, dynamic>? parsed;
          if (templateData is String) {
            try {
              parsed = jsonDecode(templateData);
            } catch (_) {}
          } else if (templateData is Map<String, dynamic>) {
            parsed = templateData;
          }

          if (parsed != null && parsed['templates'] != null && (parsed['templates'] as List).isNotEmpty) {
            final subTemplates = parsed['templates'] as List;
            int angleIdx = 0;
            for (var sub in subTemplates) {
              if (sub is Map && sub['embedding'] != null) {
                final doubleList = (sub['embedding'] as List)
                    .map((e) => (e as num).toDouble())
                    .toList();
                final embedding = Float32List.fromList(doubleList);

                final base = KaryawanWajah.fromSupabase(t);
                base.faceEmbedding = embedding;
                base.organizationId = organizationId;
                faces.add(base);
                angleIdx++;
              }
            }
            debugPrint('🧬 OBX Sync: Synced $angleIdx templates for Member ID: ${t['organization_member_id']} (Org: $organizationId)');
          } else {
            final kw = KaryawanWajah.fromSupabase(t);
            kw.organizationId = organizationId;
            faces.add(kw);
          }
        } catch (e) {
          debugPrint('⚠️ Error converting template to KaryawanWajah: $e');
        }
      }
      await ObjectBoxService().syncOrganizationFaces(organizationId, faces);
      ObjectBoxService().dumpAllRegisteredFaces();
    } catch (e) {
      debugPrint('⚠️ ObjectBox sync error: $e');
    }
  }

  void dispose() {
    debugPrint('BiometricService disposed');
  }
}
