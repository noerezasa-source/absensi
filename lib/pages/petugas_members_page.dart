import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/attendance_service.dart';
import '../services/role_service.dart';
import '../services/member_performance_service.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'petugas_dashboard.dart';
import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';

class PetugasMembersPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasMembersPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<PetugasMembersPage> createState() => _PetugasMembersPageState();
}

class _PetugasMembersPageState extends State<PetugasMembersPage>
    with SingleTickerProviderStateMixin {
  static const Color primaryColor = Color(0xFF6B46C1);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFF1F2937);

  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();
  final MemberPerformanceService _performanceService = MemberPerformanceService();

  bool _isLoading = true;
  bool _isLoadingPerformance = false;
  bool _isLoadingActivities = false;
  String? _errorMessage;
  int _currentNavIndex = 1;
  String _organizationTimezone = 'Asia/Jakarta';

  List<Map<String, dynamic>> _organizationMembers = [];
  Map<String, dynamic>? _organization;
  Map<String, dynamic> _memberPerformanceStats = {};
  List<Map<String, dynamic>> _topPerformers = [];
  List<Map<String, dynamic>> _lowPerformers = [];
  List<Map<String, dynamic>> _recentActivities = [];
  String _searchQuery = '';
  String _selectedDepartment = 'All';
  List<String> _departments = ['All'];

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadDataOptimized();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDataOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== STARTING FAST DATA LOADING ===');
    
    // Load everything in parallel for fastest response
    await Future.wait([
      _loadOrganizationData(),
      _loadOrganizationMembersOptimized(),
      _loadPerformanceStatsOptimized(),
    ]);
    
    // Load activities separately to not block main content
    _loadRecentActivitiesOptimized();
  }

  Future<void> _loadOrganizationMembersOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING ORGANIZATION MEMBERS (OPTIMIZED) ===');
    debugPrint('Organization ID: $organizationId');

    try {
      final members = await _performanceService.getOrganizationMembers(organizationId);
      
      debugPrint('Received ${members.length} members from service');
      
      if (mounted) {
        setState(() {
          _organizationMembers = members;
          
          // Extract departments for filtering
          final deptSet = <String>{'All'};
          for (final member in members) {
            final dept = member['departments'] as Map<String, dynamic>?;
            if (dept != null && dept['name'] != null) {
              deptSet.add(dept['name'] as String);
            }
          }
          _departments = deptSet.toList();
          
          _isLoading = false;
        });
        
        debugPrint('State updated - Members: ${_organizationMembers.length}');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading organization members: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load members: $e';
        });
      }
    }
  }

  Future<void> _loadPerformanceStatsOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING PERFORMANCE STATS (OPTIMIZED) ===');

    setState(() => _isLoadingPerformance = true);

    try {
      // Get organization performance summary
      final summary = await _performanceService.getOrganizationPerformanceSummary(organizationId);
      
      // Get top performers only (limit to 10 for faster loading)
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        limit: 10,
      );

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          _topPerformers = performers.take(5).toList();
          _lowPerformers = performers.reversed.take(5).toList();
          _isLoadingPerformance = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading performance stats: $e');
      if (mounted) {
        setState(() {
          _isLoadingPerformance = false;
        });
      }
    }
  }

  Future<void> _loadRecentActivitiesOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING RECENT ACTIVITIES (OPTIMIZED) ===');

    setState(() => _isLoadingActivities = true);

    try {
      final activities = await _performanceService.getRecentMemberActivities(
        organizationId,
        limit: 5, // Limit to 5 for faster loading
      );
      
      debugPrint('Recent activities loaded: ${activities.length}');
      
      if (mounted) {
        setState(() {
          _recentActivities = activities;
          _isLoadingActivities = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
      if (mounted) {
        setState(() {
          _isLoadingActivities = false;
        });
      }
    }
  }

  Future<void> _loadOrganizationData() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('id, name, logo_url, timezone')
          .eq('id', organizationId)
          .single();

      if (mounted && org != null) {
        setState(() {
          _organization = org;
          if (org['timezone'] != null) {
            _organizationTimezone = org['timezone'];
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading organization data: $e');
    }
  }

  Future<void> _loadOrganizationMembers() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING ORGANIZATION MEMBERS ===');
    debugPrint('Organization ID: $organizationId');
    debugPrint('Member data: ${widget.memberData}');

    setState(() => _isLoading = true);

    try {
      final members = await _performanceService.getOrganizationMembers(organizationId);
      
      debugPrint('Received ${members.length} members from service');
      
      if (mounted) {
        setState(() {
          _organizationMembers = members;
          
          // Extract departments for filtering
          final deptSet = <String>{'All'};
          for (final member in members) {
            final dept = member['departments'] as Map<String, dynamic>?;
            if (dept != null && dept['name'] != null) {
              deptSet.add(dept['name'] as String);
            }
          }
          _departments = deptSet.toList();
          
          _isLoading = false;
        });
        
        debugPrint('State updated - Members: ${_organizationMembers.length}');
        debugPrint('Departments: $_departments');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading organization members: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load members: $e';
        });
      }
    }
  }

  Future<void> _loadPerformanceStats() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING PERFORMANCE STATS ===');
    debugPrint('Organization ID: $organizationId');

    setState(() => _isLoadingPerformance = true);

    try {
      // Get organization performance summary
      final summary = await _performanceService.getOrganizationPerformanceSummary(organizationId);
      debugPrint('Performance summary received: $summary');
      
      // Get top and low performers
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        limit: 50,
      );
      debugPrint('Performers data count: ${performers.length}');

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          _topPerformers = performers.take(5).toList();
          _lowPerformers = performers.reversed.take(5).toList();
          _isLoadingPerformance = false;
        });
        
        debugPrint('Performance stats updated successfully');
        debugPrint('Top performers: ${_topPerformers.length}');
        debugPrint('Low performers: ${_lowPerformers.length}');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading performance stats: $e');
      if (mounted) {
        setState(() {
          _isLoadingPerformance = false;
        });
      }
    }
  }

  Future<void> _loadRecentActivities() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    debugPrint('=== LOADING RECENT ACTIVITIES ===');
    debugPrint('Organization ID: $organizationId');

    try {
      final activities = await _performanceService.getRecentMemberActivities(
        organizationId,
        limit: 10,
      );
      
      debugPrint('Recent activities loaded: ${activities.length}');
      
      if (mounted) {
        setState(() {
          _recentActivities = activities;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading recent activities: $e');
    }
  }

  Future<void> _testDatabaseConnection() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final testResult = await _performanceService.testDatabaseConnection(organizationId);
      debugPrint('=== DATABASE TEST RESULT ===');
      debugPrint('Test result: $testResult');
      
      if (testResult['error'] != null) {
        debugPrint('Database connection error: ${testResult['error']}');
      } else {
        debugPrint('Database connection successful!');
        debugPrint('Organization exists: ${testResult['organization_exists']}');
        debugPrint('Active members: ${testResult['active_members_count']}');
        debugPrint('Attendance records: ${testResult['attendance_records_count']}');
      }
    } catch (e) {
      debugPrint('!!! ERROR in database test: $e');
    }
  }

  List<Map<String, dynamic>> get _filteredMembers {
    return _organizationMembers.where((member) {
      // Filter by search query
      if (_searchQuery.isNotEmpty) {
        final profile = member['user_profiles'] as Map<String, dynamic>?;
        final displayName = profile?['display_name'] as String? ?? '';
        final firstName = profile?['first_name'] as String? ?? '';
        final lastName = profile?['last_name'] as String? ?? '';
        final employeeId = member['employee_id'] as String? ?? '';
        final query = _searchQuery.toLowerCase();
        
        final fullName = '$displayName $firstName $lastName $employeeId'.toLowerCase();
        if (!fullName.contains(query)) return false;
      }

      // Filter by department
      if (_selectedDepartment != 'All') {
        final dept = member['departments'] as Map<String, dynamic>?;
        final deptName = dept?['name'] as String? ?? '';
        if (deptName != _selectedDepartment) return false;
      }

      return true;
    }).toList();
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        Navigator.popUntil(context, (route) => route.isFirst);
        break;
      case 1:
        // Members - stay on current page
        break;
      case 2:
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasRecordsPage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: widget.userProfile,
            ),
          ),
        ).then((_) {
          setState(() {
            _currentNavIndex = 1;
          });
        });
        break;
      case 3:
        Navigator.push<bool>(
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
            _currentNavIndex = 1;
          });
        });
        break;
    }
  }

  String _getMemberName(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
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

  String? _getMemberPhotoUrl(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    final photoPath = profile?['profile_photo_url'] as String?;

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _formatPercentage(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        body: const Center(child: CircularProgressIndicator(color: primaryColor)),
        bottomNavigationBar: PetugasBottomNav(
          currentIndex: _currentNavIndex,
          onNavigationTap: _handleNavigation,
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: NestedScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverToBoxAdapter(child: _buildHeader()),
            SliverPersistentHeader(
              pinned: true,
              delegate: _SliverTabBarDelegate(
                TabBar(
                  controller: _tabController,
                  labelColor: primaryColor,
                  unselectedLabelColor: Colors.grey,
                  indicatorColor: primaryColor,
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: const [
                    Tab(text: 'Overview'),
                    Tab(text: 'Members'),
                    Tab(text: 'Performance'),
                  ],
                ),
              ),
            ),
          ];
        },
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildOverviewTab(),
            _buildMembersTab(),
            _buildPerformanceTab(),
          ],
        ),
      ),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [backgroundColor, Color(0xFF374151)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(24),
          bottomRight: Radius.circular(24),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _organization?['logo_url'] != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          _organization!['logo_url']!,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return _buildDefaultLogo();
                          },
                        ),
                      )
                    : _buildDefaultLogo(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Member Management',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _organization?['name'] ?? 'Unknown Organization',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDefaultLogo() {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.business, color: Colors.white, size: 28),
    );
  }

  Widget _buildOverviewTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildPerformanceSummary(),
          const SizedBox(height: 20),
          _buildStatsCards(),
          const SizedBox(height: 20),
          _buildAttendanceTrend(),
          const SizedBox(height: 20),
          _buildRecentActivities(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

 Widget _buildStatsCards() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Organization Statistics',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
          letterSpacing: -0.3,
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _buildStatCard(
              'Total Members',
              '${_memberPerformanceStats['total_members'] ?? 0}',
              const Color(0xFF3B82F6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              'Active Today',
              '${_memberPerformanceStats['active_members'] ?? 0}',
              const Color(0xFF10B981),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _buildStatCard(
              'Attendance',
              _formatPercentage(_memberPerformanceStats['avg_attendance_rate'] ?? 0.0),
              const Color(0xFFF59E0B),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard(
              'Punctuality',
              _formatPercentage(_memberPerformanceStats['avg_punctuality_rate'] ?? 0.0),
              const Color(0xFF8B5CF6),
            ),
          ),
        ],
      ),
    ],
  );
}

 Widget _buildStatCard(String title, String value, Color accentColor) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey.shade100, width: 1),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.03),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: accentColor,
                  height: 1.0,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

  Widget _buildPerformanceSummary() {
    final totalMembers = _memberPerformanceStats['total_members'] ?? 0;
    final activeMembers = _memberPerformanceStats['active_members'] ?? 0;
    final attendanceRate = _memberPerformanceStats['avg_attendance_rate'] ?? 0.0;
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6B46C1), Color(0xFF8B5CF6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6B46C1).withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Today\'s Overview',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  DateFormat('MMM dd, yyyy').format(DateTime.now()),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildSummaryItem(
                  'Active',
                  '$activeMembers',
                  'of $totalMembers members',
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: Colors.white.withOpacity(0.3),
              ),
              Expanded(
                child: _buildSummaryItem(
                  'Attendance',
                  '${(attendanceRate * 100).toStringAsFixed(0)}%',
                  'average rate',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryItem(String label, String value, String subtitle) {
    return Column(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withOpacity(0.8),
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withOpacity(0.7),
          ),
        ),
      ],
    );
  }

  Widget _buildAttendanceTrend() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Attendance Trend',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade100, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildTrendItem(
                    'This Week',
                    '${((_memberPerformanceStats['avg_attendance_rate'] ?? 0.0) * 100).toStringAsFixed(0)}%',
                    true,
                  ),
                  _buildTrendItem(
                    'Last Week',
                    '${(((_memberPerformanceStats['avg_attendance_rate'] ?? 0.0) - 0.05) * 100).toStringAsFixed(0)}%',
                    false,
                  ),
                  _buildTrendItem(
                    'This Month',
                    '${((_memberPerformanceStats['avg_attendance_rate'] ?? 0.0) * 100).toStringAsFixed(0)}%',
                    false,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _memberPerformanceStats['avg_attendance_rate'] ?? 0.0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF10B981), Color(0xFF059669)],
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrendItem(String label, String value, bool isHighlighted) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: isHighlighted ? 20 : 16,
            fontWeight: isHighlighted ? FontWeight.bold : FontWeight.w600,
            color: isHighlighted ? const Color(0xFF10B981) : Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }



  Widget _buildQuickInsights() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Quick Insights',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
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
              _buildInsightItem(
                'Best performing department',
                'Engineering Team',
                Icons.trending_up,
                Colors.green,
              ),
              const Divider(),
              _buildInsightItem(
                'Members with perfect attendance',
                '12 members this month',
                Icons.star,
                Colors.orange,
              ),
              const Divider(),
              _buildInsightItem(
                'Needs attention',
                '3 members with low punctuality',
                Icons.warning,
                Colors.red,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInsightItem(String title, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentActivities() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Recent Activities',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
                letterSpacing: -0.3,
              ),
            ),
            TextButton(
              onPressed: () {
                // Navigate to full logs
              },
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF6B46C1),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          constraints: const BoxConstraints(
            maxHeight: 400,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade100, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: _isLoadingActivities
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: CircularProgressIndicator(color: primaryColor),
                  ),
                )
              : _recentActivities.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.history,
                              size: 40,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No activities today',
                              style: TextStyle(
                                color: Colors.grey.shade500,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _recentActivities.length,
                      separatorBuilder: (context, index) => Divider(
                        height: 1,
                        color: Colors.grey.shade100,
                      ),
                      itemBuilder: (context, index) {
                        final activity = _recentActivities[index];
                        final memberName = activity['member_name'] as String? ?? 'Unknown';
                        final eventType = activity['event_type'] as String? ?? 'Unknown';
                        final timeAgo = activity['time_ago'] as String? ?? 'Just now';
                        final method = activity['method'] as String? ?? '';
                        final memberInfo = activity['member_info'] as Map<String, dynamic>? ?? {};
                        
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.grey.shade100,
                                backgroundImage: _getMemberPhotoUrl(memberInfo) != null
                                    ? NetworkImage(_getMemberPhotoUrl(memberInfo)!)
                                    : null,
                                child: _getMemberPhotoUrl(memberInfo) == null
                                    ? Icon(Icons.person, color: Colors.grey.shade400, size: 20)
                                    : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      memberName,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        _buildActivityBadge(eventType),
                                        if (method.isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          Text(
                                            'via $method',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade500,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                timeAgo,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildActivityBadge(String eventType) {
    Color color;
    String label;
    
    switch (eventType.toLowerCase()) {
      case 'check_in':
        color = const Color(0xFF10B981);
        label = 'Check In';
        break;
      case 'check_out':
        color = const Color(0xFFEF4444);
        label = 'Check Out';
        break;
      case 'break_start':
        color = const Color(0xFFF59E0B);
        label = 'Break Start';
        break;
      case 'break_end':
        color = const Color(0xFF3B82F6);
        label = 'Break End';
        break;
      default:
        color = Colors.grey;
        label = eventType.replaceAll('_', ' ');
    }
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }



  Widget _buildMembersTab() {
    return Column(
      children: [
        _buildFiltersAndSearch(),
        Expanded(
          child: _buildMembersList(),
        ),
      ],
    );
  }

  Widget _buildFiltersAndSearch() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
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
      child: Column(
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: 'Search members...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedDepartment,
            decoration: const InputDecoration(
              labelText: 'Department',
              prefixIcon: Icon(Icons.business),
            ),
            items: _departments.map((dept) {
              return DropdownMenuItem(
                value: dept,
                child: Text(dept),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedDepartment = value!;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMembersList() {
    final filteredMembers = _filteredMembers;
    
    if (filteredMembers.isEmpty) {
      return const Center(
        child: Text('No members found'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: filteredMembers.length,
      itemBuilder: (context, index) {
        final member = filteredMembers[index];
        return _buildMemberCard(member);
      },
    );
  }

  Widget _buildMemberCard(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    final position = member['positions'] as Map<String, dynamic>?;
    final isActive = member['status'] != 'inactive'; // Assuming inactive logic, change if needed
    
    return InkWell(
      onTap: () => _showMemberDetail(member),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade100, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Colors.grey.shade200,
              backgroundImage: _getMemberPhotoUrl(member) != null
                  ? CachedNetworkImageProvider(_getMemberPhotoUrl(member)!)
                  : null,
              child: _getMemberPhotoUrl(member) == null
                  ? Icon(Icons.person, color: Colors.grey.shade600)
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _getMemberName(member),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isActive) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF10B981),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (department != null)
                    Text(
                      department['name'] ?? 'No Department',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  if (position != null)
                    Text(
                      position['title'] ?? 'No Position',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade400,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.grey.shade400,
              size: 24,
            ),
          ],
        ),
      ),
    );
  }

  void _showMemberDetail(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    final deptName = department?['name'] ?? 'No Department';
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
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
            const SizedBox(height: 24),
            CircleAvatar(
              radius: 40,
              backgroundColor: Colors.grey.shade200,
              backgroundImage: _getMemberPhotoUrl(member) != null
                  ? CachedNetworkImageProvider(_getMemberPhotoUrl(member)!)
                  : null,
              child: _getMemberPhotoUrl(member) == null
                  ? const Icon(Icons.person, size: 40, color: Colors.grey)
                  : null,
            ),
            const SizedBox(height: 16),
            Text(
              _getMemberName(member),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                deptName,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: _buildDetailStat(
                    'Attendance',
                    _formatPercentage(member['performance_stats']?['attendance_rate'] ?? 0.0),
                    Icons.calendar_today,
                    const Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildDetailStat(
                    'Punctuality',
                    _formatPercentage(member['performance_stats']?['punctuality_rate'] ?? 0.0),
                    Icons.schedule,
                    const Color(0xFF8B5CF6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6B46C1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Close',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailStat(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.1)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }



  Widget _buildPerformanceTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTopPerformers(),
            const SizedBox(height: 20),
            _buildLowPerformers(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopPerformers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.trending_up, color: Colors.green),
            const SizedBox(width: 8),
            const Text(
              'Top Performers',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'This Month',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
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
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _topPerformers.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final member = _topPerformers[index];
              final performance = member['performance_stats'] as Map<String, dynamic>;
              return _buildPerformerListItem(member, performance, index + 1, true);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLowPerformers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.trending_down, color: Colors.red),
            const SizedBox(width: 8),
            const Text(
              'Needs Attention',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'This Month',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.red,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
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
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _lowPerformers.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final member = _lowPerformers[index];
              final performance = member['performance_stats'] as Map<String, dynamic>;
              return _buildPerformerListItem(member, performance, index + 1, false);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPerformerListItem(
    Map<String, dynamic> member,
    Map<String, dynamic> performance,
    int rank,
    bool isTopPerformer,
  ) {
    final color = isTopPerformer ? Colors.green : Colors.red;
    
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.1),
        child: Text(
          rank.toString(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
      title: Text(
        _getMemberName(member),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Productivity Score: ${_formatPercentage(performance['productivity_score'])}',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _buildMiniBadge(
                'Attendance',
                _formatPercentage(performance['attendance_rate']),
                performance['attendance_rate'] > 0.8 ? Colors.green : Colors.orange,
              ),
              _buildMiniBadge(
                'Punctuality',
                _formatPercentage(performance['punctuality_rate']),
                performance['punctuality_rate'] > 0.8 ? Colors.green : Colors.orange,
              ),
            ],
          ),
        ],
      ),
      trailing: Icon(
        isTopPerformer ? Icons.emoji_events : Icons.warning,
        color: color,
        size: 20,
      ),
      isThreeLine: false,
    );
  }

  Widget _buildMiniBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );
  }
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;

  _SliverTabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Colors.white,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}
