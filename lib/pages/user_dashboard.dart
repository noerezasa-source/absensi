import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/biometric_service.dart';
import '../services/role_service.dart';
import '../widgets/user_bottom_nav.dart';
import 'face_registration_page.dart';
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

class _UserDashboardPageState extends State<UserDashboardPage> {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final _supabase = Supabase.instance.client;

  bool _hasRegisteredFace = false;
  bool _isCheckingFace = true;
  bool _isLoadingProfile = true;
  bool _isLoadingStats = true;
  String? _errorMessage;
  Map<String, dynamic>? _userProfile;
  Map<String, dynamic>? _attendanceStats;

  @override
  void initState() {
    super.initState();
    print('=== USER DASHBOARD INIT ===');
    print('Organization Member ID: ${widget.organizationMemberId}');
    print('Role: ${_roleService.getRoleName(widget.memberData)}');
    _loadUserProfile();
    _checkFaceRegistration();
    _loadAttendanceStats();
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

      // Get attendance records for current month
      final records = await _supabase
          .from('attendance_records')
          .select()
          .eq('organization_member_id', widget.organizationMemberId)
          .gte('attendance_date', firstDayOfMonth.toIso8601String().split('T')[0])
          .lte('attendance_date', lastDayOfMonth.toIso8601String().split('T')[0]);

      int presentDays = 0;
      int lateDays = 0;
      int totalWorkHours = 0;

      for (var record in records) {
        if (record['actual_check_in'] != null) {
          presentDays++;
        }
        if (record['late_minutes'] != null && record['late_minutes'] > 0) {
          lateDays++;
        }
        if (record['work_duration_minutes'] != null) {
          totalWorkHours += (record['work_duration_minutes'] as int);
        }
      }

      if (mounted) {
        setState(() {
          _attendanceStats = {
            'present_days': presentDays,
            'late_days': lateDays,
            'work_hours': (totalWorkHours / 60).toStringAsFixed(1),
            'total_records': records.length,
          };
          _isLoadingStats = false;
        });
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
                    colors: [Color(0xFF6C63FF), Color(0xFF8B84FF)],
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
                                      color: const Color(0xFF6C63FF),
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
                                          color: const Color(0xFFE8E5FF),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _roleService.getRoleName(widget.memberData),
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF6C63FF),
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
                    // Attendance Statistics Card
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
                                  Icons.bar_chart_rounded,
                                  color: Color(0xFF6C63FF),
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