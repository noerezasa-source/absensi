import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../helpers/timezone_helper.dart';
import '../services/attendance_service.dart';
import '../services/role_service.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'face_attendance_multi_user_page.dart';
import 'petugas_profile_page.dart';

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
  String _organizationTimezone = 'Asia/Jakarta'; // Default to WIB

  // Stats data
  int _checkedInCount = 0;
  int _pendingCount = 0;
  int _lateCount = 0;

  // Recent activity data
  List<Map<String, dynamic>> _recentActivities = [];

  @override
  void initState() {
    super.initState();
    debugPrint('=== PETUGAS DASHBOARD INIT (KIOSK MODE) ===');
    debugPrint('Organization Member ID: ${widget.organizationMemberId}');
    debugPrint('Role: ${_roleService.getRoleName(widget.memberData)}');
    _loadOrganizationTimezone();
    _refreshAll();
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
      debugPrint('Loading today statistics for organization $organizationId...');
      
      final stats = await _attendanceService.getOrganizationTodayStats(organizationId);
      
      if (mounted) {
        setState(() {
          _checkedInCount = stats['checked_in'] ?? 0;
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
    await Future.wait([
      _loadTodayStats(),
      _loadRecentActivities(),
    ]);
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
        limit: 6,
      );

      if (!mounted) return;

      final mappedActivities = activities.map((activity) {
        final member = activity['organization_members'] as Map<String, dynamic>? ?? {};
        final profile = member['user_profiles'] as Map<String, dynamic>? ?? {};
        final record = activity['attendance_records'] as Map<String, dynamic>? ?? {};

        DateTime? eventTime;
        final eventTimeStr = activity['event_time'] as String?;
        if (eventTimeStr != null) {
          // Convert UTC to organization timezone
          eventTime = TimezoneHelper.parseAndConvert(
            eventTimeStr,
            _organizationTimezone,
          );
        }

        return {
          'name': _composeUserName(profile),
          'photoUrl': _resolveProfilePhotoUrl(profile['profile_photo_url'] as String?),
          'eventType': activity['event_type'] as String?,
          'method': activity['method'] as String?,
          'eventTime': eventTime,
          'status': record['status'] as String?,
        };
      }).toList();

      setState(() {
        _recentActivities = mappedActivities;
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

  Future<void> _navigateToMultiUserFaceAttendance(String type) async {
    try {
      final organizationId = widget.memberData['organization_id'];
      
      if (organizationId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Organization ID not found')),
        );
        return;
      }

      // Navigate to kiosk mode face attendance
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  void _handleCameraButtonPress() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Start Attendance Session',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Select the type of attendance to begin',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _navigateToMultiUserFaceAttendance('check_in');
                    },
                    icon: const Icon(Icons.login, size: 24),
                    label: const Text(
                      'Check In',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _navigateToMultiUserFaceAttendance('check_out');
                    },
                    icon: const Icon(Icons.logout, size: 24),
                    label: const Text(
                      'Check Out',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        // Home - stay on current page
        break;
      case 1:
        // Scanner
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('QR Scanner feature coming soon')),
        );
        break;
      case 2:
        // Records
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Records feature coming soon')),
        );
        break;
      case 3:
        // Profile
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasProfilePage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: widget.userProfile,
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 0;
          });
        });
        break;
    }
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    final weekday = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][now.weekday - 1];
    final month = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][now.month - 1];
    return '$weekday, ${now.day} $month ${now.year}';
  }

  String _getDisplayName() {
    final profile = widget.userProfile;
    if (profile == null) {
      return 'Petugas Attendance';
    }

    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();
    return fullName.isEmpty ? 'Petugas Attendance' : fullName;
  }

  ImageProvider _getProfileImage() {
    final photoUrl =
        _resolveProfilePhotoUrl(widget.userProfile?['profile_photo_url'] as String?);
    if (photoUrl != null && photoUrl.isNotEmpty) {
      return NetworkImage(photoUrl);
    }
    return const AssetImage('images/logo.png');
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
    
    // Get current time in organization timezone for comparison
    final nowUtc = DateTime.now().toUtc();
    final nowOrg = TimezoneHelper.parseAndConvert(
      nowUtc.toIso8601String(),
      _organizationTimezone,
    ) ?? nowUtc;
    
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
              // ---------- HEADER CARD ----------
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
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
                            color: Colors.white.withValues(alpha: 0.3),
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
                            color: Colors.white.withValues(alpha: 0.3),
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
                    // Profile Card with Petugas Badge
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Profile Image with Petugas Badge
                          Stack(
                            children: [
                              Container(
                                width: 60,
                                height: 60,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF9333EA),
                                    width: 2,
                                  ),
                                  image: DecorationImage(
                                    image: _getProfileImage(),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
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
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(width: 16),
                          // Profile Info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getDisplayName(),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF3E8FF),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.badge,
                                            size: 14,
                                            color: Color(0xFF9333EA),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _roleService.getRoleName(widget.memberData),
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Color(0xFF9333EA),
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Settings Icon
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.settings,
                              size: 18,
                              color: Colors.black54,
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
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade100),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Colors.redAccent, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close,
                              size: 16, color: Colors.redAccent),
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

              const SizedBox(height: 24),

            

              // ---------- QUICK ACTIONS ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Quick Actions",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const SizedBox(width: 12),
                        _QuickActionCard(
                          icon: Icons.people,
                          label: 'Manual Check',
                          color: Colors.blue.shade50,
                          iconColor: Colors.blue,
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Manual check coming soon')),
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ---------- TODAY'S SUMMARY ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Today's Summary",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _StatCard(
                          value: _isLoadingStats ? '-' : '$_checkedInCount',
                          label: 'Checked In',
                          color: Colors.green.shade50,
                          icon: Icons.login,
                          iconColor: Colors.green,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          value: _isLoadingStats ? '-' : '$_lateCount',
                          label: 'Late',
                          color: Colors.red.shade50,
                          icon: Icons.warning,
                          iconColor: Colors.red,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ---------- RECENT ACTIVITY ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Recent Activity',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Full history coming soon')),
                            );
                          },
                          child: const Text('View All'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_isLoadingActivities)
                      Container(
                        padding: const EdgeInsets.all(40),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else if (_recentActivities.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(40),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.history,
                                size: 48,
                                color: Colors.grey.shade300,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No recent activity',
                                style: TextStyle(
                                  fontSize: 16,
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

              const SizedBox(height: 100),
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

  Widget _buildInfoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xFF9333EA)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActivityItem(Map<String, dynamic> activity) {
    final name = activity['name'] as String? ?? 'Unknown User';
    final eventType = activity['eventType'] as String?;
    final method = activity['method'] as String?;
    final eventTime = activity['eventTime'] as DateTime?;
    final photoUrl = activity['photoUrl'] as String?;

    final ImageProvider avatarImage = (photoUrl != null && photoUrl.isNotEmpty)
        ? NetworkImage(photoUrl)
        : const AssetImage('images/logo.png');

    final isCheckIn = eventType == 'check_in';
    final chipColor = isCheckIn ? Colors.green : Colors.red;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 26,
            backgroundImage: avatarImage,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatEventTime(eventTime),
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildStatusChip(
                      _formatEventType(eventType),
                      chipColor,
                      chipColor.withValues(alpha: 0.1),
                    ),
                    if (method != null &&
                        !method.toLowerCase().contains('face_recognition'))
                      _buildStatusChip(
                        method.replaceAll('_', ' ').toUpperCase(),
                        Colors.blueGrey,
                        Colors.blueGrey.withValues(alpha: 0.1),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String label, Color textColor, Color backgroundColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

}

// ========== SUPPORTING WIDGETS ==========

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
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(icon, color: iconColor, size: 32),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
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
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            if (icon != null)
              Icon(icon, color: iconColor ?? Colors.black54, size: 24),
            if (icon != null) const SizedBox(height: 8),
            Text(
              value,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}