import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/timezone_helper.dart';
import '../../helpers/rfid_mode_helper.dart';
import '../../services/attendance_service.dart';
import '../../auth/services/role_service.dart';
import '../widgets/petugas_bottom_nav.dart';
import '../../pages/face_attendance_multi_user_page.dart';
import 'petugas_members_page.dart';
import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';
import '../../pages/rfid_attendance_page.dart';
import '../../pages/manual_check_page.dart';

class PetugasDashboardPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const PetugasDashboardPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<PetugasDashboardPage> createState() => _PetugasDashboardPageState();
}

class _PetugasDashboardPageState extends State<PetugasDashboardPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();

  bool _isLoadingStats = true;
  bool _isLoadingActivities = true;
  String? _errorMessage;
  int _currentNavIndex = 0;
  String _attendanceMode = 'face';
  String _organizationTimezone = 'Asia/Jakarta';
  Map<String, dynamic>? _organization;
  Map<String, dynamic>? _userProfile;
  bool _isDarkMode = false;

  int _checkedInCount = 0;
  int _checkedOutCount = 0;
  int _pendingCount = 0;
  int _lateCount = 0;

  List<Map<String, dynamic>> _recentActivities = [];

  // Weekly overview data
  bool _isLoadingWeeklyData = true;
  double _totalWeeklyHours = 0.0;
  double _weeklyPercentageChange = 0.0;
  List<double> _dailyHours = [0.0, 0.0, 0.0, 0.0, 0.0]; // Mon-Fri

  @override
  void initState() {
    super.initState();
    debugPrint('=== PETUGAS DASHBOARD INIT (KIOSK MODE) ===');
    debugPrint('Organization Member ID: ${widget.organizationMemberId}');
    debugPrint('Role: ${_roleService.getRoleName(widget.memberData)}');
    _userProfile = widget.userProfile;
    _isDarkMode = widget.isDarkMode;
    _loadUserProfile();
    _loadOrganizationTimezone();
    _loadOrganizationInfo();
    _loadAttendanceMode();
    _refreshAll();
    _loadWeeklyOverview();
  }

  Future<void> _loadUserProfile() async {
    if (_userProfile != null) return;

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        debugPrint('No user logged in');
        return;
      }

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .maybeSingle();

      if (mounted && response != null) {
        setState(() {
          _userProfile = response;
        });
        debugPrint('User profile loaded: ${_userProfile?['display_name']}');
      }
    } catch (e) {
      debugPrint('Error loading user profile: $e');
    }
  }

  Future<void> _loadAttendanceMode() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final mode = await RfidModeHelper.getAttendanceMode(organizationId);
      if (mounted) {
        setState(() {
          _attendanceMode = mode;
        });
        debugPrint(
          'Attendance mode loaded: $_attendanceMode for org $organizationId',
        );
      }
    } catch (e) {
      debugPrint('Error loading attendance mode: $e');
    }
  }

  Future<void> _saveAttendanceMode(String mode) async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      await RfidModeHelper.saveAttendanceMode(organizationId, mode);
      debugPrint('Attendance mode saved: $mode for org $organizationId');
    } catch (e) {
      debugPrint('Error saving attendance mode: $e');
    }
  }

  Future<void> _loadOrganizationInfo() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('id, name, logo_url')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null) {
        setState(() {
          _organization = org;
        });
      }
    } catch (e) {
      debugPrint('Error loading organization info: $e');
    }
  }

  Future<void> _loadOrganizationTimezone() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null && org['timezone'] != null) {
        setState(() {
          _organizationTimezone = org['timezone'] as String;
        });
        debugPrint('Organization timezone: $_organizationTimezone');
      }
    } catch (e) {
      debugPrint('Error loading organization timezone: $e');
    }
  }

  Future<void> _loadTodayStats() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) {
      setState(() {
        _isLoadingStats = false;
        _errorMessage = 'Organization data not found';
      });
      return;
    }

    setState(() {
      _isLoadingStats = true;
      _errorMessage = null;
    });

    try {
      debugPrint(
        'Loading today statistics for organization $organizationId...',
      );

      final stats = await _attendanceService.getOrganizationTodayStats(
        organizationId,
        organizationTimezone: _organizationTimezone,
      );

      if (mounted) {
        setState(() {
          _checkedInCount = stats['checked_in'] ?? 0;
          _checkedOutCount = stats['checked_out'] ?? 0;
          _pendingCount = stats['pending'] ?? 0;
          _lateCount = stats['late'] ?? 0;
          _isLoadingStats = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading stats: $e');
      if (mounted) {
        setState(() {
          _isLoadingStats = false;
          // Check if it's a network/connection error
          final errorString = e.toString().toLowerCase();
          if (errorString.contains('socketexception') ||
              errorString.contains('failed host lookup') ||
              errorString.contains('no address associated with hostname') ||
              errorString.contains('network is unreachable') ||
              errorString.contains('connection refused') ||
              errorString.contains('connection timed out')) {
            _errorMessage = 'Tidak ada koneksi internet';
          } else {
            _errorMessage = 'Failed to load statistics: $e';
          }
        });
      }
    }
  }

  Future<void> _refreshAll() async {
    debugPrint('=== REFRESHING ALL DATA ===');
    await Future.wait([_loadTodayStats(), _loadRecentActivities()]);
  }

  Future<void> _loadRecentActivities() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) {
      setState(() {
        _isLoadingActivities = false;
        _errorMessage = 'Organization data not found';
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isLoadingActivities = true);

    try {
      final activities = await _attendanceService.getOrganizationRecentActivities(
        organizationId: organizationId,
        limit: 10,
      );

      if (!mounted) return;

      final groupedActivities = <String, Map<String, dynamic>>{};

      for (final activity in activities) {
        final member = activity['organization_members'] as Map<String, dynamic>? ?? {};
        final profile = member['user_profiles'] as Map<String, dynamic>? ?? {};
        final department = member['departments'] as Map<String, dynamic>? ?? {};
        final record = activity['attendance_records'] as Map<String, dynamic>? ?? {};

        final memberId = member['id']?.toString() ?? activity['organization_member_id']?.toString() ?? '';
        DateTime? eventTime;
        final eventTimeStr = activity['event_time'] as String?;
        if (eventTimeStr != null) {
          eventTime = TimezoneHelper.parseAndConvert(
            eventTimeStr,
            _organizationTimezone,
          );
        }

        final attendanceDate = (record['attendance_date'] as String?) ??
            (eventTimeStr != null ? eventTimeStr.split('T').first : '');
        final key = '$memberId-$attendanceDate';

        final entry = groupedActivities.putIfAbsent(key, () {
          return {
            'name': _composeUserName(profile),
            'photoUrl': _resolveProfilePhotoUrl(profile['profile_photo_url'] as String?),
            'department': department['name'] as String? ?? 'No Department',
            'status': record['status'] as String?,
            'checkInTime': null,
            'checkOutTime': null,
            'checkInMethod': null,
            'checkOutMethod': null,
            'lastAction': null,
            'method': null,
            'lastUpdated': null,
          };
        });

        if (activity['event_type'] == 'check_in') {
          // If multiple check-ins, usually we want the EARLIEST for the "Check In" slot,
          // but since the loop is NEWEST to OLDEST (DESC), we overwrite to let the 
          // last iteration (oldest) win for earliest check-in time.
          entry['checkInTime'] = eventTime;
          entry['checkInMethod'] = activity['method'];
        } else if (activity['event_type'] == 'check_out') {
          // For Check Out, we want the LATEST. Since loop is NEWEST to OLDEST,
          // the first check_out we encounter is the latest one.
          entry['checkOutTime'] ??= eventTime;
          entry['checkOutMethod'] ??= activity['method'];
        }

        // These should reflect the LATEST action overall
        entry['lastAction'] ??= activity['event_type'];
        entry['method'] ??= activity['method'];
        entry['lastUpdated'] ??= eventTime;
      }

      final mappedActivities = groupedActivities.values.toList()
        ..sort((a, b) {
          final aTime = a['lastUpdated'] as DateTime? ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bTime = b['lastUpdated'] as DateTime? ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bTime.compareTo(aTime);
        });

      final limitedActivities = mappedActivities.take(6).toList();

      setState(() {
        _recentActivities = limitedActivities;
        _isLoadingActivities = false;
      });
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (!mounted) return;
      
      // Check if it's a network/connection error
      final errorString = e.toString().toLowerCase();
      final isNetworkError = errorString.contains('socketexception') ||
          errorString.contains('failed host lookup') ||
          errorString.contains('no address associated with hostname') ||
          errorString.contains('network is unreachable') ||
          errorString.contains('connection refused') ||
          errorString.contains('connection timed out');
      
      setState(() {
        _isLoadingActivities = false;
        if (isNetworkError) {
          _errorMessage ??= 'Tidak ada koneksi internet';
        } else {
          _errorMessage ??= 'Failed to load recent activities: $e';
        }
      });
      setState(() {
        _isLoadingActivities = false;
        _recentActivities = [];
        _errorMessage ??= 'Failed to load recent activities: $e';
      });
    }
  }

  Future<void> _loadWeeklyOverview() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) {
      setState(() {
        _isLoadingWeeklyData = false;
      });
      return;
    }

    setState(() {
      _isLoadingWeeklyData = true;
    });

    try {
      // Get current week (Monday to Friday)
      final now = DateTime.now();
      final currentWeekday = now.weekday; // 1 = Monday, 7 = Sunday
      
      // Calculate Monday of current week
      final monday = now.subtract(Duration(days: currentWeekday - 1));
      final mondayStr = monday.toIso8601String().split('T')[0];
      
      // Calculate Friday of current week
      final friday = monday.add(const Duration(days: 4));
      final fridayStr = friday.toIso8601String().split('T')[0];

      // Get last week's Monday and Friday for comparison
      final lastMonday = monday.subtract(const Duration(days: 7));
      final lastMondayStr = lastMonday.toIso8601String().split('T')[0];
      final lastFriday = lastMonday.add(const Duration(days: 4));
      final lastFridayStr = lastFriday.toIso8601String().split('T')[0];

      debugPrint('Loading weekly overview: $mondayStr to $fridayStr');

      // Fetch current week's attendance records
      final currentWeekRecords = await _supabase
          .from('attendance_records')
          .select('''
            attendance_date,
            work_duration_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', mondayStr)
          .lte('attendance_date', fridayStr);

      // Fetch last week's attendance records
      final lastWeekRecords = await _supabase
          .from('attendance_records')
          .select('''
            work_duration_minutes,
            organization_members!inner(organization_id)
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', lastMondayStr)
          .lte('attendance_date', lastFridayStr);

      // Calculate daily hours for current week
      final dailyHoursMap = <int, double>{
        1: 0.0, // Monday
        2: 0.0, // Tuesday
        3: 0.0, // Wednesday
        4: 0.0, // Thursday
        5: 0.0, // Friday
      };

      double totalMinutes = 0.0;
      for (final record in currentWeekRecords as List) {
        final dateStr = record['attendance_date'] as String?;
        final minutes = record['work_duration_minutes'] as int?;
        
        if (dateStr != null && minutes != null && minutes > 0) {
          final date = DateTime.parse(dateStr);
          final weekday = date.weekday;
          
          if (weekday >= 1 && weekday <= 5) {
            dailyHoursMap[weekday] = (dailyHoursMap[weekday] ?? 0.0) + (minutes / 60.0);
            totalMinutes += minutes;
          }
        }
      }

      // Calculate last week's total
      double lastWeekMinutes = 0.0;
      for (final record in lastWeekRecords as List) {
        final minutes = record['work_duration_minutes'] as int?;
        if (minutes != null && minutes > 0) {
          lastWeekMinutes += minutes;
        }
      }

      // Calculate percentage change
      double percentageChange = 0.0;
      if (lastWeekMinutes > 0) {
        percentageChange = ((totalMinutes - lastWeekMinutes) / lastWeekMinutes) * 100;
      } else if (totalMinutes > 0) {
        percentageChange = 100.0; // If no data last week but have data this week
      }

      if (mounted) {
        setState(() {
          _totalWeeklyHours = totalMinutes / 60.0;
          _weeklyPercentageChange = percentageChange;
          _dailyHours = [
            dailyHoursMap[1]!,
            dailyHoursMap[2]!,
            dailyHoursMap[3]!,
            dailyHoursMap[4]!,
            dailyHoursMap[5]!,
          ];
          _isLoadingWeeklyData = false;
        });
      }

      debugPrint('Weekly overview loaded: ${_totalWeeklyHours.toStringAsFixed(1)} hrs, ${_weeklyPercentageChange.toStringAsFixed(1)}% change');
    } catch (e) {
      debugPrint('!!! ERROR loading weekly overview: $e');
      if (mounted) {
        setState(() {
          _isLoadingWeeklyData = false;
        });
      }
    }
  }

  Future<void> _navigateToMultiUserFaceAttendance(String? type) async {
    try {
      final organizationId = widget.memberData['organization_id'];

      if (organizationId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Organization ID not found')),
        );
        return;
      }

      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FaceAttendanceMultiUserPage(
            organizationId: organizationId,
            attendanceType: type,
          ),
        ),
      );

      if (result == true) {
        _refreshAll();
      }
    } catch (e) {
      debugPrint('Error navigating to multi-user face attendance: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _handleCameraButtonPress() async {
    // Reload attendance mode from SharedPreferences to ensure latest value
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId != null) {
      _attendanceMode = await RfidModeHelper.getAttendanceMode(organizationId);
    }
    
    if (_attendanceMode == 'rfid') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => RfidAttendancePage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
          ),
        ),
      ).then((_) {
        _refreshAll();
      });
      return;
    } else if (_attendanceMode == 'fingerprint') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fingerprint attendance is coming soon!'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    _navigateToMultiUserFaceAttendance(null);
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        break;
      case 1:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: _isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF8F9FA),
              child: PetugasMembersPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: _isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
          _refreshAll();
        });
        break;
      case 2:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: _isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF8F9FA),
              child: PetugasRecordsPage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: _isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
          _refreshAll();
        });
        break;
      case 3:
        Navigator.push<bool>(
          context,
          PageRouteBuilder(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, __) => Container(
              color: _isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF8F9FA),
              child: PetugasProfilePage(
                organizationMemberId: widget.organizationMemberId,
                memberData: widget.memberData,
                userProfile: _userProfile ?? widget.userProfile,
                isDarkMode: _isDarkMode,
              ),
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
          // Always reload attendance mode from SharedPreferences to ensure sync
          _loadAttendanceMode();
          _loadUserProfile();
        });
        break;
    }
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    final weekday = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][now.weekday - 1];
    final month = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ][now.month - 1];
    return '$weekday, ${now.day} $month ${now.year}';
  }

  String _getFullName() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null) {
      return '';
    }

    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final firstName = profile['first_name'] as String? ?? '';
    final middleName = profile['middle_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';

    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }

    return '$firstName $lastName'.trim();
  }

  String _getEmail() {
    return _supabase.auth.currentUser?.email ?? 'No email';
  }

  String? _getProfilePhotoUrl() {
    final profile = _userProfile ?? widget.userProfile;
    if (profile == null || profile['profile_photo_url'] == null) {
      return null;
    }

    final photoPath = profile['profile_photo_url'] as String;

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

  String _composeUserName(Map<String, dynamic>? profile) {
    if (profile == null) return 'Unknown User';
    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();
    return fullName.isEmpty ? 'Unknown User' : fullName;
  }

  String? _resolveProfilePhotoUrl(String? storedPath) {
    if (storedPath == null || storedPath.trim().isEmpty) return null;
    if (storedPath.startsWith('http://') || storedPath.startsWith('https://')) {
      return storedPath;
    }

    final normalizedPath = storedPath.startsWith('mass-profile/')
        ? storedPath
        : 'mass-profile/$storedPath';

    try {
      return _supabase.storage
          .from('profile-photos')
          .getPublicUrl(normalizedPath);
    } catch (_) {
      return null;
    }
  }

  String _formatEventType(String? type) {
    switch (type) {
      case 'check_in':
        return 'Check In';
      case 'check_out':
        return 'Check Out';
      default:
        if (type == null) return 'Activity';
        return type.replaceAll('_', ' ').toUpperCase();
    }
  }

  String _formatEventTime(DateTime? time) {
    if (time == null) return 'Unknown time';

    final nowUtc = DateTime.now().toUtc();
    final nowOrg =
        TimezoneHelper.parseAndConvert(
          nowUtc.toIso8601String(),
          _organizationTimezone,
        ) ??
        nowUtc;

    final isToday =
        nowOrg.year == time.year &&
        nowOrg.month == time.month &&
        nowOrg.day == time.day;

    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute';

    if (isToday) {
      return 'Today • $timeStr';
    }

    final dateStr = '${time.day}/${time.month}/${time.year}';
    return '$dateStr • $timeStr';
  }

  String _formatShortTime(DateTime? time) {
    if (time == null) return '--';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final currentTime = '$hour:$minute';
    
    return Scaffold(
      backgroundColor: _isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // HEADER WITH PROFILE
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _isDarkMode
                        ? [const Color(0xFF2D1B4E), const Color(0xFF1F0B38)]
                        : [const Color(0xFF8938DF), const Color(0xFF4A1E79)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Column(
                  children: [
                    // Logo and Theme Toggle Row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Transform.translate(
                            offset: const Offset(-16, -16), // Shift left and up
                            child: Image.asset(
                              'assets/logo/app_logo.png',
                              width: 180,
                              height: 180,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              isAntiAlias: true,
                              errorBuilder: (context, error, stackTrace) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                          Transform.translate(
                            offset: const Offset(0, -16), // Shift up to align with logo
                            child: IconButton(
                              icon: Icon(
                                _isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_outlined,
                                color: Colors.white,
                                size: 26,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isDarkMode = !_isDarkMode;
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    // PROFILE SECTION (Photo, Name, Role, Date) - Combined
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Column(
                        children: [
                          // Profile Photo
                          Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                colors: _isDarkMode
                                    ? [const Color(0xFFD0BCFF), const Color(0xFF8938DF)]
                                    : [const Color(0xFF8938DF), const Color(0xFF4A1E79)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 20,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: ClipOval(
                              child: _getProfilePhotoUrl() != null
                                  ? Image.network(
                                      _getProfilePhotoUrl()!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) {
                                        return const Icon(
                                          Icons.person,
                                          size: 60,
                                          color: Colors.white,
                                        );
                                      },
                                    )
                                  : const Icon(
                                      Icons.person,
                                      size: 60,
                                      color: Colors.white,
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // Name
                          Text(
                            _getFullName().isNotEmpty ? _getFullName() : 'User',
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Role and Organization
                          Text(
                            '${_roleService.getRoleName(widget.memberData)}${_organization != null ? ' - ${_organization!['name']}' : ''}',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          // Date
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.calendar_today,
                                  color: Colors.white,
                                  size: 14,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _getCurrentDate(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
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

              // WHITE CONTENT AREA
              Container(
                decoration: BoxDecoration(
                  color: _isDarkMode ? const Color(0xFF1F0B38) : const Color(0xFFF5F5F5),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(32),
                    topRight: Radius.circular(32),
                  ),
                ),
                child: Column(
                  children: [
                    // COMBINED TIME & CHECK-IN CARD (OVERLAPPING)
                    Transform.translate(
                      offset: const Offset(0, -80),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              // Time and Location Row
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Current Time',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _isDarkMode ? Colors.white70 : Colors.grey.shade600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$currentTime ${now.hour < 12 ? 'AM' : 'PM'}',
                                          style: TextStyle(
                                            fontSize: 28,
                                            fontWeight: FontWeight.bold,
                                            color: _isDarkMode ? Colors.white : const Color(0xFF4A1E79),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    width: 1,
                                    height: 45,
                                    margin: const EdgeInsets.only(top: 10),
                                    color: _isDarkMode ? Colors.white24 : Colors.grey.shade200,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Office Location',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: _isDarkMode ? Colors.white70 : Colors.grey.shade600,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.location_on,
                                              color: _isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79),
                                              size: 16,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                _organization?['name'] ?? 'Office',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: _isDarkMode ? const Color(0xFFD0BCFF) : Colors.black87,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              // Check In Button
                              SizedBox(
                                width: double.infinity,
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF8938DF), Color(0xFF4A1E79)],
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF4A1E79).withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: _handleCameraButtonPress,
                                      borderRadius: BorderRadius.circular(12),
                                      child: const Padding(
                                        padding: EdgeInsets.symmetric(vertical: 16),
                                        child: Text(
                                          'Chek In With Another Way',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                    Transform.translate(
                      offset: const Offset(0, -20),
                      child: const SizedBox(height: 0),
                    ),

                    // WEEKLY OVERVIEW
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Weekly Overview',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _isDarkMode ? Colors.white : Colors.black87,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: (_isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79)).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'THIS WEEK',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: _isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _isLoadingWeeklyData
                                          ? '--'
                                          : _totalWeeklyHours.toStringAsFixed(1),
                                      style: TextStyle(
                                        fontSize: 36,
                                        fontWeight: FontWeight.bold,
                                        color: _isDarkMode ? Colors.white : Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Padding(
                                      padding: EdgeInsets.only(bottom: 8),
                                      child: Text(
                                        'hrs',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: _isDarkMode
                                              ? Colors.white54
                                              : Colors.grey.shade600,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6), // Slightly adjusted for optinal optical alignment
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 12,
                                            height: 12,
                                            decoration: BoxDecoration(
                                              color: _isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'HOURS',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: _isDarkMode
                                                  ? Colors.white54
                                                  : Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                if (!_isLoadingWeeklyData)
                                  Row(
                                    children: [
                                      Icon(
                                        _weeklyPercentageChange >= 0
                                            ? Icons.trending_up
                                            : Icons.trending_down,
                                        color: _weeklyPercentageChange >= 0
                                            ? (_isDarkMode ? Colors.greenAccent : Colors.green.shade600)
                                            : (_isDarkMode ? Colors.redAccent : Colors.red.shade600),
                                        size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${_weeklyPercentageChange >= 0 ? '+' : ''}${_weeklyPercentageChange.toStringAsFixed(1)}% from last week',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: _weeklyPercentageChange >= 0
                                              ? (_isDarkMode ? Colors.greenAccent : Colors.green.shade600)
                                              : (_isDarkMode ? Colors.redAccent : Colors.red.shade600),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: 24),
                                // Bar Chart
                                if (!_isLoadingWeeklyData)
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      _buildBarChart('MON', _dailyHours[0]),
                                      _buildBarChart('TUE', _dailyHours[1]),
                                      _buildBarChart('WED', _dailyHours[2]),
                                      _buildBarChart('THU', _dailyHours[3]),
                                      _buildBarChart('FRI', _dailyHours[4]),
                                    ],
                                  )
                                else
                                  const Center(
                                    child: Padding(
                                      padding: EdgeInsets.all(20),
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ),

                    // RECENT ACTIVITY
                    Transform.translate(
                      offset: const Offset(0, -70),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Recent Activity',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: _isDarkMode ? Colors.white : Colors.black87,
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  _handleNavigation(2);
                                },
                                child: Text(
                                  'View All',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: _isDarkMode
                                        ? const Color(0xFFD0BCFF)
                                        : const Color(0xFF4A1E79),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_isLoadingActivities)
                            Container(
                              padding: const EdgeInsets.all(32),
                              decoration: BoxDecoration(
                                color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          _isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79)),
                                    ),
                                ),
                              ),
                            )
                          else if (_recentActivities.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(32),
                              decoration: BoxDecoration(
                                color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Center(
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.history,
                                      size: 48,
                                      color: _isDarkMode ? Colors.white24 : Colors.grey.shade300,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'No recent activity',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: _isDarkMode ? Colors.white54 : Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Column(
                              children: _recentActivities
                                  .take(3)
                                  .map((activity) =>
                                      _buildModernActivityItem(activity))
                                  .toList(),
                            ),
                        ],
                      ),
                    ),
                    ),

                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        onAttendanceTap: _handleCameraButtonPress,
        isDarkMode: _isDarkMode,
        attendanceMode: _attendanceMode,
      ),
    );
  }

  Widget _buildBarChart(String day, double hours) {
    // Find max hours for normalization
    final maxHours = _dailyHours.reduce((a, b) => a > b ? a : b);
    
    // Calculate height (normalize to 0-1 range, with minimum 20% for visibility)
    double normalizedHeight = 0.2; // Minimum height for empty days
    if (maxHours > 0 && hours > 0) {
      normalizedHeight = (hours / maxHours).clamp(0.2, 1.0);
    }
    
    // Check if this is the current day
    final now = DateTime.now();
    final dayIndex = ['MON', 'TUE', 'WED', 'THU', 'FRI'].indexOf(day);
    final isCurrentDay = now.weekday == dayIndex + 1;
    
    return Column(
      children: [
        Container(
          width: 40,
          height: 100 * normalizedHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isCurrentDay
                  ? (_isDarkMode 
                      ? [const Color(0xFFD0BCFF), const Color(0xFF8938DF)]
                      : [const Color(0xFF8938DF), const Color(0xFF4A1E79)])
                  : [
                      (_isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79)).withValues(alpha: _isDarkMode ? 0.25 : 0.15),
                      (_isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79)).withValues(alpha: _isDarkMode ? 0.25 : 0.15),
                    ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          day,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isCurrentDay ? FontWeight.bold : FontWeight.w500,
            color: isCurrentDay
                ? (_isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79))
                : (_isDarkMode ? Colors.white54 : Colors.grey.shade600),
          ),
        ),
      ],
    );
  }

  Widget _buildModernActivityItem(Map<String, dynamic> activity) {
    final name = activity['name'] as String? ?? 'Unknown User';
    final checkInTime = activity['checkInTime'] as DateTime?;
    final checkOutTime = activity['checkOutTime'] as DateTime?;
    final lastUpdated = activity['lastUpdated'] as DateTime?;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _isDarkMode ? const Color(0xFF2D1B4E) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _isDarkMode ? Colors.black26 : Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          if (checkInTime != null)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isDarkMode
                        ? Colors.white
                        : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.login,
                    color: _isDarkMode ? Colors.green : Colors.green.shade600,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check In',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastUpdated != null
                            ? _formatEventTime(lastUpdated)
                            : 'Unknown time',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isDarkMode ? Colors.white54 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatShortTime(checkInTime),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isDarkMode ? Colors.white : Colors.black87,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'ON TIME',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          if (checkInTime != null && checkOutTime != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Divider(
                height: 1,
                color: _isDarkMode ? Colors.white24 : Colors.grey.shade200,
              ),
            ),
          if (checkOutTime != null)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _isDarkMode
                        ? Colors.white
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.logout,
                    color: _isDarkMode ? Colors.red : Colors.red.shade600,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check Out',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _isDarkMode ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lastUpdated != null
                            ? _formatEventTime(lastUpdated)
                            : 'Unknown time',
                        style: TextStyle(
                          fontSize: 12,
                          color: _isDarkMode ? Colors.white54 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatShortTime(checkOutTime),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _isDarkMode ? Colors.white : Colors.black87,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'REGULAR',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildActivityItem(Map<String, dynamic> activity) {
    final name = activity['name'] as String? ?? 'Unknown User';
    final photoUrl = activity['photoUrl'] as String?;
    final lastUpdated = activity['lastUpdated'] as DateTime?;
    final checkInTime = activity['checkInTime'] as DateTime?;
    final checkOutTime = activity['checkOutTime'] as DateTime?;
    final checkInMethod = activity['checkInMethod'] as String?;
    final checkOutMethod = activity['checkOutMethod'] as String?;

    // Get department info from the activity data
    final department = activity['department'] as String? ?? 'No Department';

    final ImageProvider avatarImage = (photoUrl != null && photoUrl.isNotEmpty)
        ? NetworkImage(photoUrl)
        : const AssetImage('images/logo.png');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Profile Photo - smaller
              Container(
                width: 45,
                height: 45,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF4A1E79), width: 2),
                  color: Colors.grey.shade100,
                ),
                child: ClipOval(
                  child: photoUrl != null && photoUrl.isNotEmpty
                      ? Image.network(
                          photoUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return const Icon(Icons.person, size: 22, color: Colors.grey);
                          },
                        )
                      : const Icon(Icons.person, size: 22, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 12),
              // User Info with Department
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      department,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatEventTime(lastUpdated),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Status Information without icons
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check In',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatShortTime(checkInTime),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Check Out',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatShortTime(checkOutTime),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChipWithMethod(
    String label,
    String time,
    String? method,
    Color textColor,
    Color backgroundColor,
  ) {
    IconData? methodIcon;
    if (method == 'manual') {
      methodIcon = Icons.edit;
    } else if (method == 'rfid') {
      methodIcon = Icons.nfc;
    } else if (method == 'face_recognition') {
      methodIcon = Icons.face;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (methodIcon != null) ...[
                Icon(
                  methodIcon,
                  size: 10,
                  color: textColor,
                ),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            time,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

// SUPPORTING WIDGETS - Diperkecil

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Icon(icon, color: iconColor, size: 26),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final IconData? icon;
  final Color? iconColor;

  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
    this.icon,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          if (icon != null)
            Icon(icon, color: iconColor ?? Colors.black54, size: 20),
          if (icon != null) const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}