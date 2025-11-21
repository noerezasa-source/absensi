// lib/services/attendance_service.dart
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_record.dart';

class AttendanceService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Check in attendance
  Future<AttendanceRecord> checkIn({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // Cek apakah sudah ada record hari ini
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', today.toIso8601String().split('T')[0])
          .maybeSingle();

      Map<String, dynamic> recordData;

      if (existingRecord != null) {
        // ✅ Jika sudah check-in, jangan update lagi
        if (existingRecord['actual_check_in'] != null) {
          throw Exception(
            'Already checked in today at ${existingRecord['actual_check_in']}',
          );
        }

        // Update existing record (save as UTC)
        recordData = {
          'actual_check_in': now.toUtc().toIso8601String(),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': locationWithPhoto,
          'status': 'present',
          'updated_at': now.toUtc().toIso8601String(),
        };

        await _supabase
            .from('attendance_records')
            .update(recordData)
            .eq('id', existingRecord['id']);

        recordData['id'] = existingRecord['id'];
        recordData['organization_member_id'] = organizationMemberId;
        recordData['attendance_date'] = today.toIso8601String().split('T')[0];
      } else {
        // Create new record
        recordData = {
          'organization_member_id': organizationMemberId,
          'attendance_date': today.toIso8601String().split('T')[0],
          'actual_check_in': now.toUtc().toIso8601String(),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': locationWithPhoto,
          'status': 'present',
          'validation_status': 'pending',
        };

        final result = await _supabase
            .from('attendance_records')
            .insert(recordData)
            .select()
            .single();

        recordData = result;
      }

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: recordData['id'],
        eventType: 'check_in',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: rawData,
      );

      return AttendanceRecord.fromJson(recordData);
    } catch (e) {
      throw Exception('Failed to check in: $e');
    }
  }

  // Check out attendance
  Future<AttendanceRecord> checkOut({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Cari record hari ini
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', today.toIso8601String().split('T')[0])
          .maybeSingle();

      if (existingRecord == null) {
        throw Exception('No check-in record found for today');
      }

      if (existingRecord['actual_check_in'] == null) {
        throw Exception('Please check in first');
      }

      // ✅ Jika sudah check-out, jangan update lagi
      if (existingRecord['actual_check_out'] != null) {
        throw Exception(
          'Already checked out today at ${existingRecord['actual_check_out']}',
        );
      }

      // Calculate work duration
      final checkInTime = DateTime.parse(existingRecord['actual_check_in']);
      final workDuration = now.difference(checkInTime).inMinutes;

      final locationWithPhoto = _decorateLocationWithPhoto(location, photoUrl);

      // Update record
      final recordData = {
        'actual_check_out': now.toUtc().toIso8601String(),
        'check_out_method': method,
        'check_out_photo_url': photoUrl,
        'check_out_location': locationWithPhoto,
        'work_duration_minutes': workDuration,
        'updated_at': now.toIso8601String(),
      };

      await _supabase
          .from('attendance_records')
          .update(recordData)
          .eq('id', existingRecord['id']);

      // Create attendance log
      await _createAttendanceLog(
        organizationMemberId: organizationMemberId,
        attendanceRecordId: existingRecord['id'],
        eventType: 'check_out',
        method: method,
        location: locationWithPhoto,
        deviceId: deviceId,
        ipAddress: ipAddress,
        userAgent: userAgent,
        applicationId: applicationId,
        rawData: rawData,
      );

      final updatedRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('id', existingRecord['id'])
          .single();

      return AttendanceRecord.fromJson(updatedRecord);
    } catch (e) {
      throw Exception('Failed to check out: $e');
    }
  }

  // Get today's attendance
  Future<AttendanceRecord?> getTodayAttendance(int organizationMemberId) async {
    try {
      final today = DateTime.now();
      final todayStr = DateTime(
        today.year,
        today.month,
        today.day,
      ).toIso8601String().split('T')[0];

      final record = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', todayStr)
          .maybeSingle();

      if (record == null) return null;

      return AttendanceRecord.fromJson(record);
    } catch (e) {
      throw Exception('Failed to get today attendance: $e');
    }
  }

  // Get attendance history
  Future<List<AttendanceRecord>> getAttendanceHistory({
    required int organizationMemberId,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) async {
    try {
      var query = _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId);

      if (startDate != null) {
        query = query.gte(
          'attendance_date',
          startDate.toIso8601String().split('T')[0],
        );
      }

      if (endDate != null) {
        query = query.lte(
          'attendance_date',
          endDate.toIso8601String().split('T')[0],
        );
      }

      final records = await query
          .order('attendance_date', ascending: false)
          .limit(limit);

      return (records as List)
          .map((record) => AttendanceRecord.fromJson(record))
          .toList();
    } catch (e) {
      throw Exception('Failed to get attendance history: $e');
    }
  }

  // Create attendance log
  Future<void> _createAttendanceLog({
    required int organizationMemberId,
    required int attendanceRecordId,
    required String eventType,
    required String method,
    Map<String, dynamic>? location,
    int? deviceId,
    String? ipAddress,
    String? userAgent,
    int? applicationId,
    Map<String, dynamic>? rawData,
  }) async {
    try {
      final logData = {
        'organization_member_id': organizationMemberId,
        'attendance_record_id': attendanceRecordId,
        'event_type': eventType,
        'event_time': DateTime.now().toUtc().toIso8601String(),
        'method': method,
        'location': location,
        'device_id': deviceId,
        'ip_address': ipAddress,
        'user_agent': userAgent,
        'application_id': applicationId,
        'raw_data': rawData,
        'is_verified':
            method == 'face_recognition' || method == 'face_recognition_kiosk',
        'verification_method': method.contains('face_recognition')
            ? 'face_recognition'
            : null,
      };

      await _supabase.from('attendance_logs').insert(logData);
    } catch (e) {
      // Log error tapi jangan throw exception
      debugPrint('Failed to create attendance log: $e');
    }
  }

  Future<Map<String, int>> getOrganizationTodayStats(int organizationId) async {
    final today = DateTime.now();
    final todayStr = DateTime(
      today.year,
      today.month,
      today.day,
    ).toIso8601String().split('T')[0];

    try {
      final records = await _supabase
          .from('attendance_records')
          .select('''
            id,
            actual_check_in,
            actual_check_out,
            validation_status,
            late_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('attendance_date', todayStr)
          .eq('organization_members.organization_id', organizationId);

      int checkedIn = 0;
      int checkedOut = 0;
      int pending = 0;
      int late = 0;

      for (final record in records as List<dynamic>) {
        final data = record as Map<String, dynamic>;

        if (data['actual_check_in'] != null) {
          checkedIn++;
        }

        if (data['actual_check_out'] != null) {
          checkedOut++;
        }

        if ((data['validation_status'] as String?) == 'pending') {
          pending++;
        }

        final lateMinutes = data['late_minutes'];
        if (lateMinutes is int && lateMinutes > 0) {
          late++;
        }
      }

      return {'checked_in': checkedIn, 'checked_out': checkedOut, 'pending': pending, 'late': late};
    } catch (e) {
      throw Exception('Failed to load organization stats: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getOrganizationRecentActivities({
    required int organizationId,
    int limit = 10,
  }) async {
    try {
      final logs = await _supabase
          .from('attendance_logs')
          .select('''
            id,
            event_type,
            event_time,
            method,
            organization_members!inner(
              id,
              organization_id,
              user_profiles!inner(
                display_name,
                first_name,
                last_name,
                profile_photo_url
              )
            ),
            attendance_records (
              attendance_date,
              status
            )
          ''')
          .eq('organization_members.organization_id', organizationId)
          .inFilter('method', ['face_recognition', 'face_recognition_kiosk', 'rfid_card', 'rfid_card_mobile'])
          .order('event_time', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(logs);
    } catch (e) {
      throw Exception('Failed to load recent activities: $e');
    }
  }

  Map<String, dynamic>? _decorateLocationWithPhoto(
    Map<String, dynamic>? location,
    String photoUrl,
  ) {
    if (photoUrl.trim().isEmpty) {
      return location;
    }

    final updatedLocation = location != null
        ? Map<String, dynamic>.from(location)
        : <String, dynamic>{};

    updatedLocation['photo_url'] = photoUrl;
    return updatedLocation;
  }
}
