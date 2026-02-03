import 'package:absensimassal/pages/face_registration_page.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import '../../services/biometric_service.dart';
import '../../auth/services/role_service.dart';
import '../widgets/user_bottom_nav.dart';
import 'user_profile_page.dart';

class UserDashboardPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;

  const UserDashboardPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
  });

  @override
  State<UserDashboardPage> createState() => _UserDashboardPageState();
}

class _UserDashboardPageState extends State<UserDashboardPage> with SingleTickerProviderStateMixin {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final _supabase = Supabase.instance.client;

  bool _hasRegisteredFace = false;
  bool _isCheckingFace = true;
  bool _isLoadingProfile = true;
  bool _isLoadingStats = true;
  bool _isLoadingAttendance = true;
  String? _errorMessage;
  Map<String, dynamic>? _userProfile;
  Map<String, dynamic>? _attendanceStats;
  
  // Calendar & Daily Events
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  CalendarFormat _calendarFormat = CalendarFormat.month;
  Map<DateTime, List<Map<String, dynamic>>> _attendanceByDate = {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    print('=== USER DASHBOARD INIT ===');
    print('Organization Member ID: ${widget.organizationMemberId}');
    print('Role: ${_roleService.getRoleName(widget.memberData)}');
    _loadUserProfile();
    _checkFaceRegistration();
    _loadAttendanceStats();
    _loadAttendanceData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoadingProfile = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not logged in');
      }

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _userProfile = response;
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      print('!!! ERROR loading user profile: $e');
      if (mounted) {
        setState(() {
          _isLoadingProfile = false;
          _errorMessage = 'Failed to load profile: $e';
        });
      }
    }
  }

  Future<void> _loadAttendanceStats() async {
  setState(() {
    _isLoadingStats = true;
  });

  try {
    final now = DateTime.now();
    final firstDayOfMonth = DateTime(now.year, now.month, 1);
    final lastDayOfMonth = DateTime(now.year, now.month + 1, 0);

    // Get attendance records for current month - FILTER HANYA FACE RECOGNITION KIOSK
    final records = await _supabase
        .from('attendance_records')
        .select()
        .eq('organization_member_id', widget.organizationMemberId)
        .eq('check_in_method', 'face_recognition_kiosk')
        .gte('attendance_date', firstDayOfMonth.toIso8601String().split('T')[0])
        .lte('attendance_date', lastDayOfMonth.toIso8601String().split('T')[0]);

    int presentDays = 0;
    int lateDays = 0;
    int totalWorkMinutes = 0;

    for (var record in records) {
      // HITUNG PRESENT: Jika ada actual_check_in DAN status = 'present' atau 'late'
      if (record['actual_check_in'] != null) {
        final status = record['status']?.toString().toLowerCase();
        
        // Present jika ada check_in (termasuk yang late)
        if (status == 'present' || status == 'late') {
          presentDays++;
        }
      }

      // HITUNG LATE: Jika late_minutes > 0
      if (record['late_minutes'] != null && record['late_minutes'] > 0) {
        lateDays++;
      }

      // HITUNG WORK HOURS: Dari work_duration_minutes
      if (record['work_duration_minutes'] != null) {
        totalWorkMinutes += (record['work_duration_minutes'] as int);
      }
    }

    // Konversi minutes ke hours dengan 1 desimal
    final workHours = (totalWorkMinutes / 60).toStringAsFixed(1);

    if (mounted) {
      setState(() {
        _attendanceStats = {
          'present_days': presentDays,
          'late_days': lateDays,
          'work_hours': workHours,
          'total_records': records.length,
        };
        _isLoadingStats = false;
      });
      
      // Debug print untuk memastikan
      print('=== ATTENDANCE STATS ===');
      print('Total Records: ${records.length}');
      print('Present Days: $presentDays');
      print('Late Days: $lateDays');
      print('Work Hours: $workHours');
    }
  } catch (e) {
    print('!!! ERROR loading attendance stats: $e');
    if (mounted) {
      setState(() {
        _attendanceStats = {
          'present_days': 0,
          'late_days': 0,
          'work_hours': '0.0',
          'total_records': 0,
        };
        _isLoadingStats = false;
      });
    }
  }
}

  Future<void> _loadAttendanceData() async {
    setState(() {
      _isLoadingAttendance = true;
    });

    try {
      final now = DateTime.now();
      final firstDayOfMonth = DateTime(now.year, now.month, 1);
      final lastDayOfMonth = DateTime(now.year, now.month + 1, 0);

      // Load attendance records untuk calendar
      final records = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('check_in_method', 'face_recognition_kiosk')
          .gte('attendance_date', firstDayOfMonth.toIso8601String().split('T')[0])
          .lte('attendance_date', lastDayOfMonth.toIso8601String().split('T')[0])
          .order('attendance_date', ascending: false);

      if (mounted) {
        _processAttendanceRecords(records);
        setState(() {
          _isLoadingAttendance = false;
        });
      }
    } catch (e) {
      print('!!! ERROR loading attendance data: $e');
      if (mounted) {
        setState(() {
          _isLoadingAttendance = false;
        });
      }
    }
  }

  void _processAttendanceRecords(List<dynamic> records) {
    final Map<DateTime, List<Map<String, dynamic>>> groupedData = {};

    for (var record in records) {
      try {
        final attendanceDate = DateTime.parse(record['attendance_date']);
        final dateOnly = DateTime(attendanceDate.year, attendanceDate.month, attendanceDate.day);

        groupedData[dateOnly] ??= [];

        // Add check-in event
        if (record['actual_check_in'] != null) {
          groupedData[dateOnly]!.add({
            'type': 'check_in',
            'event_time': record['actual_check_in'],
            'photo_url': record['check_in_photo_url'],
            'location': record['check_in_location'],
            'method': record['check_in_method'],
            'status': record['status'],
            'late_minutes': record['late_minutes'],
          });
        }

        // Add check-out event
        if (record['actual_check_out'] != null) {
          groupedData[dateOnly]!.add({
            'type': 'check_out',
            'event_time': record['actual_check_out'],
            'photo_url': record['check_out_photo_url'],
            'location': record['check_out_location'],
            'method': record['check_out_method'],
            'status': record['status'],
            'work_duration_minutes': record['work_duration_minutes'],
          });
        }
      } catch (e) {
        print('Error processing record: $e');
      }
    }

    // Sort events by time
    for (final dateEvents in groupedData.values) {
      dateEvents.sort((a, b) {
        final timeA = DateTime.parse(a['event_time']);
        final timeB = DateTime.parse(b['event_time']);
        return timeA.compareTo(timeB);
      });
    }

    setState(() {
      _attendanceByDate = groupedData;
    });
  }

  Future<void> _checkFaceRegistration() async {
    setState(() {
      _isCheckingFace = true;
      _errorMessage = null;
    });
    
    try {
      print('=== CHECKING FACE REGISTRATION ===');
      
      final hasRegistered = await _biometricService.hasRegisteredFace(
        widget.organizationMemberId,
      );
      
      print('Face registration check result: $hasRegistered');
      
      if (mounted) {
        setState(() {
          _hasRegisteredFace = hasRegistered;
          _isCheckingFace = false;
        });
      }
    } catch (e) {
      print('!!! ERROR checking face registration: $e');
      if (mounted) {
        setState(() {
          _hasRegisteredFace = false;
          _isCheckingFace = false;
          _errorMessage = 'Failed to check face: $e';
        });
      }
    }
  }

  Future<void> _navigateToFaceRegistration() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FaceRegistrationPage(
          organizationMemberId: widget.organizationMemberId,
        ),
      ),
    );

    if (result == true) {
      _checkFaceRegistration();
    }
  }

  void _navigateToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserProfilePage(
          organizationMemberId: widget.organizationMemberId,
          memberData: widget.memberData,
          userProfile: _userProfile,
        ),
      ),
    );
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    final weekday = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][now.weekday - 1];
    final month = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][now.month - 1];
    return '$weekday, ${now.day} $month ${now.year}';
  }

  String _getFullName() {
    if (_userProfile == null) return 'Loading...';
    final firstName = _userProfile!['first_name'] ?? '';
    final middleName = _userProfile!['middle_name'] ?? '';
    final lastName = _userProfile!['last_name'] ?? '';
    
    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }
    return '$firstName $lastName'.trim();
  }

  String? _getProfilePhotoUrl() {
    if (_userProfile == null || _userProfile!['profile_photo_url'] == null) {
      return null;
    }
    
    final photoPath = _userProfile!['profile_photo_url'] as String;
    
    if (photoPath.trim().isEmpty) {
      return null;
    }
    
    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }
    
    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final dateOnly = DateTime(day.year, day.month, day.day);
    return _attendanceByDate[dateOnly] ?? [];
  }

  List<Map<String, dynamic>> _getSelectedDayEvents() {
    final dateOnly = DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day);
    return _attendanceByDate[dateOnly] ?? [];
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!mounted) return;
    
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
  }

  Color _getEventColor(String type) {
    switch (type) {
      case 'check_in':
        return const Color(0xFF10B981);
      case 'check_out':
        return const Color(0xFFEF4444);
      default:
        return Colors.grey;
    }
  }

  IconData _getEventIcon(String type) {
    switch (type) {
      case 'check_in':
        return Icons.login;
      case 'check_out':
        return Icons.logout;
      default:
        return Icons.event;
    }
  }

  String _getEventLabel(String type) {
    switch (type) {
      case 'check_in':
        return 'Check In';
      case 'check_out':
        return 'Check Out';
      default:
        return type.replaceAll('_', ' ').toUpperCase();
    }
  }

  String _formatTime(String? dateTimeStr) {
    if (dateTimeStr == null) return '--:--';
    try {
      final dateTime = DateTime.parse(dateTimeStr);
      return DateFormat('HH:mm:ss').format(dateTime);
    } catch (e) {
      return '--:--';
    }
  }

  Future<void> _showEventDetails(Map<String, dynamic> event) async {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext context) {
        final eventTime = DateTime.parse(event['event_time']);
        
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.9,
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _getEventColor(event['type']).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _getEventIcon(event['type']),
                            color: _getEventColor(event['type']),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _getEventLabel(event['type']),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (event['photo_url'] != null) ...[
                      GestureDetector(
                        onTap: () => _showFullImage(context, event['photo_url']),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: CachedNetworkImage(
                            imageUrl: event['photo_url'],
                            width: double.infinity,
                            height: 220,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(
                              width: double.infinity,
                              height: 220,
                              color: Colors.grey[200],
                              child: const Center(child: CircularProgressIndicator()),
                            ),
                            errorWidget: (context, url, error) => Container(
                              width: double.infinity,
                              height: 220,
                              color: Colors.grey[200],
                              child: const Icon(Icons.error),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4A90E2).withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF4A90E2).withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildDetailRow(
                            Icons.calendar_today,
                            'Date',
                            DateFormat('EEEE, d MMM yyyy').format(eventTime),
                          ),
                          _buildDetailRow(
                            Icons.access_time,
                            'Time',
                            DateFormat('HH:mm:ss').format(eventTime),
                          ),
                          if (event['late_minutes'] != null && event['late_minutes'] > 0)
                            _buildDetailRow(
                              Icons.schedule,
                              'Late',
                              '${event['late_minutes']} minutes',
                            ),
                          if (event['work_duration_minutes'] != null)
                            _buildDetailRow(
                              Icons.work,
                              'Work Duration',
                              '${(event['work_duration_minutes'] / 60).toStringAsFixed(1)} hours',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showFullImage(BuildContext context, String photoUrl) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black87,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: CachedNetworkImage(
                  imageUrl: photoUrl,
                  fit: BoxFit.contain,
                  placeholder: (context, url) => const CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                  errorWidget: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(Icons.error, color: Colors.white, size: 50),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF4A90E2)),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, color: Colors.black87),
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: value),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _loadUserProfile(),
            _checkFaceRegistration(),
            _loadAttendanceStats(),
            _loadAttendanceData(),
          ]);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // ---------- HEADER CARD ----------
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA3F5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(30),
                    bottomRight: Radius.circular(30),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 50, 20, 30),
                child: Column(
                  children: [
                    // Top bar
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.calendar_today,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        Text(
                          _getCurrentDate(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.notifications,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Profile Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: _isLoadingProfile
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(20.0),
                                child: CircularProgressIndicator(),
                              ),
                            )
                          : Row(
                              children: [
                                // Profile Image
                                Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFF4A90E2),
                                      width: 2,
                                    ),
                                    color: Colors.grey.shade100,
                                  ),
                                  child: ClipOval(
                                    child: _getProfilePhotoUrl() != null
                                        ? Image.network(
                                            _getProfilePhotoUrl()!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) {
                                              return Icon(
                                                Icons.person,
                                                size: 30,
                                                color: Colors.grey.shade400,
                                              );
                                            },
                                            loadingBuilder: (context, child, loadingProgress) {
                                              if (loadingProgress == null) return child;
                                              return Center(
                                                child: CircularProgressIndicator(
                                                  value: loadingProgress.expectedTotalBytes != null
                                                      ? loadingProgress.cumulativeBytesLoaded /
                                                          loadingProgress.expectedTotalBytes!
                                                      : null,
                                                  strokeWidth: 2,
                                                ),
                                              );
                                            },
                                          )
                                        : Icon(
                                            Icons.person,
                                            size: 30,
                                            color: Colors.grey.shade400,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                // Profile Info
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _getFullName(),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.black87,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFD6EAFF),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _roleService.getRoleName(widget.memberData),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF4A90E2),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ---------- MAIN CONTENT ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Conditional: Show Register Face OR Tab View
                    if (_isCheckingFace)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20.0),
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      )
                    else if (!_hasRegisteredFace)
                      // Face Registration Card
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.face,
                                  color: Color(0xFF4A90E2),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'Face Recognition',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.orange.shade200,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    color: Colors.orange.shade700,
                                    size: 32,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Face Not Registered',
                                          style: TextStyle(
                                            color: Colors.orange.shade900,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Register your face to use attendance features',
                                          style: TextStyle(
                                            color: Colors.orange.shade800,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: _navigateToFaceRegistration,
                                icon: const Icon(Icons.face),
                                label: const Text(
                                  'Register Face',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF6C63FF),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      // Tab View: Statistics & Calendar + Daily Events
                      Column(
                        children: [
                          // Tab Bar
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.04),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: TabBar(
                              controller: _tabController,
                              labelColor: const Color(0xFF4A90E2),
                              unselectedLabelColor: Colors.grey,
                              indicatorColor: const Color(0xFF4A90E2),
                              indicatorWeight: 3,
                              labelStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              tabs: const [
                                Tab(text: 'Statistics'),
                                Tab(text: 'Calendar'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          
                          // Tab Content
                          SizedBox(
                            height: 600,
                            child: TabBarView(
                              controller: _tabController,
                              children: [
                                _buildStatisticsTab(),
                                _buildCalendarTab(),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
      // ---------- BOTTOM NAVIGATION ----------
      bottomNavigationBar: CustomBottomNav(
        currentIndex: 0,
        onTap: (index) {
          switch (index) {
            case 0:
              // Already on Home
              break;
            case 1:
              // Navigate to Profile
              _navigateToProfile();
              break;
          }
        },
      ),
    );
  }

  Widget _buildStatisticsTab() {
    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bar_chart_rounded,
                  color: Color(0xFF4A90E2),
                ),
                const SizedBox(width: 12),
                const Text(
                  'This Month Statistics',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            
            if (_isLoadingStats)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.event_available,
                      label: 'Present',
                      value: _attendanceStats?['present_days']?.toString() ?? '0',
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.access_time,
                      label: 'Late',
                      value: _attendanceStats?['late_days']?.toString() ?? '0',
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildStatCard(
                      icon: Icons.schedule,
                      label: 'Hours',
                      value: _attendanceStats?['work_hours'] ?? '0.0',
                      color: Colors.blue,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendarTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildCalendarSection(),
          const SizedBox(height: 16),
          _buildDailyEvents(),
        ],
      ),
    );
  }

  Widget _buildCalendarSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          TableCalendar<Map<String, dynamic>>(
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            eventLoader: _getEventsForDay,
            startingDayOfWeek: StartingDayOfWeek.monday,
            selectedDayPredicate: (day) {
              return isSameDay(_selectedDay, day);
            },
            onDaySelected: _onDaySelected,
            onFormatChanged: (format) {
              if (!mounted) return;
              if (_calendarFormat != format) {
                setState(() {
                  _calendarFormat = format;
                });
              }
            },
            onPageChanged: (focusedDay) {
              if (!mounted) return;
              setState(() {
                _focusedDay = focusedDay;
              });
            },
            calendarStyle: CalendarStyle(
              outsideDaysVisible: false,
              selectedDecoration: const BoxDecoration(
                color: Color(0xFF4A90E2),
                shape: BoxShape.circle,
              ),
              todayDecoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withOpacity(0.6),
                shape: BoxShape.circle,
              ),
              markersMaxCount: 3,
              markerDecoration: const BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
              ),
              markerSize: 6,
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: true,
              titleCentered: true,
              formatButtonDecoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                borderRadius: BorderRadius.circular(8),
              ),
              formatButtonTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 12,
              ),
              titleTextStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDailyEvents() {
    final events = _getSelectedDayEvents();
    
    if (events.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.event_busy, color: Colors.grey.shade300, size: 48),
              const SizedBox(height: 12),
              Text(
                'No Attendance Data',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('dd MMM yyyy').format(_selectedDay),
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6C63FF).withOpacity(0.08),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withOpacity(0.05),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.event_note,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Daily Events',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      Text(
                        DateFormat('EEE, dd MMM yyyy').format(_selectedDay),
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${events.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: events.length,
              separatorBuilder: (context, index) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                return _buildEventListItem(events[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventListItem(Map<String, dynamic> event) {
    final eventTime = DateTime.parse(event['event_time']);
    final eventColor = _getEventColor(event['type']);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: eventColor.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showEventDetails(event),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        eventColor.withOpacity(0.8),
                        eventColor,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: eventColor.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _buildEventLeadingWidget(event, Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _getEventLabel(event['type']),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.access_time, size: 12, color: Colors.grey.shade600),
                          const SizedBox(width: 4),
                          Text(
                            _formatTime(event['event_time']),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _buildEventStatusRow(event),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: Colors.grey.shade400,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEventLeadingWidget(Map<String, dynamic> event, Color iconColor) {
    if (event['photo_url'] != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: CachedNetworkImage(
          imageUrl: event['photo_url'],
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          placeholder: (context, url) => Icon(
            _getEventIcon(event['type']),
            color: iconColor,
            size: 22,
          ),
          errorWidget: (context, url, error) => Icon(
            _getEventIcon(event['type']),
            color: iconColor,
            size: 22,
          ),
        ),
      );
    }

    return Icon(
      _getEventIcon(event['type']),
      color: iconColor,
      size: 22,
    );
  }

  Widget _buildEventStatusRow(Map<String, dynamic> event) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        if (event['status'] != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _getStatusColor(event['status']).withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _getStatusColor(event['status']).withOpacity(0.5),
                width: 1,
              ),
            ),
            child: Text(
              event['status'].toString().toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                color: _getStatusColor(event['status']),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (event['late_minutes'] != null && event['late_minutes'] > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.withOpacity(0.5), width: 1),
            ),
            child: Text(
              '+${event['late_minutes']}m',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.orange,
              ),
            ),
          ),
      ],
    );
  }

  Color _getStatusColor(String? status) {
    if (status == null) return Colors.grey;
    switch (status.toLowerCase()) {
      case 'present':
        return const Color(0xFF10B981);
      case 'absent':
        return const Color(0xFFEF4444);
      case 'late':
        return const Color(0xFFF59E0B);
      default:
        return Colors.grey;
    }
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color.withOpacity(0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}