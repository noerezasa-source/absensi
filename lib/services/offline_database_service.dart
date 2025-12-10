// lib/services/offline_database_service.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import '../models/offline_attendance.dart';

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
      version: 2, // Increment version for migration
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
      // Only get RFID records, skip face_recognition_kiosk since it syncs directly now
      final results = await db.query(
        'offline_attendances',
        where: 'is_synced = ? AND method = ?',
        whereArgs: [0, 'rfid_card_mobile'],
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
      // Only count RFID records, skip face_recognition_kiosk since it syncs directly now
      final result = await db.rawQuery(
        'SELECT COUNT(*) as count FROM offline_attendances WHERE is_synced = 0 AND method = ?',
        ['rfid_card_mobile'],
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
        'department_id': departmentId,
        'department_name': departmentName,
        'organization_id': memberInfo['organization_id'],
        'user_id': memberInfo['user_id'],
        'is_active': 1,
        'cached_at': DateTime.now().toIso8601String(),
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
            'profile_photo_url': cachedMember['profile_photo_url'],
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

  // Check for duplicate attendance on the same day
  Future<bool> hasDuplicateAttendance({
    required int organizationMemberId,
    required String eventType,
    required String attendanceDate, // Format: YYYY-MM-DD
  }) async {
    try {
      final db = await database;
      
      // Parse the timestamp to get the date
      final results = await db.query(
        'offline_attendances',
        where: 'organization_member_id = ? AND event_type = ?',
        whereArgs: [organizationMemberId, eventType],
        orderBy: 'created_at DESC',
      );

      // Check if any record exists for the same date
      for (final record in results) {
        final timestamp = record['timestamp'] as String;
        final recordDate = DateTime.parse(timestamp).toUtc();
        final recordDateStr = '${recordDate.year}-${recordDate.month.toString().padLeft(2, '0')}-${recordDate.day.toString().padLeft(2, '0')}';
        
        if (recordDateStr == attendanceDate) {
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Error checking duplicate attendance: $e');
      return false;
    }
  }
}