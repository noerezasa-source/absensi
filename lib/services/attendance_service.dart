// lib/services/attendance_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/attendance_record.dart';
import '../models/attendance_log.dart';

class AttendanceService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // Check in attendance
  Future<AttendanceRecord> checkIn({
    required int organizationMemberId,
    required String photoUrl,
    required String method,
    Map<String, dynamic>? location,
  }) async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      // Cek apakah sudah ada record hari ini
      final existingRecord = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', organizationMemberId)
          .eq('attendance_date', today.toIso8601String().split('T')[0])
          .maybeSingle();

      Map<String, dynamic> recordData;

      if (existingRecord != null) {
        // Update existing record
        recordData = {
          'actual_check_in': now.toIso8601String(),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': location,
          'status': 'present',
          'updated_at': now.toIso8601String(),
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
          'actual_check_in': now.toIso8601String(),
          'check_in_method': method,
          'check_in_photo_url': photoUrl,
          'check_in_location': location,
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
        location: location,
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

      // Calculate work duration
      final checkInTime = DateTime.parse(existingRecord['actual_check_in']);
      final workDuration = now.difference(checkInTime).inMinutes;

      // Update record
      final recordData = {
        'actual_check_out': now.toIso8601String(),
        'check_out_method': method,
        'check_out_photo_url': photoUrl,
        'check_out_location': location,
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
        location: location,
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
      final todayStr = DateTime(today.year, today.month, today.day)
          .toIso8601String()
          .split('T')[0];

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
        query = query.gte('attendance_date', startDate.toIso8601String().split('T')[0]);
      }

      if (endDate != null) {
        query = query.lte('attendance_date', endDate.toIso8601String().split('T')[0]);
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
  }) async {
    try {
      final logData = {
        'organization_member_id': organizationMemberId,
        'attendance_record_id': attendanceRecordId,
        'event_type': eventType,
        'event_time': DateTime.now().toIso8601String(),
        'method': method,
        'location': location,
        'is_verified': method == 'face_recognition',
        'verification_method': method == 'face_recognition' ? 'face_recognition' : null,
      };

      await _supabase.from('attendance_logs').insert(logData);
    } catch (e) {
      // Log error tapi jangan throw exception
      print('Failed to create attendance log: $e');
    }
  }
}