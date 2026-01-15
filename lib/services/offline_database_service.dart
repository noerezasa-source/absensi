// lib/services/offline_database_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/offline_attendance.dart';
import '../helpers/timezone_helper.dart';

class OfflineDatabaseService {
  static final OfflineDatabaseService _instance = OfflineDatabaseService._internal();
  factory OfflineDatabaseService() => _instance;
  OfflineDatabaseService._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'offline_attendance.db');

    return await openDatabase(
      path,
      version: 4, // Increment version for migration
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Create attendance table
    await db.execute('''
      CREATE TABLE offline_attendances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_number TEXT NOT NULL,
        face_embedding TEXT,
        event_type TEXT NOT NULL,
        method TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        photo_path TEXT,
        captured_photo_base64 TEXT,
        profile_photo_base64 TEXT,
        latitude REAL,
        longitude REAL,
        work_time_mode TEXT,
        organization_member_id INTEGER,
        user_name TEXT,
        is_synced INTEGER DEFAULT 0,
        sync_error TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    // Create index for faster queries
    await db.execute('''
      CREATE INDEX idx_synced ON offline_attendances(is_synced)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_created_at ON offline_attendances(created_at)
    ''');

    // Create cached members table
    await db.execute('''
      CREATE TABLE cached_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        organization_member_id INTEGER NOT NULL,
        card_number TEXT,
        display_name TEXT,
        first_name TEXT,
        last_name TEXT,
        profile_photo_url TEXT,
        profile_photo_base64 TEXT,
        department_id INTEGER,
        department_name TEXT,
        organization_id INTEGER NOT NULL,
        user_id TEXT,
        is_active INTEGER DEFAULT 1,
        cached_at TEXT NOT NULL,
        UNIQUE(organization_member_id, card_number)
      )
    ''');

    // Create indexes for cached members
    await db.execute('''
      CREATE INDEX idx_card_number ON cached_members(card_number)
    ''');
    
    await db.execute('''
      CREATE INDEX idx_org_member ON cached_members(organization_member_id)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Create cached members table if upgrading from version 1
      await db.execute('''
        CREATE TABLE IF NOT EXISTS cached_members (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          organization_member_id INTEGER NOT NULL,
          card_number TEXT,
          display_name TEXT,
          first_name TEXT,
          last_name TEXT,
          profile_photo_url TEXT,
          profile_photo_base64 TEXT,
          department_id INTEGER,
          department_name TEXT,
          organization_id INTEGER NOT NULL,
          user_id TEXT,
          is_active INTEGER DEFAULT 1,
          cached_at TEXT NOT NULL,
          UNIQUE(organization_member_id, card_number)
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_card_number ON cached_members(card_number)
      ''');
      
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_org_member ON cached_members(organization_member_id)
      ''');
    }

    if (oldVersion < 3) {
      // Add base64 fields for photos and captured faces
      await db.execute('ALTER TABLE offline_attendances ADD COLUMN captured_photo_base64 TEXT');
      await db.execute('ALTER TABLE offline_attendances ADD COLUMN profile_photo_base64 TEXT');
      await db.execute('ALTER TABLE cached_members ADD COLUMN profile_photo_base64 TEXT');
    }

    if (oldVersion < 4) {
      // Create biometric data table for offline face validation
      await db.execute('''
        CREATE TABLE IF NOT EXISTS biometric_data (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          organization_member_id INTEGER NOT NULL,
          biometric_type TEXT NOT NULL,
          template_data TEXT NOT NULL,
          device_id INTEGER,
          enrollment_date TEXT NOT NULL,
          last_used_at TEXT,
          is_active INTEGER DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          UNIQUE(organization_member_id, biometric_type)
        )
      ''');

      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_biometric_member ON biometric_data(organization_member_id)
      ''');
      
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_biometric_type ON biometric_data(biometric_type)
      ''');
    }
  }

  // Insert attendance
  Future<int> insertAttendance(OfflineAttendance attendance) async {
    try {
      final db = await database;
      final map = attendance.toMap();
      debugPrint('📝 Inserting attendance: method=${attendance.method}, memberId=${attendance.organizationMemberId}, eventType=${attendance.eventType}');
      final id = await db.insert('offline_attendances', map);
      debugPrint('✅ Attendance inserted with ID: $id');
      return id;
    } catch (e) {
      debugPrint('❌ Error inserting offline attendance: $e');
      debugPrint('   Method: ${attendance.method}');
      debugPrint('   Member ID: ${attendance.organizationMemberId}');
      debugPrint('   Event Type: ${attendance.eventType}');
      rethrow;
    }
  }

  // Get all unsynced attendances (only RFID, skip face recognition)
  Future<List<OfflineAttendance>> getUnsyncedAttendances() async {
    try {
      final db = await database;
      // Include RFID and Face Recognition records
      final results = await db.query(
        'offline_attendances',
        where: 'is_synced = ? AND method IN (?, ?, ?)',
        whereArgs: [0, 'rfid_card_mobile', 'FACERECOGNITION', 'face_recognition'],
        orderBy: 'created_at ASC',
      );
      return results.map((map) => OfflineAttendance.fromMap(map)).toList();
    } catch (e) {
      debugPrint('Error getting unsynced attendances: $e');
      return [];
    }
  }

  // Get all attendances (for display)
  Future<List<OfflineAttendance>> getAllAttendances({int limit = 50}) async {
    try {
      final db = await database;
      final results = await db.query(
        'offline_attendances',
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return results.map((map) => OfflineAttendance.fromMap(map)).toList();
    } catch (e) {
      debugPrint('Error getting all attendances: $e');
      return [];
    }
  }

  // Update attendance sync status
  Future<int> updateSyncStatus({
    required int id,
    required bool isSynced,
    String? syncError,
  }) async {
    try {
      final db = await database;
      return await db.update(
        'offline_attendances',
        {
          'is_synced': isSynced ? 1 : 0,
          'sync_error': syncError,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('Error updating sync status: $e');
      return 0;
    }
  }

  // Delete synced attendances (deprecated - use deleteSuccessfullySyncedAttendances instead)
  Future<int> deleteSyncedAttendances() async {
    return await deleteSuccessfullySyncedAttendances();
  }

  // Delete only successfully synced attendances (no errors)
  Future<int> deleteSuccessfullySyncedAttendances() async {
    try {
      final db = await database;
      // Only delete records that are synced AND have no sync error
      // This ensures failed records are kept for retry
      return await db.delete(
        'offline_attendances',
        where: 'is_synced = ? AND (sync_error IS NULL OR sync_error = ?)',
        whereArgs: [1, ''],
      );
    } catch (e) {
      debugPrint('Error deleting successfully synced attendances: $e');
      return 0;
    }
  }

  // Delete a specific attendance record by ID
  Future<int> deleteAttendance(int id) async {
    try {
      final db = await database;
      return await db.delete(
        'offline_attendances',
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('Error deleting attendance: $e');
      return 0;
    }
  }

  // Delete duplicate records (marked as synced with duplicate error)
  Future<int> deleteDuplicateRecords() async {
    try {
      final db = await database;
      // Delete records that are marked as synced but have duplicate error
      // These are records that were detected as duplicate during sync
      return await db.delete(
        'offline_attendances',
        where: 'is_synced = ? AND sync_error LIKE ?',
        whereArgs: [1, '%Duplicate%'],
      );
    } catch (e) {
      debugPrint('Error deleting duplicate records: $e');
      return 0;
    }
  }

  // Get count of unsynced records (only RFID, skip face recognition)
  Future<int> getUnsyncedCount() async {
    try {
      final db = await database;
      // Count RFID and face recognition records
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM offline_attendances WHERE is_synced = 0 AND method IN (?, ?, ?)',
        ['rfid_card_mobile', 'FACERECOGNITION', 'face_recognition'],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    } catch (e) {
      debugPrint('Error getting unsynced count: $e');
      return 0;
    }
  }

  // Clear all data (use with caution)
  Future<void> clearAllData() async {
    try {
      final db = await database;
      await db.delete('offline_attendances');
    } catch (e) {
      debugPrint('Error clearing all data: $e');
    }
  }

  // Update attendance record user name
  Future<int> updateAttendanceUserName(int id, String userName) async {
    try {
      final db = await database;
      return await db.update(
        'offline_attendances',
        {'user_name': userName},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('Error updating attendance user name: $e');
      return 0;
    }
  }

  // Cache member data for offline use
  Future<void> cacheMemberData(Map<String, dynamic> memberData) async {
    try {
      final db = await database;
      
      final memberInfo = memberData['organization_members'] as Map<String, dynamic>?;
      if (memberInfo == null) {
        debugPrint('⚠️ No organization_members data found');
        return;
      }

      final cardNumber = memberData['card_number'] as String?;
      final orgMemberId = memberData['organization_member_id'] as int?;
      
      if (orgMemberId == null) {
        debugPrint('⚠️ No organization_member_id found');
        return;
      }

      // Extract user profile data
      final profile = memberInfo['user_profiles'] as Map<String, dynamic>?;
      final displayName = profile?['display_name'] as String?;
      final firstName = profile?['first_name'] as String?;
      final lastName = profile?['last_name'] as String?;
      final profilePhotoUrl = profile?['profile_photo_url'] as String?;
      String? profilePhotoBase64;
      if (profilePhotoUrl != null && profilePhotoUrl.isNotEmpty) {
        profilePhotoBase64 = await _downloadPhotoAsBase64(profilePhotoUrl);
      }

      // Extract department data
      final department = memberInfo['departments'] as Map<String, dynamic>?;
      final departmentId = memberInfo['department_id'] as int?;
      final departmentName = department?['name'] as String?;

      final dataToCache = {
        'organization_member_id': orgMemberId,
        'card_number': cardNumber,
        'display_name': displayName,
        'first_name': firstName,
        'last_name': lastName,
        'profile_photo_url': profilePhotoUrl,
        'profile_photo_base64': profilePhotoBase64,
        'department_id': departmentId,
        'department_name': departmentName,
        'organization_id': memberInfo['organization_id'],
        'user_id': memberInfo['user_id'],
        'is_active': 1,
        'cached_at': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
      };

      await db.insert(
        'cached_members',
        dataToCache,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      debugPrint('✅ Cached member: ${displayName ?? '$firstName $lastName'} (Card: $cardNumber)');
    } catch (e) {
      debugPrint('❌ Error caching member data: $e');
    }
  }

  // Find member by card number in cache
  Future<Map<String, dynamic>?> findMemberByCardInCache(String cardNumber, int organizationId) async {
    try {
      final db = await database;
      // Normalize card number for search
      final normalizedCardNumber = cardNumber.trim();
      
      // Try exact match first
      var results = await db.query(
        'cached_members',
        where: 'card_number = ? AND organization_id = ? AND is_active = 1',
        whereArgs: [normalizedCardNumber, organizationId],
      );

      // If not found, try case-insensitive search
      if (results.isEmpty) {
        debugPrint('🔍 Trying case-insensitive search in cache...');
        final allCached = await db.query(
          'cached_members',
          where: 'organization_id = ? AND is_active = 1',
          whereArgs: [organizationId],
        );
        
        results = allCached.where((member) {
          final cachedCard = (member['card_number'] as String?)?.trim() ?? '';
          return cachedCard.toLowerCase() == normalizedCardNumber.toLowerCase();
        }).toList();
      }

      if (results.isEmpty) {
        debugPrint('❌ Card "$normalizedCardNumber" not found in cache');
        return null;
      }

      final cachedMember = results.first;
      
      debugPrint('✅ Found cached member: ${cachedMember['display_name'] ?? '${cachedMember['first_name']} ${cachedMember['last_name']}'}');
      
      // Return in same format as Supabase query
      return {
        'id': cachedMember['id'],
        'card_number': cachedMember['card_number'],
        'organization_member_id': cachedMember['organization_member_id'],
        'organization_members': {
          'id': cachedMember['organization_member_id'],
          'organization_id': cachedMember['organization_id'],
          'user_id': cachedMember['user_id'],
          'department_id': cachedMember['department_id'],
          'user_profiles': {
            'display_name': cachedMember['display_name'],
            'first_name': cachedMember['first_name'],
            'last_name': cachedMember['last_name'],
            'profile_photo_url': cachedMember['profile_photo_base64'] != null && (cachedMember['profile_photo_base64'] as String).isNotEmpty
                ? 'data:image/jpeg;base64,${cachedMember['profile_photo_base64']}'
                : cachedMember['profile_photo_url'],
            'profile_photo_base64': cachedMember['profile_photo_base64'],
          },
          'departments': cachedMember['department_name'] != null 
            ? {
                'id': cachedMember['department_id'], 
                'name': cachedMember['department_name']
              }
            : null,
        }
      };
    } catch (e) {
      debugPrint('❌ Error finding member in cache: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> findMemberByOrgIdInCache(int organizationMemberId) async {
    try {
      final db = await database;
      final results = await db.query(
        'cached_members',
        where: 'organization_member_id = ? AND is_active = 1',
        whereArgs: [organizationMemberId],
        limit: 1,
      );

      if (results.isEmpty) return null;
      final cachedMember = results.first;

      return {
        'organization_member_id': cachedMember['organization_member_id'],
        'organization_members': {
          'id': cachedMember['organization_member_id'],
          'organization_id': cachedMember['organization_id'],
          'user_id': cachedMember['user_id'],
          'department_id': cachedMember['department_id'],
          'user_profiles': {
            'display_name': cachedMember['display_name'],
            'first_name': cachedMember['first_name'],
            'last_name': cachedMember['last_name'],
            'profile_photo_url': cachedMember['profile_photo_base64'] != null && (cachedMember['profile_photo_base64'] as String).isNotEmpty
                ? 'data:image/jpeg;base64,${cachedMember['profile_photo_base64']}'
                : cachedMember['profile_photo_url'],
            'profile_photo_base64': cachedMember['profile_photo_base64'],
          },
          'departments': cachedMember['department_name'] != null
              ? {
                  'id': cachedMember['department_id'],
                  'name': cachedMember['department_name'],
                }
              : null,
        }
      };
    } catch (e) {
      debugPrint('❌ Error finding member by orgId in cache: $e');
      return null;
    }
  }

  // Get cached member statistics
  Future<Map<String, int>> getCacheStats() async {
    try {
      final db = await database;
      final totalResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM cached_members',
      );
      final activeResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM cached_members WHERE is_active = 1',
      );
      
      return {
        'total': Sqflite.firstIntValue(totalResult) ?? 0,
        'active': Sqflite.firstIntValue(activeResult) ?? 0,
      };
    } catch (e) {
      debugPrint('Error getting cache stats: $e');
      return {'total': 0, 'active': 0};
    }
  }

  // Clear cached members
  Future<void> clearCachedMembers() async {
    try {
      final db = await database;
      await db.delete('cached_members');
      debugPrint('✅ Cleared all cached members');
    } catch (e) {
      debugPrint('❌ Error clearing cached members: $e');
    }
  }

  // Delete specific member from cache by card number
  Future<void> deleteMemberFromCache(String cardNumber) async {
    try {
      final db = await database;
      await db.delete(
        'cached_members',
        where: 'card_number = ?',
        whereArgs: [cardNumber],
      );
      debugPrint('✅ Deleted member from cache: $cardNumber');
    } catch (e) {
      debugPrint('❌ Error deleting member from cache: $e');
    }
  }

  // Get all cached members for debugging
  Future<List<Map<String, dynamic>>> getAllCachedMembers() async {
    try {
      final db = await database;
      return await db.query('cached_members', orderBy: 'cached_at DESC');
    } catch (e) {
      debugPrint('Error getting all cached members: $e');
      return [];
    }
  }

  Future<String?> _downloadPhotoAsBase64(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        debugPrint('⚠️ Failed to download photo ($url): HTTP ${response.statusCode}');
        return null;
      }

      final bytes = await consolidateHttpClientResponseBytes(response);
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('⚠️ Could not download photo: $e');
      return null;
    }
  }

  // Check for duplicate attendance (debounced by 2 minutes to prevent double-taps)
  Future<bool> hasDuplicateAttendance({
    required int organizationMemberId,
    required String eventType,
    required String attendanceDate,
    String? workTimeMode, // ✅ NEW: Check shift-specific duplicates
  }) async {
    try {
      final db = await database;
      
      final now = DateTime.now().toUtc();
      final twoMinutesAgo = now.subtract(const Duration(minutes: 2)).toIso8601String();
      
      String whereClause = 'organization_member_id = ? AND event_type = ? AND created_at > ?';
      List<dynamic> whereArgs = [organizationMemberId, eventType, twoMinutesAgo];
      
      // ✅ ENHANCED: For multi-shift, also check work_time_mode
      if (workTimeMode != null && workTimeMode.isNotEmpty) {
        whereClause += ' AND work_time_mode = ?';
        whereArgs.add(workTimeMode);
      }
      
      final result = await db.query(
        'offline_attendances',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'created_at DESC',
        limit: 1,
      );

      if (result.isNotEmpty) {
        final lastRecord = result.first;
        final diff = now.difference(DateTime.parse(lastRecord['created_at'] as String));
        debugPrint('⚠️ Duplicate check: Last $eventType was ${diff.inSeconds}s ago (Mode: ${lastRecord['work_time_mode']})');
        return true;
      }
      
      return false;
    } catch (e) {
      debugPrint('Error checking duplicate attendance: $e');
      return false;
    }
  }

  // Biometric data operations for offline face validation
  Future<void> cacheBiometricData({
    required int organizationMemberId,
    required String biometricType,
    required String templateData,
    int? deviceId,
  }) async {
    try {
      final db = await database;
      final now = TimezoneHelper.formatUtcForSupabase(DateTime.now());
      
      await db.insert(
        'biometric_data',
        {
          'organization_member_id': organizationMemberId,
          'biometric_type': biometricType,
          'template_data': templateData,
          'device_id': deviceId,
          'enrollment_date': now,
          'last_used_at': now,
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      debugPrint('✅ Cached biometric data for member $organizationMemberId, type: $biometricType');
    } catch (e) {
      debugPrint('❌ Error caching biometric data: $e');
    }
  }

  Future<bool> hasBiometricData({
    required int organizationMemberId,
    required String biometricType,
  }) async {
    try {
      final db = await database;
      
      final result = await db.query(
        'biometric_data',
        where: 'organization_member_id = ? AND biometric_type = ? AND is_active = 1',
        whereArgs: [organizationMemberId, biometricType],
      );
      
      return result.isNotEmpty;
    } catch (e) {
      debugPrint('Error checking biometric data: $e');
      return false;
    }
  }

  Future<String?> getBiometricTemplate({
    required int organizationMemberId,
    required String biometricType,
  }) async {
    try {
      final db = await database;
      
      final result = await db.query(
        'biometric_data',
        where: 'organization_member_id = ? AND biometric_type = ? AND is_active = 1',
        whereArgs: [organizationMemberId, biometricType],
        limit: 1,
      );
      
      if (result.isNotEmpty) {
        return result.first['template_data'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('Error getting biometric template: $e');
      return null;
    }
  }

  Future<void> updateBiometricLastUsed({
    required int organizationMemberId,
    required String biometricType,
  }) async {
    try {
      final db = await database;
      final now = TimezoneHelper.formatUtcForSupabase(DateTime.now());
      
      await db.update(
        'biometric_data',
        {'last_used_at': now, 'updated_at': now},
        where: 'organization_member_id = ? AND biometric_type = ?',
        whereArgs: [organizationMemberId, biometricType],
      );
    } catch (e) {
      debugPrint('Error updating biometric last used: $e');
    }
  }

  Future<void> clearBiometricData() async {
    try {
      final db = await database;
      await db.delete('biometric_data');
      debugPrint('✅ Cleared all biometric data');
    } catch (e) {
      debugPrint('Error clearing biometric data: $e');
    }
  }

  // ✅ NEW: Get all biometric data with user info from SQLite for offline use
  Future<List<Map<String, dynamic>>> getAllBiometricDataWithUserInfo({
    required int organizationId,
  }) async {
    try {
      final db = await database;
      
      // Get all biometric data for the organization
      // Join with cached_members to get user info (using direct columns, not JSON)
      final biometricResults = await db.rawQuery('''
        SELECT 
          bd.id,
          bd.organization_member_id,
          bd.template_data,
          bd.enrollment_date,
          bd.last_used_at,
          cm.id as cm_id,
          cm.user_id,
          cm.employee_id,
          cm.department_id,
          cm.first_name,
          cm.last_name,
          cm.display_name,
          cm.profile_photo_url,
          cm.department_name
        FROM biometric_data bd
        LEFT JOIN cached_members cm ON bd.organization_member_id = cm.organization_member_id
          AND cm.organization_id = ?
          AND cm.is_active = 1
        WHERE bd.biometric_type = 'face_recognition'
          AND bd.is_active = 1
      ''', [organizationId]);

      final results = <Map<String, dynamic>>[];
      
      for (var row in biometricResults) {
        try {
          // Build result in same format as Supabase query
          final result = {
            'id': row['id'],
            'organization_member_id': row['organization_member_id'],
            'template_data': row['template_data'],
            'enrollment_date': row['enrollment_date'],
            'last_used_at': row['last_used_at'],
            'organization_members': row['cm_id'] != null ? {
              'id': row['organization_member_id'],
              'user_id': row['user_id'],
              'organization_id': organizationId,
              'employee_id': row['employee_id'],
              'department_id': row['department_id'],
              'user_profiles': row['first_name'] != null ? {
                'id': row['cm_id'], // Use cached_members id as proxy
                'first_name': row['first_name'],
                'last_name': row['last_name'],
                'display_name': row['display_name'] ?? '${row['first_name']} ${row['last_name']}',
                'profile_photo_url': row['profile_photo_url'],
              } : null,
              'departments': row['department_name'] != null ? {
                'id': row['department_id'],
                'name': row['department_name'],
              } : null,
            } : {
              'id': row['organization_member_id'],
              'user_id': null,
              'organization_id': organizationId,
              'employee_id': null,
              'department_id': null,
              'user_profiles': null,
              'departments': null,
            },
          };
          
          results.add(result);
        } catch (e) {
          debugPrint('Error parsing biometric row: $e');
          continue;
        }
      }
      
      debugPrint('✅ Retrieved ${results.length} biometric templates from SQLite for offline use');
      return results;
    } catch (e) {
      debugPrint('❌ Error getting biometric data from SQLite: $e');
      return [];
    }
  }
}