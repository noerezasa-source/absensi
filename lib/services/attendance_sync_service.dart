// lib/services/attendance_sync_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/offline_attendance.dart';
import './offline_database_service.dart';
import './attendance_service.dart';
import './supabase_storage_service.dart';

class AttendanceSyncService {
  static final AttendanceSyncService _instance = AttendanceSyncService._internal();
  factory AttendanceSyncService() => _instance;
  AttendanceSyncService._internal();

  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseStorageService _storageService = SupabaseStorageService();
  final SupabaseClient _supabase = Supabase.instance.client;
  
  Timer? _autoSyncTimer;
  bool _isSyncing = false;
  
  final _syncStatusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get syncStatusStream => _syncStatusController.stream;

  // Start auto sync every 15 seconds when online
  void startAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!_isSyncing) {
        final isOnline = await _checkConnectivity();
        if (isOnline) {
          await syncPendingAttendances();
        }
      }
    });
  }

  // Stop auto sync
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
  }

  // Check internet connectivity
  Future<bool> _checkConnectivity() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        return false;
      }
      
      // Additional check: try to reach Supabase
      final result = await InternetAddress.lookup('supabase.co').timeout(
        const Duration(seconds: 3),
      );
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      debugPrint('Connectivity check failed: $e');
      return false;
    }
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
    
    if (showProgress) {
      _syncStatusController.add(SyncStatus(
        isLoading: true,
        message: 'Checking connectivity...',
      ));
    }

    try {
      // Check connectivity
      final isOnline = await _checkConnectivity();
      if (!isOnline) {
        if (showProgress) {
          _syncStatusController.add(SyncStatus(
            isLoading: false,
            message: 'No internet connection',
            isError: true,
          ));
        }
        return SyncResult(
          success: false,
          message: 'No internet connection',
          syncedCount: 0,
          failedCount: 0,
        );
      }

      // Get unsynced records
      final unsyncedRecords = await _offlineDb.getUnsyncedAttendances();
      
      if (unsyncedRecords.isEmpty) {
        if (showProgress) {
          _syncStatusController.add(SyncStatus(
            isLoading: false,
            message: 'No pending data to sync',
          ));
        }
        return SyncResult(
          success: true,
          message: 'No pending data to sync',
          syncedCount: 0,
          failedCount: 0,
        );
      }

      if (showProgress) {
        _syncStatusController.add(SyncStatus(
          isLoading: true,
          message: 'Syncing ${unsyncedRecords.length} records...',
          progress: 0,
          total: unsyncedRecords.length,
        ));
      }

      int syncedCount = 0;
      int failedCount = 0;
      final List<String> errors = [];

      for (int i = 0; i < unsyncedRecords.length; i++) {
        final record = unsyncedRecords[i];
        
        try {
          await _syncSingleRecord(record);
          syncedCount++;
          
          // Mark as synced
          await _offlineDb.updateSyncStatus(
            id: record.id!,
            isSynced: true,
          );
          
          if (showProgress) {
            _syncStatusController.add(SyncStatus(
              isLoading: true,
              message: 'Syncing... ($syncedCount/${unsyncedRecords.length})',
              progress: i + 1,
              total: unsyncedRecords.length,
            ));
          }
        } catch (e) {
          final errorMessage = e.toString();
          final isDuplicate = errorMessage.contains('Already checked') || 
                             errorMessage.contains('already') ||
                             errorMessage.toLowerCase().contains('duplicate');
          
          if (isDuplicate) {
            // If duplicate, mark as synced and delete (data already exists in online DB)
            debugPrint('⚠️ Duplicate attendance detected during sync for record ${record.id}: $errorMessage');
            await _offlineDb.updateSyncStatus(
              id: record.id!,
              isSynced: true, // Mark as synced since data already exists
              syncError: 'Duplicate: Data already exists in server',
            );
            syncedCount++; // Count as synced since data is already on server
          } else {
            failedCount++;
            final error = 'Failed: ${record.userName ?? record.cardNumber} - $e';
            errors.add(error);
            debugPrint('Sync failed for record ${record.id}: $e');
            
            // Update with error
            await _offlineDb.updateSyncStatus(
              id: record.id!,
              isSynced: false,
              syncError: e.toString(),
            );
          }
        }
      }

      // Delete successfully synced records
      if (syncedCount > 0) {
        await _offlineDb.deleteSyncedAttendances();
      }

      final message = syncedCount > 0
          ? 'Synced: $syncedCount${failedCount > 0 ? ", Failed: $failedCount" : ""}'
          : 'All syncs failed';

      if (showProgress) {
        _syncStatusController.add(SyncStatus(
          isLoading: false,
          message: message,
          isError: failedCount > 0,
        ));
      }

      return SyncResult(
        success: syncedCount > 0,
        message: message,
        syncedCount: syncedCount,
        failedCount: failedCount,
        errors: errors.isEmpty ? null : errors,
      );
    } catch (e) {
      debugPrint('Sync error: $e');
      if (showProgress) {
        _syncStatusController.add(SyncStatus(
          isLoading: false,
          message: 'Sync error: $e',
          isError: true,
        ));
      }
      return SyncResult(
        success: false,
        message: 'Sync error: $e',
        syncedCount: 0,
        failedCount: 0,
      );
    } finally {
      _isSyncing = false;
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
            user_profiles (display_name, first_name, last_name, profile_photo_url)
          )
        ''')
          .eq('card_number', record.cardNumber)
          .eq('is_active', true)
          .maybeSingle();
      
      if (cardData == null) {
        throw Exception('RFID card not found: ${record.cardNumber}');
      }
      
      memberId = cardData['organization_member_id'] as int;
      
      // Update cache with latest member data
      await _offlineDb.cacheMemberData(cardData);
      
      // Update the record with latest member info
      final memberInfo = cardData['organization_members'] as Map<String, dynamic>?;
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
    // For Face Recognition: Use stored member ID and update member data
    else if (record.organizationMemberId != null) {
      memberId = record.organizationMemberId!;
      
      // Fetch latest member data and update cache
      final memberData = await _supabase
          .from('organization_members')
          .select('''
          id, organization_id, user_id, department_id,
          user_profiles (display_name, first_name, last_name, profile_photo_url),
          departments!inner (id, name)
        ''')
          .eq('id', memberId)
          .eq('is_active', true)
          .maybeSingle();
      
      if (memberData != null) {
        // Create card-like structure for caching
        final cardData = {
          'id': 'face_recognition',
          'card_number': null,
          'organization_member_id': memberId,
          'organization_members': memberData,
        };
        
        await _offlineDb.cacheMemberData(cardData);
        
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
          }
        }
      }
    } else {
      throw Exception('Cannot determine organization member ID');
    }

    // Upload photo if exists
    String photoUrl = '';
    if (record.photoPath != null && record.photoPath!.isNotEmpty) {
      try {
        final photoFile = File(record.photoPath!);
        if (await photoFile.exists()) {
          photoUrl = await _storageService.uploadAttendancePhoto(
            photoFile,
            memberId,
            record.eventType,
          );
        }
      } catch (e) {
        debugPrint('Failed to upload photo: $e');
        // Continue without photo
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

    // Sync to Supabase
    if (record.eventType == 'check_in') {
      await _attendanceService.checkIn(
        organizationMemberId: memberId,
        photoUrl: photoUrl,
        method: record.method,
        location: locationData,
        rawData: {
          'synced_from_offline': true,
          'offline_timestamp': record.timestamp,
          'work_time_mode': record.workTimeMode,
          if (record.method == 'rfid_card_mobile')
            'card_number': record.cardNumber,
        },
      );
    } else {
      await _attendanceService.checkOut(
        organizationMemberId: memberId,
        photoUrl: photoUrl,
        method: record.method,
        location: locationData,
        rawData: {
          'synced_from_offline': true,
          'offline_timestamp': record.timestamp,
          'work_time_mode': record.workTimeMode,
          if (record.method == 'rfid_card_mobile')
            'card_number': record.cardNumber,
        },
      );
    }
  }

  // Add method for manual sync all
  Future<SyncResult> syncAllPendingAttendances() async {
    return await syncPendingAttendances(showProgress: true);
  }

  // Get sync statistics
  Future<Map<String, int>> getSyncStats() async {
    final unsyncedCount = await _offlineDb.getUnsyncedCount();
    final allRecords = await _offlineDb.getAllAttendances();
    final syncedCount = allRecords.where((r) => r.isSynced).length;
    final failedCount = allRecords.where((r) => !r.isSynced && r.syncError != null).length;
    
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