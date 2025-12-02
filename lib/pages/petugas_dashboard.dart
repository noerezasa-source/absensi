import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../helpers/timezone_helper.dart';
import '../helpers/rfid_mode_helper.dart';
import '../services/attendance_service.dart';
import '../services/role_service.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'face_attendance_multi_user_page.dart';
import 'petugas_profile_page.dart';
import 'petugas_records_page.dart';
import 'rfid_attendance_page.dart';
import 'manual_check_page.dart';

class PetugasDashboardPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasDashboardPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
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
  bool _useRfidForAttendance = false;
  String _organizationTimezone = 'Asia/Jakarta';
  Map<String, dynamic>? _organization;
  Map<String, dynamic>? _userProfile;

  int _checkedInCount = 0;
  int _checkedOutCount = 0;
  int _pendingCount = 0;
  int _lateCount = 0;

  List<Map<String, dynamic>> _recentActivities = [];

  @override
  void initState() {
    super.initState();
    debugPrint('=== PETUGAS DASHBOARD INIT (KIOSK MODE) ===');
    debugPrint('Organization Member ID: ${widget.organizationMemberId}');
    debugPrint('Role: ${_roleService.getRoleName(widget.memberData)}');
    _userProfile = widget.userProfile;
    _loadUserProfile();
    _loadOrganizationTimezone();
    _loadOrganizationInfo();
    _loadRfidMode();
    _refreshAll();
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

  Future<void> _loadRfidMode() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final savedMode = await RfidModeHelper.getRfidMode(organizationId);
      if (mounted) {
        setState(() {
          _useRfidForAttendance = savedMode;
        });
        debugPrint(
          'RFID mode loaded: $_useRfidForAttendance for org $organizationId',
        );
      }
    } catch (e) {
      debugPrint('Error loading RFID mode: $e');
    }
  }

  Future<void> _saveRfidMode(bool enabled) async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      await RfidModeHelper.saveRfidMode(organizationId, enabled);
      debugPrint('RFID mode saved: $enabled for org $organizationId');
    } catch (e) {
      debugPrint('Error saving RFID mode: $e');
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
          _errorMessage = 'Failed to load statistics: $e';
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

    setState(() {
      _isLoadingActivities = true;
    });

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
          entry['checkInTime'] = eventTime;
          entry['checkInMethod'] = activity['method'];
        } else if (activity['event_type'] == 'check_out') {
          entry['checkOutTime'] = eventTime;
          entry['checkOutMethod'] = activity['method'];
        }

        entry['lastAction'] = activity['event_type'];
        entry['method'] = activity['method'];
        entry['lastUpdated'] = eventTime;
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
      setState(() {
        _isLoadingActivities = false;
        _recentActivities = [];
        _errorMessage ??= 'Failed to load recent activities: $e';
      });
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

  void _handleCameraButtonPress() {
    if (_useRfidForAttendance) {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Member feature coming soon')),
        );
        break;
      case 2:
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasRecordsPage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: _userProfile ?? widget.userProfile,
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
          MaterialPageRoute(
            builder: (context) => PetugasProfilePage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: _userProfile ?? widget.userProfile,
            ),
          ),
        ).then((rfidMode) {
          setState(() {
            _currentNavIndex = 0;
            if (rfidMode != null) {
              _useRfidForAttendance = rfidMode;
              _saveRfidMode(rfidMode);
            }
          });
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
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // HEADER CARD - Diperkecil
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(24),
                    bottomRight: Radius.circular(24),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 44, 16, 20),
                child: Column(
                  children: [
                    // Top bar - Diperkecil
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.calendar_today,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 6),
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
                    const SizedBox(height: 14),
                    // Profile Card - Diperkecil
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Profile Image - Diperkecil
                          Stack(
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF9333EA),
                                    width: 2.5,
                                  ),
                                  color: Colors.grey.shade100,
                                ),
                                child: ClipOval(
                                  child: _getProfilePhotoUrl() != null
                                      ? Image.network(
                                          _getProfilePhotoUrl()!,
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) {
                                            return const Icon(
                                              Icons.person,
                                              size: 28,
                                              color: Colors.grey,
                                            );
                                          },
                                        )
                                      : const Icon(
                                          Icons.person,
                                          size: 28,
                                          color: Colors.grey,
                                        ),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF9333EA),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.badge,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 12),
                          // Profile Info - Diperkecil
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getFullName().isNotEmpty
                                      ? _getFullName()
                                      : 'User',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                // Petugas Badge - Diperkecil
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3E8FF),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.badge,
                                        size: 11,
                                        color: Color(0xFF9333EA),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _roleService.getRoleName(
                                          widget.memberData,
                                        ),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF9333EA),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_organization != null) ...[
                                  const SizedBox(height: 6),
                                  // Organization - Diperkecil
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.business,
                                        size: 11,
                                        color: Colors.grey.shade600,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          _organization!['name'] ??
                                              'Unknown Organization',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.shade100),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.redAccent,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.close,
                            size: 14,
                            color: Colors.redAccent,
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            setState(() {
                              _errorMessage = null;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // QUICK ACTIONS - Diperkecil
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Quick Actions",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(width: 8),
                        _QuickActionCard(
                          icon: Icons.people,
                          label: 'Manual Check',
                          color: Colors.blue.shade50,
                          iconColor: Colors.blue,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ManualCheckPage(
                                  organizationMemberId:
                                      widget.organizationMemberId,
                                  memberData: widget.memberData,
                                ),
                              ),
                            ).then((_) {
                              _refreshAll();
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // TODAY'S SUMMARY - Diperkecil
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Today's Summary",
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            value: _isLoadingStats ? '-' : '$_checkedInCount',
                            label: 'Checked In',
                            color: Colors.green.shade50,
                            icon: Icons.login,
                            iconColor: Colors.green,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _StatCard(
                            value: _isLoadingStats ? '-' : '$_lateCount',
                            label: 'Late',
                            color: Colors.yellow.shade50,
                            icon: Icons.warning,
                            iconColor: Colors.orange,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _StatCard(
                            value: _isLoadingStats ? '-' : '$_checkedOutCount',
                            label: 'Checked Out',
                            color: Colors.red.shade50,
                            icon: Icons.logout,
                            iconColor: Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // RECENT ACTIVITY - Diperkecil
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Recent Activity',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Full history coming soon'),
                              ),
                            );
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'View All',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_isLoadingActivities)
                      Container(
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (_recentActivities.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.history,
                                size: 36,
                                color: Colors.grey.shade300,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'No recent activity',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Column(
                        children: _recentActivities
                            .map((activity) => _buildActivityItem(activity))
                            .toList(),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        onAttendanceTap: _handleCameraButtonPress,
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

    final ImageProvider avatarImage = (photoUrl != null && photoUrl.isNotEmpty)
        ? NetworkImage(photoUrl)
        : const AssetImage('images/logo.png');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
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
              CircleAvatar(
                radius: 20,
                backgroundImage: avatarImage,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatEventTime(lastUpdated),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _buildStatusChipWithMethod(
                  'CHECK IN',
                  _formatShortTime(checkInTime),
                  checkInMethod,
                  Colors.green.shade800,
                  Colors.green.shade50,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStatusChipWithMethod(
                  'CHECK OUT',
                  _formatShortTime(checkOutTime),
                  checkOutMethod,
                  Colors.blue.shade800,
                  Colors.blue.shade50,
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