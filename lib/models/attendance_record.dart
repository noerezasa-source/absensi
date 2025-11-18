// lib/models/attendance_record.dart
class AttendanceRecord {
  final int? id;
  final int organizationMemberId;
  final DateTime attendanceDate;
  final int? scheduledShiftId;
  final String? scheduledStart;
  final String? scheduledEnd;
  final DateTime? actualCheckIn;
  final DateTime? actualCheckOut;
  final int? checkInDeviceId;
  final int? checkOutDeviceId;
  final String? checkInMethod;
  final String? checkOutMethod;
  final Map<String, dynamic>? checkInLocation;
  final Map<String, dynamic>? checkOutLocation;
  final String? checkInPhotoUrl;
  final String? checkOutPhotoUrl;
  final int? workDurationMinutes;
  final int? breakDurationMinutes;
  final int? overtimeMinutes;
  final int? lateMinutes;
  final int? earlyLeaveMinutes;
  final String? status;
  final String validationStatus;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  AttendanceRecord({
    this.id,
    required this.organizationMemberId,
    required this.attendanceDate,
    this.scheduledShiftId,
    this.scheduledStart,
    this.scheduledEnd,
    this.actualCheckIn,
    this.actualCheckOut,
    this.checkInDeviceId,
    this.checkOutDeviceId,
    this.checkInMethod,
    this.checkOutMethod,
    this.checkInLocation,
    this.checkOutLocation,
    this.checkInPhotoUrl,
    this.checkOutPhotoUrl,
    this.workDurationMinutes,
    this.breakDurationMinutes,
    this.overtimeMinutes,
    this.lateMinutes,
    this.earlyLeaveMinutes,
    this.status,
    this.validationStatus = 'pending',
    this.createdAt,
    this.updatedAt,
  });

  factory AttendanceRecord.fromJson(Map<String, dynamic> json) {
    return AttendanceRecord(
      id: json['id'],
      organizationMemberId: json['organization_member_id'],
      attendanceDate: DateTime.parse(json['attendance_date']),
      scheduledShiftId: json['scheduled_shift_id'],
      scheduledStart: json['scheduled_start'],
      scheduledEnd: json['scheduled_end'],
      actualCheckIn: json['actual_check_in'] != null
          ? DateTime.parse(json['actual_check_in'])
          : null,
      actualCheckOut: json['actual_check_out'] != null
          ? DateTime.parse(json['actual_check_out'])
          : null,
      checkInDeviceId: json['check_in_device_id'],
      checkOutDeviceId: json['check_out_device_id'],
      checkInMethod: json['check_in_method'],
      checkOutMethod: json['check_out_method'],
      checkInLocation: json['check_in_location'],
      checkOutLocation: json['check_out_location'],
      checkInPhotoUrl: json['check_in_photo_url'],
      checkOutPhotoUrl: json['check_out_photo_url'],
      workDurationMinutes: json['work_duration_minutes'],
      breakDurationMinutes: json['break_duration_minutes'],
      overtimeMinutes: json['overtime_minutes'],
      lateMinutes: json['late_minutes'],
      earlyLeaveMinutes: json['early_leave_minutes'],
      status: json['status'],
      validationStatus: json['validation_status'] ?? 'pending',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'])
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'organization_member_id': organizationMemberId,
      'attendance_date': attendanceDate.toIso8601String().split('T')[0],
      'scheduled_shift_id': scheduledShiftId,
      'scheduled_start': scheduledStart,
      'scheduled_end': scheduledEnd,
      'actual_check_in': actualCheckIn?.toIso8601String(),
      'actual_check_out': actualCheckOut?.toIso8601String(),
      'check_in_device_id': checkInDeviceId,
      'check_out_device_id': checkOutDeviceId,
      'check_in_method': checkInMethod,
      'check_out_method': checkOutMethod,
      'check_in_location': checkInLocation,
      'check_out_location': checkOutLocation,
      'check_in_photo_url': checkInPhotoUrl,
      'check_out_photo_url': checkOutPhotoUrl,
      'work_duration_minutes': workDurationMinutes,
      'break_duration_minutes': breakDurationMinutes,
      'overtime_minutes': overtimeMinutes,
      'late_minutes': lateMinutes,
      'early_leave_minutes': earlyLeaveMinutes,
      'status': status,
      'validation_status': validationStatus,
    };
  }
}