// lib/services/attendance_sync_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../models/offline_attendance.dart';
import '../../services/offline_database_service.dart';
import 'attendance_service.dart';
import '../../services/supabase_storage_service.dart';

class AttendanceSyncService {
  static final AttendanceSyncService _instance =
      AttendanceSyncService._internal();
  factory AttendanceSyncService() => _instance;
  AttendanceSyncService._internal();

  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
  final SupabaseClient _supabase = Supabase.instance.client;

  Timer? _autoSyncTimer;
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  bool _isSyncing = false;

  final _syncStatusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get syncStatusStream => _syncStatusController.stream;

  // Start auto sync every 30 seconds when online (keeps sending idle queue)
  void startAutoSync({Duration interval = const Duration(seconds: 30)}) {
    stopAutoSync();

    // Periodic worker
    _autoSyncTimer = Timer.periodic(interval, (_) async {
      await _triggerSync(reason: 'timer');
    });

    // Fire once on startup
    _triggerSync(reason: 'startup');

    // Listen to connectivity so the queue ships immediately after back online
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      result,
    ) {
      if (result != ConnectivityResult.none) {
        _triggerSync(reason: 'connectivity');
      }
    });
  }

  // Stop auto sync
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  // Check internet connectivity
  Future<bool> _checkConnectivity() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        return false;
      }

      // Additional check: try to reach Supabase
      final result = await InternetAddress.lookup(
        'supabase.co',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      debugPrint('Connectivity check failed: $e');
      return false;
    }
  }

  // Safe guard to prevent overlapping syncs and skip when queue empty
  Future<void> _triggerSync({String reason = 'timer'}) async {
    if (_isSyncing) return;

    final pending = await _offlineDb.getUnsyncedCount();
    if (pending == 0) {
      return;
    }

    final isOnline = await _checkConnectivity();
    if (!isOnline) {
      debugPrint('⏸️ Sync skipped ($reason) - offline');
      return;
    }

    debugPrint('🚚 Triggering sync ($reason), pending: $pending');
    await syncPendingAttendances();
  }

  // Sync all pending attendances
  Future<SyncResult> syncPendingAttendances({bool showProgress = false}) async {
    if (_isSyncing) {
      return SyncResult(
        success: false,
        message: 'Sync already in progress',
        syncedCount: 0,
        failedCount: 0,
      );
    }

    _isSyncing = true;
    _syncStatusController.add(
      SyncStatus(isLoading: true, message: 'Syncing pending attendances...'),
    );

    if (showProgress) {
      _syncStatusController.add(
        SyncStatus(isLoading: true, message: 'Checking connectivity...'),
      );
    }

    try {
      // Check connectivity
      final isOnline = await _checkConnectivity();
      if (!isOnline) {
        if (showProgress) {
          _syncStatusController.add(
            SyncStatus(
              isLoading: false,
              message: 'No internet connection',
              isError: true,
            ),
          );
        }
        return SyncResult(
          success: false,
          message: 'No internet connection',
          syncedCount: 0,
          failedCount: 0,
        );
      }

      // ✅ Auto-Cleanup: Prune old records (older than 7 days)
      await _offlineDb.pruneOldRecords(days: 7);

      // Clean up duplicate records first
      await cleanupDuplicateRecords();

      // Get unsynced records
      final unsyncedRecords = await _offlineDb.getUnsyncedAttendances();

      debugPrint('📊 Found ${unsyncedRecords.length} unsynced records');

      if (unsyncedRecords.isEmpty) {
        if (showProgress) {
          _syncStatusController.add(
            SyncStatus(isLoading: false, message: 'No pending data to sync'),
          );
        }
        return SyncResult(
          success: true,
          message: 'No pending data to sync',
          syncedCount: 0,
          failedCount: 0,
        );
      }

      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(
            isLoading: true,
            message: 'Syncing ${unsyncedRecords.length} records...',
            progress: 0,
            total: unsyncedRecords.length,
          ),
        );
      }

      int syncedCount = 0;
      int failedCount = 0;
      final List<String> errors = [];

      for (int i = 0; i < unsyncedRecords.length; i++) {
        final record = unsyncedRecords[i];

        debugPrint(
          '🔄 [${i + 1}/${unsyncedRecords.length}] Syncing record ID: ${record.id}, Method: ${record.method}',
        );

        try {
          await _syncSingleRecord(record);
          syncedCount++;

          await _offlineDb.updateSyncStatus(
            id: record.id!,
            isSynced: true,
            syncError: null,
          );

          await _offlineDb.deleteAttendance(record.id!);

          if (showProgress) {
            _syncStatusController.add(
              SyncStatus(
                isLoading: true,
                message: 'Syncing... ($syncedCount/${unsyncedRecords.length})',
                progress: i + 1,
                total: unsyncedRecords.length,
              ),
            );
          }
        } catch (e) {
          final errorMessage = e.toString();

          // ⚠️ Logika Penanganan Error:
          // 1. Duplicate: Data sudah ada di server (hapus dari HP)
          // 2. Fatal: Kesalahan logika seperti "No check-in found" (tandai sukses tapi simpan error, agar tidak di-retry)

          final isDuplicate =
              errorMessage.contains('Already checked') ||
              errorMessage.contains('already') ||
              errorMessage.toLowerCase().contains('duplicate');

          final isFatal =
              errorMessage.contains('No check-in record found') ||
              errorMessage.contains('No-Check-In');

          if (isDuplicate || isFatal) {
            debugPrint(
              '⚠️ ${isFatal ? "FATAL" : "DUPLICATE"} record ${record.id}: $errorMessage',
            );
            try {
              // Jika fatal/duplicate, kita tandai is_synced=1 agar SELESAI (tidak di-retry)
              await _offlineDb.updateSyncStatus(
                id: record.id!,
                isSynced: true,
                syncError:
                    '${isFatal ? "FATAL: " : "Duplicate: "}$errorMessage',
              );

              if (isDuplicate) {
                await _offlineDb.deleteAttendance(record.id!);
              }
            } catch (updateError) {
              debugPrint('❌ Update failed: $updateError');
            }
            syncedCount++;
          } else {
            // Error Jaringan/Server: Keep in DB for retry
            failedCount++;
            errors.add('Failed: ${record.userName ?? record.cardNumber} - $e');
            debugPrint('❌ Sync failed for record ${record.id}: $e');

            await _offlineDb.updateSyncStatus(
              id: record.id!,
              isSynced: false,
              syncError: errorMessage,
            );
          }
        }
      }

      // Cleanup batch sync
      if (syncedCount > 0) {
        await _offlineDb.deleteSuccessfullySyncedAttendances();
      }

      final summaryMessage = syncedCount > 0
          ? 'Synced: $syncedCount${failedCount > 0 ? ", Failed: $failedCount" : ""}'
          : 'All syncs failed';

      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(
            isLoading: false,
            message: summaryMessage,
            isError: failedCount > 0,
          ),
        );
      }

      return SyncResult(
        success: syncedCount > 0,
        message: summaryMessage,
        syncedCount: syncedCount,
        failedCount: failedCount,
        errors: errors.isEmpty ? null : errors,
      );
    } catch (e) {
      debugPrint('General sync error: $e');
      if (showProgress) {
        _syncStatusController.add(
          SyncStatus(isLoading: false, message: 'Error: $e', isError: true),
        );
      }
      return SyncResult(
        success: false,
        message: 'Error: $e',
        syncedCount: 0,
        failedCount: 0,
      );
    } finally {
      _isSyncing = false;
      _syncStatusController.add(
        SyncStatus(isLoading: false, message: 'Sync finished'),
      );
    }
  }

  // Sync single record
  Future<void> _syncSingleRecord(OfflineAttendance record) async {
    int memberId;

    // For RFID: Find member by card number
    if (record.method == 'rfid_card_mobile') {
      final cardData = await _supabase
          .from('rfid_cards')
          .select('''
          id, card_number, organization_member_id,
          organization_members!inner(
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          )
        ''')
          .eq('card_number', record.cardNumber)
          .eq('is_active', true)
          .maybeSingle();

      if (cardData == null) {
        debugPrint(
          '🗑️ Card ${record.cardNumber} not found in server, deleting offline record ${record.id}',
        );
        await _offlineDb.deleteAttendance(record.id!);
        throw Exception('RFID card not found: ${record.cardNumber}');
      }

      memberId = cardData['organization_member_id'] as int;

      // Update cache with latest member data
      await _offlineDb.cacheMemberData(cardData);

      // Update the record with latest member info
      final memberInfo =
          cardData['organization_members'] as Map<String, dynamic>?;
      if (memberInfo != null) {
        final profile = memberInfo['user_profiles'] as Map<String, dynamic>?;
        if (profile != null) {
          final displayName = profile['display_name'] as String?;
          final firstName = profile['first_name'] as String?;
          final lastName = profile['last_name'] as String?;
          final userName = (displayName?.isNotEmpty == true)
              ? displayName
              : '$firstName $lastName'.trim();

          if (userName?.isNotEmpty == true) {
            await _offlineDb.updateAttendanceUserName(record.id!, userName!);
          }
        }
      }
    }
    // For Face Recognition: Use stored member ID (or derive from FACE_{id}) and update member data
    else if (record.method == 'FACERECOGNITION' ||
        record.method == 'face_recognition') {
      if (record.organizationMemberId != null) {
        memberId = record.organizationMemberId!;
      } else {
        memberId = _extractMemberIdFromFaceCard(record.cardNumber);
      }

      debugPrint(
        '🔄 Syncing face recognition attendance for member ID: $memberId',
      );

      // Fetch latest member data and update cache
      try {
        final memberData = await _supabase
            .from('organization_members')
            .select('''
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments!organization_members_department_id_fkey (id, name)
          ''')
            .eq('id', memberId)
            .eq('is_active', true)
            .maybeSingle();

        if (memberData == null) {
          throw Exception(
            'Organization member not found or inactive: $memberId',
          );
        }

        debugPrint('✅ Found member data for ID: $memberId');

        // Create card-like structure for caching (skip if card_number is null to avoid cache errors)
        try {
          final cardData = {
            'id': 'face_recognition_$memberId',
            'card_number': record.cardNumber, // Use the FACE_$memberId format
            'organization_member_id': memberId,
            'organization_members': memberData,
          };

          await _offlineDb.cacheMemberData(cardData);
          debugPrint('✅ Cached member data for face recognition');
        } catch (cacheError) {
          debugPrint(
            '⚠️ Failed to cache member data (non-critical): $cacheError',
          );
          // Continue even if cache fails
        }

        // Update the record with latest member info
        final profile = memberData['user_profiles'] as Map<String, dynamic>?;
        if (profile != null) {
          final displayName = profile['display_name'] as String?;
          final firstName = profile['first_name'] as String?;
          final lastName = profile['last_name'] as String?;
          final userName = (displayName?.isNotEmpty == true)
              ? displayName
              : '$firstName $lastName'.trim();

          if (userName != null && userName.isNotEmpty) {
            await _offlineDb.updateAttendanceUserName(record.id!, userName);
            debugPrint('✅ Updated attendance user name: $userName');
          }
        } else {
          debugPrint('⚠️ No user profile found for member ID: $memberId');
        }
      } catch (e) {
        debugPrint('❌ Error fetching member data for face recognition: $e');
        rethrow;
      }
    } else {
      throw Exception(
        'Cannot determine organization member ID. Method: ${record.method}, CardNumber: ${record.cardNumber}',
      );
    }

    // Upload photo if exists (use saved file or base64 fallback)
    String photoUrl = '';
    File? tempPhotoFile;
    try {
      File? photoFile;
      if (record.photoPath != null && record.photoPath!.isNotEmpty) {
        final file = File(record.photoPath!);
        if (await file.exists()) {
          photoFile = file;
        }
      }

      // Fallback to captured base64 if no file available
      if (photoFile == null && record.capturedPhotoBase64?.isNotEmpty == true) {
        final bytes = base64Decode(record.capturedPhotoBase64!);
        final tempPath =
            '${Directory.systemTemp.path}/offline_face_${record.id ?? DateTime.now().millisecondsSinceEpoch}.jpg';
        tempPhotoFile = File(tempPath);
        await tempPhotoFile.writeAsBytes(bytes, flush: true);
        photoFile = tempPhotoFile;
        debugPrint(
          '🗂️ Recreated photo from base64 for member $memberId at $tempPath',
        );
      }

      if (photoFile != null) {
        try {
          debugPrint('📸 Uploading photo for member $memberId...');
          photoUrl = await _storageService.uploadAttendancePhoto(
            photoFile,
            memberId,
            record.eventType,
          );
          debugPrint('✅ Photo uploaded successfully: $photoUrl');
        } catch (e) {
          debugPrint(
            '⚠️ Failed to upload photo (continuing without photo): $e',
          );
        }
      } else {
        debugPrint('ℹ️ No photo available for member $memberId');
      }
    } finally {
      // Clean up temporary file created from base64
      if (tempPhotoFile != null) {
        try {
          await tempPhotoFile.delete();
        } catch (_) {}
      }
    }

    // Prepare location data
    Map<String, dynamic>? locationData;
    if (record.latitude != null && record.longitude != null) {
      locationData = {
        'latitude': record.latitude,
        'longitude': record.longitude,
      };
    }

    // Prepare raw data with parsing logic for multi-shift
    Map<String, dynamic> rawData = {
      'synced_from_offline': true,
      'offline_timestamp': record.timestamp,
      'work_time_mode': record.workTimeMode, // Default fallback
    };

    // Try to parse encoded shift details
    if (record.workTimeMode != null &&
        record.workTimeMode!.trim().startsWith('{')) {
      try {
        final parsed = jsonDecode(record.workTimeMode!) as Map<String, dynamic>;
        rawData['shift_details'] = parsed;
        if (parsed.containsKey('mode_code')) {
          rawData['work_time_mode'] = parsed['mode_code'];
        }
      } catch (e) {
        debugPrint('⚠️ Failed to parse workTimeMode JSON: $e');
      }
    }

    if (record.method == 'rfid_card_mobile') {
      rawData['card_number'] = record.cardNumber;
    }
    if (record.method == 'FACERECOGNITION' ||
        record.method == 'face_recognition') {
      rawData['face_recognition'] = true;
    }

    // Sync to Supabase
    debugPrint(
      '🔄 Syncing ${record.eventType} to Supabase for member $memberId...',
    );
    try {
      if (record.eventType == 'check_in') {
        await _attendanceService.checkIn(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint('✅ Successfully synced check_in for member $memberId');
      } else if (record.eventType == 'check_out') {
        await _attendanceService.checkOut(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint('✅ Successfully synced check_out for member $memberId');
      } else if (record.eventType == 'break_out' ||
          record.eventType == 'break_start') {
        await _attendanceService.breakOut(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint(
          '✅ Successfully synced ${record.eventType} (break_start) for member $memberId',
        );
      } else if (record.eventType == 'break_in' ||
          record.eventType == 'break_end') {
        await _attendanceService.breakIn(
          organizationMemberId: memberId,
          photoUrl: photoUrl,
          method: record.method,
          location: locationData,
          rawData: rawData,
        );
        debugPrint(
          '✅ Successfully synced ${record.eventType} (break_end) for member $memberId',
        );
      }
    } catch (e) {
      debugPrint('❌ Error syncing attendance to Supabase: $e');
      rethrow;
    }
  }

  // Add method for manual sync all
  Future<SyncResult> syncAllPendingAttendances() async {
    return await syncPendingAttendances(showProgress: true);
  }

  // Clean up duplicate records that are already marked as synced
  Future<int> cleanupDuplicateRecords() async {
    try {
      debugPrint('🧹 Cleaning up duplicate records...');
      final deletedCount = await _offlineDb.deleteDuplicateRecords();
      debugPrint('✅ Cleaned up $deletedCount duplicate records');
      return deletedCount;
    } catch (e) {
      debugPrint('❌ Error cleaning up duplicate records: $e');
      return 0;
    }
  }

  // Get sync statistics
  Future<Map<String, int>> getSyncStats() async {
    final unsyncedCount = await _offlineDb.getUnsyncedCount();
    final allRecords = await _offlineDb.getAllAttendances();
    final syncedCount = allRecords.where((r) => r.isSynced).length;
    final failedCount = allRecords
        .where((r) => !r.isSynced && r.syncError != null)
        .length;

    return {
      'total': allRecords.length,
      'synced': syncedCount,
      'pending': unsyncedCount,
      'failed': failedCount,
    };
  }

  void dispose() {
    stopAutoSync();
    _syncStatusController.close();
  }

  int _extractMemberIdFromFaceCard(String cardNumber) {
    try {
      if (cardNumber.startsWith('FACE_')) {
        final idPart = cardNumber.replaceFirst('FACE_', '');
        return int.parse(idPart);
      }
    } catch (_) {
      // fallthrough
    }
    throw Exception('Invalid face card number: $cardNumber');
  }
}

// Sync status model
class SyncStatus {
  final bool isLoading;
  final String message;
  final bool isError;
  final int? progress;
  final int? total;

  SyncStatus({
    required this.isLoading,
    required this.message,
    this.isError = false,
    this.progress,
    this.total,
  });
}

// Sync result model
class SyncResult {
  final bool success;
  final String message;
  final int syncedCount;
  final int failedCount;
  final List<String>? errors;

  SyncResult({
    required this.success,
    required this.message,
    required this.syncedCount,
    required this.failedCount,
    this.errors,
  });
}
