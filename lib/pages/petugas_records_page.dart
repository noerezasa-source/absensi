// Part 1: Imports and Class Definition
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/attendance_record.dart';
import '../services/attendance_service.dart';
import '../helpers/timezone_helper.dart';
import '../services/role_service.dart';
import '../widgets/petugas_bottom_nav.dart';
import 'petugas_dashboard.dart';
import 'petugas_members_page.dart';
import 'petugas_profile_page.dart';

class PetugasRecordsPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasRecordsPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<PetugasRecordsPage> createState() => _PetugasRecordsPageState();
}

class _PetugasRecordsPageState extends State<PetugasRecordsPage>
    with SingleTickerProviderStateMixin {
  static const Color primaryColor = Color(0xFF6B46C1);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFF1F2937);

  final AttendanceService _attendanceService = AttendanceService();
  final RoleService _roleService = RoleService();
  final supabase = Supabase.instance.client;

  bool _isLoading = true;
  bool _isInitialized = false;
  String? _errorMessage;
  int _currentNavIndex = 2;

  Map<String, dynamic>? _organization;
  Map<String, dynamic>? _userProfile;
  String _organizationTimezone = 'Asia/Jakarta';

  List<Map<String, dynamic>> _allAttendanceRecords = [];
  List<Map<String, dynamic>> _filteredRecords = [];
  Map<int, String> _deviceLocations = {};
  Map<String, dynamic> _memberProfiles = {};

  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  CalendarFormat _calendarFormat = CalendarFormat.month;
  late int _selectedMonth;
  late int _selectedYear;

  List<Map<String, dynamic>> _organizationMembers = [];
  int? _selectedMemberId; // Filter by member (null = all members)
  String _searchQuery = '';

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    final now = DateTime.now();
    _selectedMonth = now.month;
    _selectedYear = now.year;
    _selectedDay = now;
    _focusedDay = now;
    _userProfile = widget.userProfile;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeData();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // Initialize all data
  Future<void> _initializeData() async {
    if (!mounted || _isInitialized) return;

    try {
      await _loadOrganizationData();
      await _loadOrganizationMembers();
      await _loadDeviceLocations();
      await _loadAttendanceRecords();

      if (mounted) {
        setState(() {
          _isInitialized = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error initializing data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isInitialized = true;
          _errorMessage = 'Failed to initialize: $e';
        });
      }
    }
  }

  // Load organization data
  Future<void> _loadOrganizationData() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final org = await supabase
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

  // Load all organization members
  Future<void> _loadOrganizationMembers() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final response = await supabase
          .from('organization_members')
          .select('''
            id,
            employee_id,
            user_id,
            user_profiles!inner(
              id,
              display_name,
              first_name,
              last_name,
              profile_photo_url
            )
          ''')
          .eq('organization_id', organizationId)
          .eq('is_active', true)
          .order('employee_id');

      if (mounted && response != null) {
        setState(() {
          _organizationMembers = List<Map<String, dynamic>>.from(response);

          // Cache member profiles for quick lookup
          for (final member in response) {
            final profile = member['user_profiles'] as Map<String, dynamic>?;
            if (profile != null) {
              _memberProfiles[member['id'].toString()] = profile;
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading organization members: $e');
    }
  }

  // Load device locations
  Future<void> _loadDeviceLocations() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final response = await supabase
          .from('attendance_devices')
          .select('id, location, device_name')
          .eq('organization_id', organizationId);

      if (response != null) {
        final Map<int, String> locations = {};
        for (final device in response as List) {
          final deviceId = device['id'] as int;
          final locationName =
              (device['location'] as String?)?.isNotEmpty == true
              ? device['location']
              : device['device_name'];
          locations[deviceId] = locationName ?? 'Unknown Device';
        }

        if (mounted) {
          setState(() {
            _deviceLocations = locations;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading device locations: $e');
    }
  }
  // Part 2: Data Loading and Filtering Methods

  // Load attendance records for all members
  Future<void> _loadAttendanceRecords() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    setState(() => _isLoading = true);

    try {
      final startDate = DateTime(_selectedYear, _selectedMonth, 1);
      final endDate = DateTime(
        _selectedYear,
        _selectedMonth + 1,
        0,
        23,
        59,
        59,
      );
      final startDateStr = startDate.toIso8601String().split('T')[0];
      final endDateStr = endDate.toIso8601String().split('T')[0];

      final response = await supabase
          .from('attendance_records')
          .select('''
            *,
            organization_members!inner(
              id,
              employee_id,
              user_profiles!inner(
                display_name,
                first_name,
                last_name,
                profile_photo_url
              )
            )
          ''')
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr)
          .order('attendance_date', ascending: false)
          .order('organization_member_id');

      if (mounted && response != null) {
        setState(() {
          _allAttendanceRecords = List<Map<String, dynamic>>.from(response);
          _applyFilters();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading attendance records: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load attendance records: $e';
        });
      }
    }
  }

  // Apply filters to attendance records
  void _applyFilters() {
    setState(() {
      _filteredRecords = _allAttendanceRecords.where((record) {
        // Filter by selected member
        if (_selectedMemberId != null) {
          if (record['organization_member_id'] != _selectedMemberId) {
            return false;
          }
        }

        // Filter by search query
        if (_searchQuery.isNotEmpty) {
          final memberName = _getMemberName(record).toLowerCase();
          final employeeId = _getEmployeeId(record).toLowerCase();
          final query = _searchQuery.toLowerCase();

          if (!memberName.contains(query) && !employeeId.contains(query)) {
            return false;
          }
        }

        return true;
      }).toList();
    });
  }

  // Helper methods for getting member information
  String? _getDeviceLocationName(int? deviceId) {
    if (deviceId == null) return null;
    return _deviceLocations[deviceId];
  }

  String _getMemberName(Map<String, dynamic> record) {
    final member = record['organization_members'] as Map<String, dynamic>?;
    final profile = member?['user_profiles'] as Map<String, dynamic>?;

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

  String _getEmployeeId(Map<String, dynamic> record) {
    final member = record['organization_members'] as Map<String, dynamic>?;
    return member?['employee_id'] as String? ?? '';
  }

  String? _getMemberPhotoUrl(Map<String, dynamic> record) {
    final member = record['organization_members'] as Map<String, dynamic>?;
    final profile = member?['user_profiles'] as Map<String, dynamic>?;
    final photoPath = profile?['profile_photo_url'] as String?;

    if (photoPath == null || photoPath.trim().isEmpty) return null;

    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }

    return supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  Future<void> refreshData() async {
    await _loadAttendanceRecords();
  }

  void _handleNavigation(int index) {
    if (index == _currentNavIndex) return;

    setState(() {
      _currentNavIndex = index;
    });

    switch (index) {
      case 0:
        // Home - kembali ke dashboard
        Navigator.popUntil(context, (route) => route.isFirst);
        break;
      case 1:
        // Member
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasMembersPage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: _userProfile ?? widget.userProfile,
            ),
          ),
        ).then((_) {
          if (mounted) {
            setState(() {
              _currentNavIndex = 2; // Kembali ke Records index
            });
          }
        });
        break;
      case 2:
        // Records - stay on current page
        break;
      case 3:
        // Profile - Navigate to Profile Page
        Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (context) => PetugasProfilePage(
              organizationMemberId: widget.organizationMemberId,
              memberData: widget.memberData,
              userProfile: _userProfile ?? widget.userProfile,
            ),
          ),
        ).then((_) {
          if (mounted) {
            setState(() {
              _currentNavIndex = 2; // Kembali ke Records index
            });
          }
        });
        break;
    }
  }

  // Calendar event methods
  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    final dateStr = DateFormat('yyyy-MM-dd').format(day);
    return _filteredRecords.where((record) {
      final attendanceDate = record['attendance_date'] as String? ?? '';
      return attendanceDate == dateStr;
    }).toList();
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!mounted) return;

    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });
  }

  String _getMonthName(int month) {
    final format = DateFormat.MMMM();
    return format.format(DateTime(2023, month));
  }

  String _formatTime(String? timeString) {
    if (timeString == null) return '--:--';

    try {
      final orgTime = TimezoneHelper.parseAndConvert(
        timeString,
        _organizationTimezone,
      );
      if (orgTime == null) return '--:--';
      return DateFormat('HH:mm').format(orgTime);
    } catch (e) {
      debugPrint('Error formatting time: $e');
      return '--:--';
    }
  }

  String _formatDateTime(String? dateTimeString) {
    if (dateTimeString == null) return '--';

    try {
      final orgTime = TimezoneHelper.parseAndConvert(
        dateTimeString,
        _organizationTimezone,
      );
      if (orgTime == null) return '--';
      return DateFormat('HH:mm:ss').format(orgTime);
    } catch (e) {
      debugPrint('Error formatting datetime: $e');
      return '--';
    }
  }

  String _formatFullDateTime(String? dateTimeString) {
    if (dateTimeString == null) return '--';

    try {
      final orgTime = TimezoneHelper.parseAndConvert(
        dateTimeString,
        _organizationTimezone,
      );
      if (orgTime == null) return '--';
      return DateFormat('dd MMM yyyy, HH:mm:ss').format(orgTime);
    } catch (e) {
      debugPrint('Error formatting full datetime: $e');
      return '--';
    }
  }

  String _getTimezoneDisplay() {
    if (_organizationTimezone.toLowerCase().contains('jakarta') ||
        _organizationTimezone.toLowerCase() == 'wib') {
      return 'WIB (GMT+7)';
    } else if (_organizationTimezone.toLowerCase().contains('makassar') ||
        _organizationTimezone.toLowerCase() == 'wita') {
      return 'WITA (GMT+8)';
    } else if (_organizationTimezone.toLowerCase().contains('jayapura') ||
        _organizationTimezone.toLowerCase() == 'wit') {
      return 'WIT (GMT+9)';
    } else if (_organizationTimezone.toLowerCase() == 'utc') {
      return 'UTC (GMT+0)';
    }
    return _organizationTimezone;
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'present':
        return successColor;
      case 'absent':
        return errorColor;
      case 'late':
        return warningColor;
      default:
        return Colors.grey;
    }
  }

  // Part 3: Build Methods - Main UI

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFFF5F5F5),
        body: _buildLoadingState(),
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        // onAttendanceTap: tidak diberikan, jadi tombol attendance tidak muncul
      ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: RefreshIndicator(
        onRefresh: refreshData,
        color: primaryColor,
        child: NestedScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverToBoxAdapter(child: _buildHeader()),
              SliverToBoxAdapter(child: _buildFilterSection()),
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
                      Tab(text: 'Calendar View'),
                      Tab(text: 'List View'),
                    ],
                  ),
                ),
              ),
            ];
          },
          body: TabBarView(
            controller: _tabController,
            children: [_buildCalendarTab(), _buildListTab()],
          ),
        ),
      ),
        bottomNavigationBar: PetugasBottomNav(
          currentIndex: _currentNavIndex,
          onNavigationTap: _handleNavigation,
          // onAttendanceTap: tidak diberikan, jadi tombol attendance tidak muncul
        ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(child: CircularProgressIndicator(color: primaryColor));
  }

  Widget _buildHeader() {
    final now = DateTime.now();
    final dateFormat = DateFormat('EEEE, dd MMM yyyy');

    return Container(
      width: double.infinity,
// Header reduction
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 12), // Reduced padding
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [backgroundColor, Color(0xFF374151)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20), // Reduced radius
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _buildOrgLogo(),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attendance Records',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18, // Reduced from 22
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _organization?['name'] ?? 'Unknown Organization',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 12, // Reduced from 13
                        fontWeight: FontWeight.w400,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8), // Reduced gap
          Text(
            dateFormat.format(now),
            style: TextStyle(
              color: Colors.white.withOpacity(0.75),
              fontSize: 12, // Reduced from 13
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrgLogo() {
    return Container(
      width: 40, // Reduced from 50
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10), // Reduced radius
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
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                _organization!['logo_url']!,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return _buildDefaultLogo();
                },
              ),
            )
          : _buildDefaultLogo(),
    );
  }

  Widget _buildDefaultLogo() {
    return Container(
      width: 40, // Reduced from 50
      height: 40,
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.business, color: Colors.white, size: 24), // Reduced size
    );
  }

  Widget _buildFilterSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // Reduced margin
      padding: const EdgeInsets.all(12), // Reduced padding
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
            'Filters',
            style: TextStyle(
              fontSize: 14, // Reduced from 16
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8), // Reduced gap

          // Month Selector
          _buildMonthSelector(),
          const SizedBox(height: 8),

          // Member Filter Dropdown
          _buildMemberFilter(),
          const SizedBox(height: 8),

          // Search Field
          _buildSearchField(),

          // Summary Stats
          if (_filteredRecords.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildFilterStats(),
          ],
        ],
      ),
    );
  }

  Widget _buildMonthSelector() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8), // Reduced radius
      child: InkWell(
        onTap: _showMonthYearPicker,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), // Reduced padding
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.calendar_today, color: primaryColor, size: 16), // Reduced size
              const SizedBox(width: 8),
              Text(
                '${_getMonthName(_selectedMonth)} $_selectedYear',
                style: const TextStyle(
                  fontSize: 14, // Reduced from 16
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down,
                color: Colors.grey.shade600,
                size: 18, // Reduced size
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemberFilter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0), // Reduced vertical padding
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: _selectedMemberId,
          isExpanded: true,
          icon: Icon(Icons.arrow_drop_down, color: Colors.grey.shade600, size: 20), // Icon size
          hint: Row(
            children: [
              Icon(Icons.person, color: primaryColor, size: 16), // Reduced size
              const SizedBox(width: 8),
              const Text('All Members', style: TextStyle(fontSize: 13)), // Reduced text
            ],
          ),
          items: [
            DropdownMenuItem<int?>(
              value: null,
              child: Row(
                children: [
                  Icon(Icons.people, color: primaryColor, size: 16),
                  const SizedBox(width: 8),
                  const Text('All Members', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            ..._organizationMembers.map((member) {
              final profile = member['user_profiles'] as Map<String, dynamic>?;
              final displayName =
                  profile?['display_name'] as String? ??
                  '${profile?['first_name'] ?? ''} ${profile?['last_name'] ?? ''}'
                      .trim();
              final employeeId = member['employee_id'] as String? ?? '';

              return DropdownMenuItem<int?>(
                value: member['id'] as int,
                child: Row(
                  children: [
                    Icon(Icons.person, color: Colors.grey.shade600, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        employeeId.isNotEmpty
                            ? '$displayName ($employeeId)'
                            : displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13), // Reduced text
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
          onChanged: (value) {
            setState(() {
              _selectedMemberId = value;
              _applyFilters();
            });
          },
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      style: const TextStyle(fontSize: 13), // Reduced size
      decoration: InputDecoration(
        hintText: 'Search by name or employee ID',
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        prefixIcon: Icon(Icons.search, color: primaryColor, size: 20),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                    _applyFilters();
                  });
                },
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8, // Reduced padding
        ),
        isDense: true,
      ),
      onChanged: (value) {
        setState(() {
          _searchQuery = value;
          _applyFilters();
        });
      },
    );
  }

  Widget _buildFilterStats() {
    final presentCount = _filteredRecords
        .where((r) => r['status'] == 'present')
        .length;
    final absentCount = _filteredRecords
        .where((r) => r['status'] == 'absent')
        .length;
    final lateCount = _filteredRecords
        .where((r) => (r['late_minutes'] as int? ?? 0) > 0)
        .length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: primaryColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem('Present', presentCount, successColor),
          _buildStatItem('Absent', absentCount, errorColor),
          _buildStatItem('Late', lateCount, warningColor),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }
  // Part 4: Calendar and List Views

  Widget _buildCalendarTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        children: [
          _buildCalendarSection(),
          _buildCalendarEvents(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCalendarSection() {
    return Container(
      margin: const EdgeInsets.all(12), // Reduced margin
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
            locale: 'en_US',
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            eventLoader: _getEventsForDay,
            startingDayOfWeek: StartingDayOfWeek.monday,
            rowHeight: 42, // Reduced row height
            daysOfWeekHeight: 40,
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
              cellMargin: const EdgeInsets.all(4), // Reduced margin
              defaultTextStyle: const TextStyle(fontSize: 13), // Reduced text
              weekendTextStyle: const TextStyle(fontSize: 13, color: Colors.red),
              selectedDecoration: BoxDecoration(
                color: primaryColor,
                shape: BoxShape.circle,
              ),
              todayDecoration: BoxDecoration(
                color: primaryColor.withOpacity(0.6),
                shape: BoxShape.circle,
              ),
              markersMaxCount: 3,
              markerDecoration: const BoxDecoration(
                color: Colors.orange,
                shape: BoxShape.circle,
              ),
              markerSize: 5,
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: true,
              titleCentered: true,
              formatButtonDecoration: BoxDecoration(
                color: primaryColor,
                borderRadius: BorderRadius.circular(8),
              ),
              formatButtonTextStyle: const TextStyle(
                color: Colors.white,
                fontSize: 11, // Reduced size
              ),
              titleTextStyle: const TextStyle(
                fontSize: 14, // Reduced size
                fontWeight: FontWeight.w600,
              ),
              leftChevronIcon: const Icon(Icons.chevron_left, size: 20),
              rightChevronIcon: const Icon(Icons.chevron_right, size: 20),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildCalendarEvents() {
    final events = _getEventsForDay(_selectedDay);

    if (events.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(24), // Reduced padding
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12), // Reduced radius
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
              Icon(Icons.event_busy, color: Colors.grey.shade300, size: 32), // Reduced size
              const SizedBox(height: 8),
              Text(
                'No attendance data',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13, // Reduced size
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('dd MMM yyyy').format(_selectedDay),
                style: TextStyle(color: Colors.grey.shade400, fontSize: 11), // Reduced size
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12), // Reduced radius
        boxShadow: [
          BoxShadow(
            color: primaryColor.withOpacity(0.08),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), // Reduced vertical padding (12->8)
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(0.05),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6), // Reduced padding (8->6)
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.event_note,
                    color: Colors.white,
                    size: 16, // Reduced size (18->16)
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Daily Events',
                        style: TextStyle(
                          fontSize: 14, // Reduced size (15->14)
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      Text(
                        DateFormat('EEE, dd MMM yyyy').format(_selectedDay),
                        style: TextStyle(
                          fontSize: 11, // Reduced size (12->11)
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ), // Reduced padding
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${events.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12, // Reduced size (13->12)
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), // Removed top padding (2->0)
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: events.length,
              separatorBuilder: (context, index) => const SizedBox(height: 0), // Removed gap (8->0) - relying on item margin
              itemBuilder: (context, index) {
                return _buildRecordListItem(events[index], isCompact: true);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Column(
        children: [_buildRecordsList(), const SizedBox(height: 24)],
      ),
    );
  }

  Widget _buildRecordsList() {
    if (_filteredRecords.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(12), // Reduced margin
        padding: const EdgeInsets.all(24), // Reduced padding
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12), // Reduced radius
        ),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.inbox_outlined, size: 32, color: Colors.grey.shade300), // Reduced size
              const SizedBox(height: 8),
              Text(
                'No records found',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13, // Reduced size
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (_selectedMemberId != null || _searchQuery.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _selectedMemberId = null;
                      _searchQuery = '';
                      _applyFilters();
                    });
                  },
                  icon: const Icon(Icons.clear_all, size: 18), // Reduced size
                  label: const Text('Clear Filters', style: TextStyle(fontSize: 13)), // Reduced text
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.all(12), // Reduced margin
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12), // Reduced radius
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), // Reduced padding
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6), // Reduced padding
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.list_alt, color: primaryColor, size: 16), // Reduced size
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: const Text(
                    'Attendance Records',
                    style: TextStyle(
                      fontSize: 14, // Reduced size
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ), // Reduced padding
                  decoration: BoxDecoration(
                    color: primaryColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_filteredRecords.length}',
                    style: const TextStyle(
                      color: primaryColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12, // Reduced size
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), // Reduced padding
            itemCount: _filteredRecords.length,
            separatorBuilder: (context, index) => const SizedBox(height: 0), // Removed gap (handled by margin)
            itemBuilder: (context, index) {
              return _buildRecordListItem(_filteredRecords[index]);
            },
          ),
        ],
      ),
    );
  }



  Widget _buildRecordListItem(Map<String, dynamic> record, {bool isCompact = false}) {
    final memberName = _getMemberName(record);
    final employeeId = _getEmployeeId(record);
    final memberPhoto = _getMemberPhotoUrl(record);
    final attendanceDate = record['attendance_date'] as String? ?? '';
    final checkInTime = record['actual_check_in'] as String?;
    final checkOutTime = record['actual_check_out'] as String?;
    final status = record['status'] as String? ?? 'unknown';
    final lateMinutes = record['late_minutes'] as int?;

    final isPresent = status.toLowerCase() == 'present';
    final isLate = lateMinutes != null && lateMinutes > 0;

    DateTime? parsedDate;
    try {
      parsedDate = DateTime.parse(attendanceDate);
    } catch (_) {}

    if (isCompact) {
      return InkWell(
        onTap: () => _showRecordDetails(record),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade100, width: 1),
            ),
          ),
          child: Row(
            children: [
              _buildPhotoCircle(memberPhoto, isPresent, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: _buildRecordInfo(memberName, employeeId, parsedDate, attendanceDate, checkInTime, checkOutTime, isCompact: true),
              ),
              _buildStatusPill(status, isLate, lateMinutes),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _showRecordDetails(record),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                _buildPhotoCircle(memberPhoto, isPresent),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildRecordInfo(memberName, employeeId, parsedDate, attendanceDate, checkInTime, checkOutTime),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoCircle(String? photoUrl, bool isPresent, {double size = 44}) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.grey.shade100,
          border: Border.all(
            color: isPresent
                ? successColor.withOpacity(0.3)
                : errorColor.withOpacity(0.3),
            width: 2,
          ),
        ),
        child: ClipOval(
          child: photoUrl != null
              ? CachedNetworkImage(
                  imageUrl: photoUrl,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => Container(color: Colors.grey.shade50),
                  errorWidget: (context, url, error) => Icon(
                    Icons.person,
                    color: Colors.grey.shade400,
                    size: size * 0.6,
                  ),
                )
              : Icon(
                  Icons.person,
                  color: Colors.grey.shade400,
                  size: size * 0.6,
                ),
        ),
      );
  }

  Widget _buildRecordInfo(String name, String id, DateTime? date, String dateStr, String? inTime, String? outTime, {bool isCompact = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: isCompact ? 13 : 14,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            letterSpacing: -0.2,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (!isCompact) ...[
              Icon(Icons.calendar_today, size: 11, color: Colors.grey.shade500),
              const SizedBox(width: 4),
              Text(
                date != null ? DateFormat('dd MMM').format(date) : dateStr,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.access_time, size: 11, color: Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(
              _formatTime(inTime),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            if (outTime != null) ...[
              const SizedBox(width: 4),
              const Text('-', style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(width: 4),
              Text(
                _formatTime(outTime),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildStatusPill(String status, bool isLate, int? lateMinutes) {
     return Row(
       children: [
         if (isLate) 
           Container(
             padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
             margin: const EdgeInsets.only(right: 4),
             decoration: BoxDecoration(
               color: warningColor.withOpacity(0.1),
               borderRadius: BorderRadius.circular(4),
             ),
             child: Text(
               '+${lateMinutes}m',
               style: const TextStyle(fontSize: 10, color: warningColor, fontWeight: FontWeight.bold),
             ),
           ),
          _buildStatusChip(status),
       ],
     );
  }

  Widget _buildStatusChip(String status) {
    Color chipColor;
    String displayStatus;

    switch (status.toLowerCase()) {
      case 'present':
        chipColor = successColor;
        displayStatus = 'Present';
        break;
      case 'absent':
        chipColor = errorColor;
        displayStatus = 'Absent';
        break;
      case 'late':
        chipColor = warningColor;
        displayStatus = 'Late';
        break;
      default:
        chipColor = Colors.grey;
        displayStatus = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: chipColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        displayStatus,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: chipColor,
        ),
      ),
    );
  }
  // Part 5: Detail Dialog and Month Picker

  Future<void> _showRecordDetails(Map<String, dynamic> record) async {
    if (!mounted) return;

    final memberName = _getMemberName(record);
    final employeeId = _getEmployeeId(record);
    final memberPhoto = _getMemberPhotoUrl(record);
    final attendanceDate = record['attendance_date'] as String? ?? '';
    final checkInTime = record['actual_check_in'] as String?;
    final checkOutTime = record['actual_check_out'] as String?;
    final status = record['status'] as String? ?? 'unknown';
    final lateMinutes = record['late_minutes'] as int?;
    final earlyLeaveMinutes = record['early_leave_minutes'] as int?;
    final workDurationMinutes = record['work_duration_minutes'] as int?;
    final checkInDeviceId = record['check_in_device_id'] as int?;
    final checkOutDeviceId = record['check_out_device_id'] as int?;
    final checkInMethod = record['check_in_method'] as String?;
    final checkOutMethod = record['check_out_method'] as String?;

    final checkInLocation = _getDeviceLocationName(checkInDeviceId);
    final checkOutLocation = _getDeviceLocationName(checkOutDeviceId);

    showDialog(
      context: context,
      builder: (BuildContext context) {
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
                    // Header with photo and name
                    Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.grey.shade200,
                            border: Border.all(
                              color: _getStatusColor(status).withOpacity(0.3),
                              width: 2,
                            ),
                          ),
                          child: ClipOval(
                            child: memberPhoto != null
                                ? Image.network(
                                    memberPhoto,
                                    width: 60,
                                    height: 60,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Icon(
                                        Icons.person,
                                        color: Colors.grey.shade600,
                                        size: 30,
                                      );
                                    },
                                  )
                                : Icon(
                                    Icons.person,
                                    color: Colors.grey.shade600,
                                    size: 30,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                memberName,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (employeeId.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Employee ID: $employeeId',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              _buildStatusChip(status),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Timezone info banner
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.blue.withOpacity(0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.access_time,
                            size: 14,
                            color: Colors.blue.shade700,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Timezone: ${_getTimezoneDisplay()}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Details section
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primaryColor.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: primaryColor.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          _buildDetailRow(
                            Icons.calendar_today,
                            'Date',
                            attendanceDate,
                          ),
                          if (checkInTime != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.login,
                              'Check In Time',
                              _formatDateTime(checkInTime),
                            ),
                            if (checkInMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                'Check In Method',
                                checkInMethod,
                              ),
                            if (checkInLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                'Check In Location',
                                checkInLocation,
                              ),
                          ],
                          if (checkOutTime != null) ...[
                            const Divider(height: 20),
                            _buildDetailRow(
                              Icons.logout,
                              'Check Out Time',
                              _formatDateTime(checkOutTime),
                            ),
                            if (checkOutMethod != null)
                              _buildDetailRow(
                                Icons.fingerprint,
                                'Check Out Method',
                                checkOutMethod,
                              ),
                            if (checkOutLocation != null)
                              _buildDetailRow(
                                Icons.location_on,
                                'Check Out Location',
                                checkOutLocation,
                              ),
                          ],
                          if (workDurationMinutes != null ||
                              lateMinutes != null ||
                              earlyLeaveMinutes != null) ...[
                            const Divider(height: 20),
                            if (workDurationMinutes != null)
                              _buildDetailRow(
                                Icons.work,
                                'Work Duration',
                                '${(workDurationMinutes / 60).toStringAsFixed(1)} hours',
                              ),
                            if (lateMinutes != null && lateMinutes > 0)
                              _buildDetailRow(
                                Icons.schedule,
                                'Late',
                                '$lateMinutes minutes',
                                valueColor: warningColor,
                              ),
                            if (earlyLeaveMinutes != null &&
                                earlyLeaveMinutes > 0)
                              _buildDetailRow(
                                Icons.schedule,
                                'Early Leave',
                                '$earlyLeaveMinutes minutes',
                                valueColor: warningColor,
                              ),
                          ],
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

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: primaryColor),
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
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      color: valueColor ?? Colors.black87,
                      fontWeight: valueColor != null
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMonthYearPicker() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext context) {
        int tempYear = _selectedYear;
        int tempMonth = _selectedMonth;

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: () => setStateDialog(() => tempYear--),
                        icon: const Icon(
                          Icons.chevron_left,
                          color: primaryColor,
                        ),
                      ),
                      Text(
                        tempYear.toString(),
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      IconButton(
                        onPressed: () => setStateDialog(() => tempYear++),
                        icon: const Icon(
                          Icons.chevron_right,
                          color: primaryColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          childAspectRatio: 2,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: 12,
                    itemBuilder: (context, index) {
                      final month = index + 1;
                      final isSelected = month == tempMonth;
                      final monthName = _getMonthName(month);

                      return InkWell(
                        onTap: () => setStateDialog(() => tempMonth = month),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? primaryColor
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? primaryColor
                                  : Colors.grey.shade300,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              monthName.length >= 3
                                  ? monthName.substring(0, 3)
                                  : monthName,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? Colors.white
                                    : Colors.black87,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        if (!mounted) return;
                        setState(() {
                          _selectedMonth = tempMonth;
                          _selectedYear = tempYear;
                        });
                        Navigator.pop(context);
                        _loadAttendanceRecords();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Apply',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// SliverTabBarDelegate for pinned tab bar
class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  _SliverTabBarDelegate(this._tabBar);

  final TabBar _tabBar;

  @override
  double get minExtent => _tabBar.preferredSize.height;

  @override
  double get maxExtent => _tabBar.preferredSize.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: const Color(0xFFF8F9FA),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
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
        child: _tabBar,
      ),
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return false;
  }
}
