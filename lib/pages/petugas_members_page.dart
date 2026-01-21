import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/attendance_service.dart';
import '../services/role_service.dart';
import '../services/member_performance_service.dart';
import '../services/face_recognition_tflite_service.dart';
import '../services/biometric_service.dart';
import '../services/supabase_storage_service.dart';
import '../helpers/timezone_helper.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'petugas_dashboard.dart';
import 'petugas_records_page.dart';
import 'petugas_profile_page.dart';
import 'face_registration_page.dart';

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

  bool _isInitialLoading = true;
  bool _isContentLoading = false;
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
  final TextEditingController _searchController = TextEditingController();
  String _selectedDepartment = 'All';
  List<String> _departments = ['All'];

  // Enhancement features state
  String _selectedTimePeriod = 'This Month';
  String _selectedSortBy = 'Total Attendance';
  List<Map<String, dynamic>> _performanceTrend = [];
  Map<String, dynamic> _comparisonData = {};
  Map<int, List<String>> _memberAchievements = {};
  bool _isLoadingTrend = false;
  bool _isLoadingComparison = false;

  // Pagination
  final ScrollController _scrollController = ScrollController();
  int _currentPage = 1;
  static const int _pageSize = 20; // Increased page size for better performance
  int _totalMembers = 0;
  int _totalPages = 0;
  DateTime? _lastLoadTime; // Prevent rapid successive loads
  bool _isPaginationDisabled = false; // Flag to completely disable pagination

  late TabController _tabController;
  StreamSubscription? _biometricSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _scrollController.addListener(_onScroll);
    _loadDataOptimized();
    _setupBiometricRealtimeListener();
  }


  void _onScroll() {
    // Automatic pagination removed - replaced with Load More button
  }

  @override
  void dispose() {
    _biometricSubscription?.cancel();
    _tabController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _setupBiometricRealtimeListener() {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    // Listen to biometric_data table changes
    _biometricSubscription = _supabase
        .from('biometric_data')
        .stream(primaryKey: ['id'])
        .listen((_) {
          if (!mounted) return;
          debugPrint('🔄 Biometric data changed, refreshing member list...');
          // Refresh list to update Face/No Face badges
          _loadOrganizationMembersOptimized(page: _currentPage);
        });
  }

  Future<void> _loadDataOptimized() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    setState(() => _isInitialLoading = true);
    
    try {
      await Future.wait([
        _loadOrganizationData(),
        _loadOrganizationMembersOptimized(page: 1, isInitial: true),
        _loadPerformanceStatsOptimized(),
      ]);
    } finally {
      if (mounted) setState(() => _isInitialLoading = false);
    }
    
    _loadRecentActivitiesOptimized();
  }

  Future<void> _loadOrganizationMembersOptimized({int page = 1, bool isInitial = false}) async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    if (!mounted) return;
    setState(() {
      if (!isInitial) _isContentLoading = true;
      _currentPage = page;
    });

    try {
      final searchQuery = _searchController.text.trim();
      
      // Fetch members and total count in parallel if it's page 1 or total count is 0
      final futures = <Future>[
        _performanceService.getOrganizationMembers(
          organizationId,
          page: _currentPage,
          limit: _pageSize,
          searchQuery: searchQuery.isNotEmpty ? searchQuery : null,
          departmentFilter: _selectedDepartment != 'All' ? _selectedDepartment : null,
        )
      ];

      if (_currentPage == 1 || _totalMembers == 0) {
        futures.add(_performanceService.getOrganizationMembersCount(
          organizationId,
          searchQuery: searchQuery.isNotEmpty ? searchQuery : null,
          departmentFilter: _selectedDepartment != 'All' ? _selectedDepartment : null,
        ));
      }

      final results = await Future.wait(futures);
      final members = results[0] as List<Map<String, dynamic>>;
      
      if (mounted) {
        setState(() {
          _organizationMembers = members;
          
          if (results.length > 1) {
            _totalMembers = results[1] as int;
            _totalPages = (_totalMembers / _pageSize).ceil();
          }
          
          _isPaginationDisabled = false;
          
          if (_departments.length <= 1) {
            final deptSet = <String>{'All'};
            for (final member in members) {
              final dept = member['departments'] as Map<String, dynamic>?;
              if (dept != null && dept['name'] != null) {
                deptSet.add(dept['name'] as String);
              }
            }
            _departments = deptSet.toList();
          }
          
          if (!isInitial) _isContentLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (!isInitial) _isContentLoading = false;
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
      // Get organization performance summary (uses aggregated data, not all members)
      final summary = await _performanceService.getOrganizationPerformanceSummary(organizationId);
      
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);
      final endOfMonth = DateTime(now.year, now.month + 1, 0);

      // Get top performers only (limit to 20 to get better top/bottom performers)
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        startDate: startOfMonth,
        endDate: endOfMonth,
        limit: 20,
      );

      if (mounted) {
        setState(() {
          _memberPerformanceStats = summary;
          // Get top 5 and bottom 5 from the sorted list
          _topPerformers = performers.take(5).toList();
          _lowPerformers = performers.length > 5 
              ? performers.reversed.take(5).toList()
              : performers.reversed.toList();
          _isLoadingPerformance = false;
        });
        
        debugPrint('Performance stats loaded - Top: ${_topPerformers.length}, Low: ${_lowPerformers.length}');
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

    setState(() => _isInitialLoading = true);

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
          
          _isInitialLoading = false;
        });
        
        debugPrint('State updated - Members: ${_organizationMembers.length}');
        debugPrint('Departments: $_departments');
      }
    } catch (e) {
      debugPrint('!!! ERROR loading organization members: $e');
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
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
      
      final now = DateTime.now();
      final startOfMonth = DateTime(now.year, now.month, 1);
      final endOfMonth = DateTime(now.year, now.month + 1, 0);

      // Get top and low performers
      final performers = await _performanceService.getMembersPerformanceData(
        organizationId,
        startDate: startOfMonth,
        endDate: endOfMonth,
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

  // Helper function to get achievement icon
  IconData _getAchievementIcon(String achievementType) {
    switch (achievementType) {
      case 'perfect_attendance':
        return Icons.emoji_events;
      case 'most_punctual':
        return Icons.schedule;
      case 'consistent_performer':
        return Icons.trending_up;
      case 'early_bird':
        return Icons.wb_sunny;
      case 'overtime_champion':
        return Icons.work;
      case 'productivity_star':
        return Icons.star;
      default:
        return Icons.emoji_events;
    }
  }

  // Helper function to get achievement label
  String _getAchievementLabel(String achievementType) {
    switch (achievementType) {
      case 'perfect_attendance':
        return 'Perfect Attendance';
      case 'most_punctual':
        return 'Most Punctual';
      case 'consistent_performer':
        return 'Consistent';
      case 'early_bird':
        return 'Early Bird';
      case 'overtime_champion':
        return 'Overtime Champion';
      case 'productivity_star':
        return 'Productivity Star';
      default:
        return achievementType;
    }
  }

  // Helper function to get achievement color
  Color _getAchievementColor(String achievementType) {
    switch (achievementType) {
      case 'perfect_attendance':
        return Colors.amber;
      case 'most_punctual':
        return Colors.blue;
      case 'consistent_performer':
        return Colors.green;
      case 'early_bird':
        return Colors.orange;
      case 'overtime_champion':
        return Colors.purple;
      case 'productivity_star':
        return Colors.pink;
      default:
        return Colors.grey;
    }
  }

  // Helper function to build comparison badge
  Widget _buildComparisonBadge(double changePercentage) {
    final isPositive = changePercentage >= 0;
    final color = isPositive ? Colors.green : Colors.red;
    final icon = isPositive ? Icons.arrow_upward : Icons.arrow_downward;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 2),
          Text(
            '${changePercentage.abs().toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // Helper function to build achievement badges
  Widget _buildAchievementBadges(int memberId) {
    final badges = _memberAchievements[memberId] ?? [];
    
    if (badges.isEmpty) return const SizedBox.shrink();
    
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: badges.take(3).map((badge) {
        return Tooltip(
          message: _getAchievementLabel(badge),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _getAchievementColor(badge).withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _getAchievementIcon(badge),
              size: 14,
              color: _getAchievementColor(badge),
            ),
          ),
        );
      }).toList(),
    );
  }


  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
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
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [backgroundColor, Color(0xFF374151)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _organization?['logo_url'] != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          _organization!['logo_url']!,
                          width: 42,
                          height: 42,
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
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _organization?['name'] ?? 'Unknown Organization',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontSize: 11,
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
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.business, color: Colors.white, size: 24),
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
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                'Total Members',
                '${_memberPerformanceStats['total_members'] ?? 0}',
                const Color(0xFF3B82F6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildStatCard(
                'Active Today',
                '${_memberPerformanceStats['active_members'] ?? 0}',
                const Color(0xFF10B981),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                'Attendance',
                _formatPercentage(_memberPerformanceStats['avg_attendance_rate'] ?? 0.0),
                const Color(0xFFF59E0B),
              ),
            ),
            const SizedBox(width: 10),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade100, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
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
              fontSize: 11,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: accentColor,
              height: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6B46C1), Color(0xFF8B5CF6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6B46C1).withOpacity(0.2),
            blurRadius: 10,
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
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  DateFormat('MMM dd, yyyy').format(DateTime.now()),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
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
                width: 0.5,
                height: 30,
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
            fontSize: 9,
            color: Colors.white.withOpacity(0.7),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 9,
            color: Colors.white.withOpacity(0.6),
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
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: Colors.black87,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 10),
        Container(
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
            fontSize: isHighlighted ? 16 : 14,
            fontWeight: isHighlighted ? FontWeight.bold : FontWeight.w600,
            color: isHighlighted ? const Color(0xFF10B981) : Colors.black87,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey.shade500,
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
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
                letterSpacing: -0.2,
              ),
            ),
            TextButton(
              onPressed: () {},
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF6B46C1),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: 10),
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
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: const ValueKey('member_search_field'),
              controller: _searchController,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search...',
                hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: Icon(Icons.search, size: 20, color: Colors.grey.shade400),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey.shade100),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              onChanged: (value) {
                // Simple debounce/delay to avoid too many requests
                Future.delayed(const Duration(milliseconds: 600), () {
                  if (value == _searchController.text) {
                    _loadOrganizationMembersOptimized();
                  }
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade100),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedDepartment,
                  isDense: true,
                  icon: Icon(Icons.filter_list, size: 18, color: Colors.grey.shade500),
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  items: _departments.map((dept) {
                    return DropdownMenuItem(
                      value: dept,
                      child: Text(dept, overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedDepartment = value);
                      _loadOrganizationMembersOptimized();
                    }
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersList() {
    final filteredMembers = _organizationMembers;
    final isFiltering = _searchController.text.isNotEmpty || _selectedDepartment != 'All';
    
    if (_isContentLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(strokeWidth: 3),
              SizedBox(height: 16),
              Text('Searching...', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    if (filteredMembers.isEmpty) {
      return _buildEmptyState(isFiltering);
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            itemCount: filteredMembers.length,
            itemBuilder: (context, index) {
              return _buildMemberCard(filteredMembers[index]);
            },
          ),
        ),
        _buildPaginationControls(),
      ],
    );
  }

  Widget _buildEmptyState(bool isFiltering) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              isFiltering ? 'No members found' : 'No members available',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaginationControls() {
    if (_totalMembers == 0 && !_isContentLoading) return const SizedBox.shrink();
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade100)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Previous Button
          SizedBox(
            width: 100,
            child: OutlinedButton(
              onPressed: _currentPage > 1 ? () => _loadOrganizationMembersOptimized(page: _currentPage - 1) : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                side: BorderSide(color: _currentPage > 1 ? primaryColor : Colors.grey.shade200),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chevron_left, size: 18, color: _currentPage > 1 ? primaryColor : Colors.grey),
                  const SizedBox(width: 4),
                  Text('Prev', style: TextStyle(color: _currentPage > 1 ? primaryColor : Colors.grey, fontSize: 13)),
                ],
              ),
            ),
          ),
          
          // Page Info (Centered)
          Expanded(
            child: InkWell(
              onTap: _showJumpToPageDialog,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Page $_currentPage of $_totalPages',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '$_totalMembers Total Members',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          
          // Next Button
          SizedBox(
            width: 100,
            child: OutlinedButton(
              onPressed: _currentPage < _totalPages ? () => _loadOrganizationMembersOptimized(page: _currentPage + 1) : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                side: BorderSide(color: _currentPage < _totalPages ? primaryColor : Colors.grey.shade200),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Next', style: TextStyle(color: _currentPage < _totalPages ? primaryColor : Colors.grey, fontSize: 13)),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: _currentPage < _totalPages ? primaryColor : Colors.grey),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showJumpToPageDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to Page', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Enter page number (1-$_totalPages):', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'e.g. 49',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page != null && page >= 1 && page <= _totalPages) {
                Navigator.pop(context);
                _loadOrganizationMembersOptimized(page: page);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Please enter a valid page between 1 and $_totalPages')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Go'),
          ),
        ],
      ),
    );
  }


  Widget _buildMemberCard(Map<String, dynamic> member) {
    final department = member['departments'] as Map<String, dynamic>?;
    final position = member['positions'] as Map<String, dynamic>?;
    final isActive = member['status'] != 'inactive';
    
    // Check biometric data - it's an array of objects
    final biometricData = member['biometric_data'] as List?;
    final hasBiometric = biometricData != null && 
                         biometricData.isNotEmpty &&
                         biometricData.any((template) => 
                           template is Map && 
                           template['is_active'] == true && 
                           template['biometric_type'] == 'face_recognition'
                         );
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade100, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _showMemberDetail(member),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Stack(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey.shade100,
                      border: Border.all(color: Colors.grey.shade50, width: 2),
                    ),
                    child: ClipOval(
                      child: _getMemberPhotoUrl(member) != null
                          ? CachedNetworkImage(
                              imageUrl: _getMemberPhotoUrl(member)!,
                              fit: BoxFit.cover,
                              placeholder: (context, url) => Container(color: Colors.grey.shade50),
                              errorWidget: (context, url, error) => Icon(Icons.person, color: Colors.grey.shade400, size: 24),
                            )
                          : Icon(Icons.person, color: Colors.grey.shade400, size: 24),
                    ),
                  ),
                  if (isActive)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _getMemberName(member),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                        letterSpacing: -0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      department?['name'] ?? 'No Dept',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: hasBiometric 
                      ? const Color(0xFF10B981).withOpacity(0.1)
                      : Colors.grey.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: hasBiometric
                        ? const Color(0xFF10B981).withOpacity(0.3)
                        : Colors.grey.withOpacity(0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasBiometric 
                          ? Icons.face_retouching_natural
                          : Icons.face_retouching_off,
                      size: 12,
                      color: hasBiometric 
                          ? const Color(0xFF10B981)
                          : Colors.grey.shade600,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      hasBiometric ? 'Face' : 'No Face',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: hasBiometric 
                            ? const Color(0xFF10B981)
                            : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              _buildCompactRoleBadge(member),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.grey.shade300,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactRoleBadge(Map<String, dynamic> member) {
    final roleName = (member['role_name'] ?? 'Member').toString();
    final roleCode = member['role_code'];
    
    MaterialColor color;
    if (roleCode == 'P001') {
      color = Colors.blue;
    } else if (roleCode == 'A001' || roleCode == 'SA001') {
      color = Colors.purple;
    } else {
      color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        roleName.toUpperCase(),
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color.shade800,
          letterSpacing: 0.2,
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
              child: ElevatedButton.icon(
                onPressed: () => _showRegistrationOptions(member),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.face_retouching_natural),
                label: const Text(
                  'Register Face',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF6B46C1),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Color(0xFF6B46C1)),
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

  void _showRegistrationOptions(Map<String, dynamic> member) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Face Registration',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pilih metode registrasi wajah sesuai kebutuhan.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.2)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Row(
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Color(0xFF10B981)),
                      SizedBox(width: 6),
                      Text('Live Camera: 5 Sudut (Akurasi Tinggi)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                   ),
                   SizedBox(height: 4),
                   Row(
                    children: [
                      Icon(Icons.check_circle, size: 14, color: Color(0xFF6B46C1)),
                      SizedBox(width: 6),
                      Text('Upload Photo: 1 Foto Depan (Praktis)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                   ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildOptionCard(
                    'Live Camera',
                    Icons.face_retouching_natural,
                    const Color(0xFF10B981),
                    () {
                      Navigator.pop(context); // Close options
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FaceRegistrationPage(
                            organizationMemberId: member['id'],
                          ),
                        ),
                      ).then((refresh) {
                        if (refresh == true) _loadOrganizationMembersOptimized();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildOptionCard(
                    'Upload Photos',
                    Icons.photo_library_rounded,
                    const Color(0xFF6B46C1),
                    () {
                      Navigator.pop(context);
                      _registerFaceFromSinglePhoto(member);
                    },
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

  Widget _buildOptionCard(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: color.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.1)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 12),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _registerFaceFromSinglePhoto(Map<String, dynamic> member) async {
    final faceService = FaceRecognitionTFLiteService();
    final organizationMemberId = member['id'] as int?;
    
    if (organizationMemberId == null) return;

    try {
      await faceService.initialize();
      final ImagePicker picker = ImagePicker();

      // Single photo picker
      final XFile? image = await showDialog<XFile?>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Pilih Foto Wajah Depan'),
          content: const Text(
            'Pastikan foto:\n'
            '1. Wajah menghadap lurus ke depan\n'
            '2. Pencahayaan terang & jelas\n'
            '3. Tidak memakai masker/kacamata gelap',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context), 
              child: const Text('Batal')
            ),
            ElevatedButton(
              onPressed: () async {
                final img = await picker.pickImage(source: ImageSource.gallery, imageQuality: 100);
                if (mounted) Navigator.pop(context, img);
              },
              child: const Text('Buka Galeri'),
            ),
          ],
        ),
      );

      if (image == null) return; // User cancelled

      if (!mounted) return;
      _showProcessingOverlay(context, 'Memproses foto & Menyimpan data...');

      try {
        final faceTemplate = await faceService.extractFaceFeatures(
          image.path,
          allowSidePose: false, // Strict check for single upload
        );

        // Quality check
        double qualityScore = (faceTemplate['qualityScore'] as num?)?.toDouble() ?? 0.0;
        if (qualityScore < 0.65) {
            throw Exception('Kualitas foto kurang baik (Score: ${(qualityScore*100).toInt()}%). Gunakan foto yang lebih jelas.');
        }

        final biometricService = BiometricService();
        final storageService = SupabaseStorageService();

        // 1. Upload Photo
        final processedFile = File(image.path); // Or add compression if needed
        await storageService.uploadFaceTemplate(processedFile, organizationMemberId);
        
        // 2. Register Template to DB (Version 5 - Single)
        await biometricService.registerFaceTemplate(
          organizationMemberId: organizationMemberId,
          faceTemplate: faceTemplate,
        );

        if (mounted) {
          Navigator.of(context).pop(); // Close processing overlay safely
          _showSuccessSnackBar('Wajah ${_getMemberName(member)} berhasil didaftarkan (Single Mode)!');
          _loadOrganizationMembersOptimized();
        }

      } catch (e) {
        if (mounted) Navigator.of(context).pop(); // Close processing overlay on error
        _showErrorDialog('Gagal: $e');
      }

    } catch (e) {
      debugPrint('Single-photo reg error: $e');
      // If overlay was shown, ensure it's popped (though the inner catch handles most)
       // Check if we are still in a dialog context if needed, but safest is to rely on user report or inner catch.
      if (mounted) _showErrorDialog('Terjadi kesalahan sistem: $e');
    } finally {
      faceService.dispose();
    }
  }



  void _showProcessingOverlay(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(message),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Gagal'),
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  // Legacy kept for now but unused in flow
  Future<void> _registerFaceFromPhoto(Map<String, dynamic> member, {required ImageSource source}) async {}

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
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
            _buildFilterSection(),
            const SizedBox(height: 16),
            if (_performanceTrend.isNotEmpty) ...[
              _buildPerformanceTrendChart(),
              const SizedBox(height: 20),
            ],
            _buildTopPerformers(),
            const SizedBox(height: 20),
            _buildLowPerformers(),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterSection() {
    return Container(
      padding: const EdgeInsets.all(12),
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
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Time Period',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade100),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedTimePeriod,
                      isExpanded: true,
                      isDense: true,
                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                      items: ['Today', 'This Week', 'This Month', 'Last Month']
                          .map((period) => DropdownMenuItem(
                                value: period,
                                child: Text(period),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedTimePeriod = value);
                          _applyFilters();
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sort By',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade100),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedSortBy,
                      isExpanded: true,
                      isDense: true,
                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                      items: ['Total Attendance', 'Work Hours']
                          .map((sort) => DropdownMenuItem(
                                value: sort,
                                child: Text(sort),
                              ))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedSortBy = value);
                          _applyFilters();
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceTrendChart() {
    return Container(
      padding: const EdgeInsets.all(12),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Performance Trend',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.black87,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: _isLoadingTrend
                ? const Center(child: CircularProgressIndicator())
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: 0.2,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade200,
                            strokeWidth: 1,
                          );
                        },
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            getTitlesWidget: (value, meta) {
                              if (value == 0 || value == 0.5 || value == 1.0) {
                                return Text(
                                  '${(value * 100).toInt()}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey.shade400,
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: 1, 
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 || index >= _performanceTrend.length) {
                                return const SizedBox.shrink();
                              }
                              
                              // Logic to show labels sparsely (every 7 points if many, or start/end)
                              final totalPoints = _performanceTrend.length;
                              bool showLabel = false;
                              
                              if (totalPoints <= 8) {
                                // For few points (like a week), show every 2nd or 3rd to keep it clean
                                showLabel = index % 2 == 0 || index == totalPoints - 1;
                              } else {
                                // For more points, show once a week (every 7)
                                showLabel = index % 7 == 0 || index == totalPoints - 1;
                              }

                              if (!showLabel) return const SizedBox.shrink();

                              final trendItem = _performanceTrend[index];
                              final period = trendItem['period'] as String;
                              
                              String label = '';
                              try {
                                final date = DateTime.parse(period.length == 7 ? '$period-01' : period);
                                // Format as MM/DD following the concept image
                                final month = date.month.toString().padLeft(2, '0');
                                final day = date.day.toString().padLeft(2, '0');
                                label = '$month/$day';
                              } catch (e) {
                                label = period.split('-').last;
                              }

                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      borderData: FlBorderData(show: false),
                      minY: 0,
                      maxY: 1,
                      lineBarsData: [
                        // Attendance rate line
                        LineChartBarData(
                          spots: _performanceTrend.asMap().entries.map((entry) {
                            return FlSpot(
                              entry.key.toDouble(),
                              entry.value['attendance_rate'] as double,
                            );
                          }).toList(),
                          isCurved: true,
                          curveSmoothness: 0.35,
                          color: const Color(0xFF03A9F4), // Light blue like concept
                          barWidth: 2,
                          dotData: const FlDotData(show: false), // Clean look, no dots
                        ),
                        // Work Hours line (normalized 0-12h to 0-1.0)
                        LineChartBarData(
                          spots: _performanceTrend.asMap().entries.map((entry) {
                            final hours = entry.value['avg_work_hours'] as double? ?? 0.0;
                            final normalized = (hours / 12).clamp(0.0, 1.0);
                            return FlSpot(
                              entry.key.toDouble(),
                              normalized,
                            );
                          }).toList(),
                          isCurved: true,
                          curveSmoothness: 0.35,
                          color: const Color(0xFF2E7D32), // Dark green like concept
                          barWidth: 2,
                          dotData: const FlDotData(show: false), // No dots
                        ),
                      ],
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (touchedSpot) => Colors.blueGrey.withOpacity(0.8),
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              if (spot.barIndex == 0) {
                                return LineTooltipItem(
                                  'Att: ${(spot.y * 100).toInt()}%',
                                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                );
                              } else {
                                final hours = (spot.y * 12); // Denormalize
                                return LineTooltipItem(
                                  'Work: ${hours.toStringAsFixed(1)}h',
                                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                );
                              }
                            }).toList();
                          },
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildChartLegend(Colors.green, 'Attendance'),
              const SizedBox(width: 16),
              _buildChartLegend(Colors.purple, 'Work Hours'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChartLegend(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 16,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }

  Future<void> _applyFilters() async {
    setState(() => _isLoadingPerformance = true);
    
    try {
      final organizationId = widget.memberData['organization_id'] as int;
      
      // Map time period to service parameter
      String timePeriod;
      switch (_selectedTimePeriod) {
        case 'Today':
          timePeriod = 'today';
          break;
        case 'This Week':
          timePeriod = 'week';
          break;
        case 'This Month':
          timePeriod = 'month';
          break;
        case 'Last Month':
          timePeriod = 'custom';
          break;
        default:
          timePeriod = 'month';
      }
      
      // Map sort by to service parameter
      String sortBy;
      if (_selectedSortBy == 'Total Attendance') {
        sortBy = 'total_attendance';
      } else {
        sortBy = 'work_hours';
      }
      
      final filteredData = await _performanceService.getFilteredPerformance(
        organizationId,
        timePeriod: timePeriod,
        sortBy: sortBy,
      );
      
      // Split into top and low performers
      final topPerformers = filteredData.take(5).toList();
      final lowPerformers = filteredData.length > 5
          ? filteredData.skip(filteredData.length - 5).toList()
          : <Map<String, dynamic>>[];
      
      setState(() {
        _topPerformers = topPerformers;
        _lowPerformers = lowPerformers;
        _isLoadingPerformance = false;
      });
      
      // Load trend data
      _loadPerformanceTrend();
      
      // Load achievements
      _loadAchievements();
    } catch (e) {
      debugPrint('Error applying filters: $e');
      setState(() => _isLoadingPerformance = false);
    }
  }

  Future<void> _loadPerformanceTrend() async {
    setState(() => _isLoadingTrend = true);
    
    try {
      final organizationId = widget.memberData['organization_id'] as int;
      final now = DateTime.now();
      
      String period = 'monthly';
      DateTime startDate;
      
      switch (_selectedTimePeriod) {
        case 'Today':
        case 'This Week':
          period = 'daily';
          // Start from Monday of this week
          startDate = now.subtract(Duration(days: now.weekday - 1));
          break;
        case 'This Month':
          period = 'weekly';
          startDate = DateTime(now.year, now.month, 1);
          break;
        case 'Last Month':
          period = 'weekly';
          startDate = DateTime(now.year, now.month - 1, 1);
          break;
        default:
          period = 'weekly';
          startDate = now.subtract(const Duration(days: 30));
      }
      
      final trendData = await _performanceService.getPerformanceTrend(
        organizationId,
        period: period,
        startDate: startDate,
      );
      
      setState(() {
        _performanceTrend = trendData;
        _isLoadingTrend = false;
      });
    } catch (e) {
      debugPrint('Error loading trend: $e');
      setState(() => _isLoadingTrend = false);
    }
  }

  Future<void> _loadAchievements() async {
    try {
      final organizationId = widget.memberData['organization_id'] as int;
      
      final achievements = await _performanceService.calculateAchievements(
        organizationId,
      );
      
      setState(() {
        _memberAchievements = achievements;
      });
    } catch (e) {
      debugPrint('Error loading achievements: $e');
    }
  }


  Widget _buildTopPerformers() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 3,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Top Performers',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'This Month',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.green.shade700,
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
          child: _isLoadingPerformance
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _topPerformers.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.trending_up, size: 48, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text(
                              'No top performers yet',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
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
            Container(
              width: 3,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.orange.shade700,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Needs Attention',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'This Month',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.orange.shade700,
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
          child: _isLoadingPerformance
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _lowPerformers.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.trending_down, size: 48, color: Colors.grey.shade300),
                            const SizedBox(height: 12),
                            Text(
                              'No members need attention',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
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
    final accentColor = isTopPerformer ? Colors.green : Colors.orange.shade700;
    // New metrics variables
    final totalAttendance = performance['present_days'] as num? ?? 0;
    final totalWorkMinutes = performance['total_work_minutes'] as num? ?? 0;
    final workHours = (totalWorkMinutes.toDouble() / 60).toStringAsFixed(1);
    final productivityScore = performance['productivity_score'] as double? ?? 0.0;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: accentColor.withOpacity(0.1),
          width: 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '#$rank',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: accentColor,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _getMemberName(member),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                              letterSpacing: -0.2,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          _buildAchievementBadges(member['id'] as int),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Score: ${_formatPercentage(productivityScore)}',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Attendance',
                              style: TextStyle(fontSize: 9, color: Colors.blue.shade600, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$totalAttendance Logs',
                              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.blue.shade900, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Work Hours',
                              style: TextStyle(fontSize: 9, color: Colors.purple.shade600, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$workHours Hrs',
                              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.purple.shade900, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
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

  Widget _buildMetricBar(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              _formatPercentage(value),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade800,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: value,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(color),
            minHeight: 6,
          ),
        ),
      ],
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
