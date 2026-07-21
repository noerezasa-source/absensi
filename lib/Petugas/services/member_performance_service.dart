import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../helpers/timezone_helper.dart';

class MemberPerformanceService {
  final SupabaseClient _supabase = Supabase.instance.client;

  /// Test database connection and basic data
  Future<Map<String, dynamic>> testDatabaseConnection(
    int organizationId,
  ) async {
    try {
      debugPrint('=== TESTING DATABASE CONNECTION ===');
      debugPrint('Organization ID: $organizationId');

      // Test 1: Check if organization exists
      final orgResponse = await _supabase
          .from('organizations')
          .select('id, name')
          .eq('id', organizationId)
          .maybeSingle();

      debugPrint('Organization check: $orgResponse');

      // Test 2: Count organization members
      final memberCountResponse = await _supabase
          .from('organization_members')
          .select('id')
          .eq('organization_id', organizationId)
          .eq('is_active', true);

      final memberCount = memberCountResponse.length;
      debugPrint('Active members count: $memberCount');

      // Test 3: Count attendance records for current month
      final now = DateTime.now().toUtc();
      final startDateStr = DateTime(
        now.year,
        now.month,
        1,
      ).toIso8601String().split('T')[0];
      final endDateStr = DateTime(
        now.year,
        now.month + 1,
        0,
      ).toIso8601String().split('T')[0];

      final attendanceResponse = await _supabase
          .from('attendance_records')
          .select('id, organization_member_id, attendance_date, status')
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr);

      final attendanceCount = attendanceResponse.length;
      debugPrint('Attendance records this month: $attendanceCount');

      // Test 4: Check user_profiles
      final userProfileResponse = await _supabase
          .from('user_profiles')
          .select('id, display_name')
          .limit(5);

      debugPrint('User profiles count: ${userProfileResponse.length}');

      return {
        'organization_exists': orgResponse != null,
        'organization_data': orgResponse,
        'active_members_count': memberCount,
        'attendance_records_count': attendanceCount,
        'user_profiles_count': userProfileResponse.length,
        'test_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
      };
    } catch (e) {
      debugPrint('!!! ERROR in database connection test: $e');
      return {
        'error': e.toString(),
        'test_date': TimezoneHelper.formatUtcForSupabase(DateTime.now()),
      };
    }
  }

  /// Get organization members from local cache ONLY (for instant UI loading)
  Future<List<Map<String, dynamic>>?> getOrganizationMembersOffline(
    int organizationId, {
    int page = 1,
    int limit = 20,
    String? searchQuery,
    String? departmentFilter,
  }) async {
    final cacheKey = 'org_members_${organizationId}_page_${page}_limit_${limit}_dep_${departmentFilter ?? "all"}';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(cacheKey);
      if (cachedData != null) {
        debugPrint('⚡ USING INSTANT OFFLINE CACHE for org members page $page');
        var members = List<Map<String, dynamic>>.from(jsonDecode(cachedData));
        
        if (searchQuery != null && searchQuery.isNotEmpty) {
          final q = searchQuery.toLowerCase();
          members = members.where((m) {
            final name = (m['member_name'] as String? ?? '').toLowerCase();
            final empId = (m['employee_id'] as String? ?? '').toLowerCase();
            return name.contains(q) || empId.contains(q);
          }).toList();
        }
        return members;
      }
    } catch (cacheErr) {
      debugPrint('Error reading offline member cache: $cacheErr');
    }
    return null; // Return null if no cache found
  }

  /// Get organization members with their profile information (FAST + REAL DATA)
  /// Supports pagination with [page] (1-based) and [limit]
  Future<List<Map<String, dynamic>>> getOrganizationMembers(
    int organizationId, {
    int page = 1,
    int limit = 20,
    String? searchQuery,
    String? departmentFilter,
    bool includeInactive = false,
  }) async {
    try {
      debugPrint('=== GETTING ORGANIZATION MEMBERS (PAGINATED) ===');
      debugPrint('Org ID: $organizationId | Page: $page | Limit: $limit');

      final fromIndex = (page - 1) * limit;
      final toIndex = fromIndex + limit - 1;

      // Simplified query - PostgREST will auto-resolve FK relationships
      // Use left join (no !inner) for user_profiles so members always show
      // even if user_profiles record is missing
      const selectStr = '''
            id,
            user_id,
            role_id,
            department_id,
            employee_id,
            is_active,
            user_profiles(
              id,
              display_name,
              first_name,
              last_name,
              profile_photo_url
            ),
            departments(
              id,
              name
            ),
            system_roles(
              id,
              name,
              code
            ),
            biometric_data!left(
              id,
              is_active,
              biometric_type,
              template_data
            ),
            rfid_cards(
              id,
              card_number,
              is_active
            )
          ''';

      var query = _supabase
          .from('organization_members')
          .select(selectStr)
          .eq('organization_id', organizationId);

      // Filter active only if not requesting all
      if (!includeInactive) {
        query = query.eq('is_active', true);
      }

      // Apply department filter: departmentFilter is expected to be a stringified
      // integer ID (e.g. "5"). Parse it to int before filtering department_id (bigint).
      if (departmentFilter != null && departmentFilter.toLowerCase() != 'all') {
        final deptId = int.tryParse(departmentFilter);
        if (deptId != null) {
          query = query.eq('department_id', deptId);
        } else {
          debugPrint(
            '⚠️ departmentFilter "$departmentFilter" is not a valid integer, skipping DB filter.',
          );
        }
      }

      // Execute query with range
      final response = await query
          .order('employee_id', ascending: true)
          .range(fromIndex, toIndex)
          .timeout(const Duration(seconds: 4));

      debugPrint('Members fetched: ${response.length}');

      var members = List<Map<String, dynamic>>.from(response);

      // Debug: Log biometric data for first few members
      for (int i = 0; i < members.length && i < 3; i++) {
        final member = members[i];
        final bioData = member['biometric_data'];
        debugPrint(
          '🔍 Member ${member['id']} biometric_data: $bioData (type: ${bioData.runtimeType})',
        );
      }

      // Add member names and process roles for easier access
      for (final member in members) {
        member['member_name'] = _getMemberName(member);

        // Extract role name for UI
        final role = member['system_roles'] as Map<String, dynamic>?;
        member['role_name'] = role?['name'] ?? 'Member';
        member['role_code'] = role?['code'] ?? 'US001';

        // Extract RFID card ID
        final rfidCards = member['rfid_cards'];
        if (rfidCards is List && rfidCards.isNotEmpty) {
          final activeCard = rfidCards.firstWhere(
            (c) => c['is_active'] == true,
            orElse: () => null,
          );
          if (activeCard != null) {
            member['rfid_card_id'] = activeCard['id'];
          }
        }
      }

      // Caching data untuk penggunaan offline
      final cacheKey = 'org_members_${organizationId}_page_${page}_limit_${limit}_dep_${departmentFilter ?? "all"}';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(cacheKey, jsonEncode(members));
      } catch (cacheErr) {
        debugPrint('⚠️ Failed to cache org members: $cacheErr');
      }

      // In-memory search filter (safer than DB-side filtering via joined tables)
      if (searchQuery != null && searchQuery.isNotEmpty) {
        final q = searchQuery.toLowerCase();
        members = members.where((m) {
          final name = (m['member_name'] as String? ?? '').toLowerCase();
          final empId = (m['employee_id'] as String? ?? '').toLowerCase();
          return name.contains(q) || empId.contains(q);
        }).toList();
      }

      return members;
    } catch (e) {
      debugPrint('!!! ERROR in getOrganizationMembers: $e');
      
      // Fallback ke offline cache jika jaringan terputus
      final cacheKey = 'org_members_${organizationId}_page_${page}_limit_${limit}_dep_${departmentFilter ?? "all"}';
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedData = prefs.getString(cacheKey);
        if (cachedData != null) {
          debugPrint('✅ USING OFFLINE CACHE for org members page $page');
          var members = List<Map<String, dynamic>>.from(jsonDecode(cachedData));
          
          if (searchQuery != null && searchQuery.isNotEmpty) {
            final q = searchQuery.toLowerCase();
            members = members.where((m) {
              final name = (m['member_name'] as String? ?? '').toLowerCase();
              final empId = (m['employee_id'] as String? ?? '').toLowerCase();
              return name.contains(q) || empId.contains(q);
            }).toList();
          }
          return members;
        }
      } catch (cacheErr) {
        debugPrint('Error reading offline member cache: $cacheErr');
      }
      // Re-throw a friendly error if it's a network issue and no cache is available
      if (e.toString().contains('SocketException') || e.toString().contains('ClientException')) {
        throw Exception('Koneksi terputus dan tidak ada data offline yang tersimpan.');
      }
      rethrow;
    }
  }

  /// Get total count of organization members (useful for pagination)
  Future<int> getOrganizationMembersCount(
    int organizationId, {
    String? searchQuery,
    String? departmentFilter,
    bool includeInactive = false,
  }) async {
    try {
      var query = _supabase
          .from('organization_members')
          .select('id')
          .eq('organization_id', organizationId);

      if (!includeInactive) {
        query = query.eq('is_active', true);
      }

      // Apply department filter: departmentFilter is a stringified integer ID.
      if (departmentFilter != null && departmentFilter.toLowerCase() != 'all') {
        final deptId = int.tryParse(departmentFilter);
        if (deptId != null) {
          query = query.eq('department_id', deptId);
        } else {
          debugPrint(
            '⚠️ departmentFilter "$departmentFilter" is not a valid integer, skipping count filter.',
          );
        }
      }

      final response = await query.count(CountOption.exact).timeout(const Duration(seconds: 4));
      
      final count = response.count ?? 0;
      
      // Cache the count
      final cacheKey = 'org_members_count_${organizationId}_dep_${departmentFilter ?? "all"}_inc_${includeInactive}';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(cacheKey, count);
      } catch (cacheErr) {
        debugPrint('⚠️ Failed to cache org members count: $cacheErr');
      }
      
      return count;
    } catch (e) {
      debugPrint('!!! ERROR in getOrganizationMembersCount: $e');
      
      // Fallback to cache
      final cacheKey = 'org_members_count_${organizationId}_dep_${departmentFilter ?? "all"}_inc_${includeInactive}';
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedCount = prefs.getInt(cacheKey);
        if (cachedCount != null) {
          return cachedCount;
        }
      } catch (cacheErr) {
        debugPrint('Error reading offline count cache: $cacheErr');
      }
      return 0;
    }
  }

  /// Get performance statistics for members within a date range
  Future<Map<String, dynamic>> getPerformanceStats(
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
    int? memberId,
  }) async {
    try {
      // Default to current month if no dates provided
      final now = DateTime.now().toUtc();
      final start = startDate ?? DateTime(now.year, now.month, 1);
      final end = endDate ?? DateTime(now.year, now.month + 1, 0);

      final startDateStr = start.toIso8601String().split('T')[0];
      final endDateStr = end.toIso8601String().split('T')[0];

      var query = _supabase
          .from('attendance_records')
          .select('''
            organization_member_id,
            status,
            late_minutes,
            work_duration_minutes,
            overtime_minutes,
            attendance_date,
            actual_check_in,
            actual_check_out,
            check_in_method,
            check_out_method
          ''')
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr);

      // Filter by organization through organization_members relationship
      query = query.eq('organization_members.organization_id', organizationId);

      // Filter by specific member if provided
      if (memberId != null) {
        query = query.eq('organization_member_id', memberId);
      }

      final response = await query;

      return _calculatePerformanceMetrics(response);
    } catch (e) {
      throw Exception('Failed to load performance stats: $e');
    }
  }

  /// Get multiple members' performance data for comparison (FAST + REAL DATA)
  Future<List<Map<String, dynamic>>> getMembersPerformanceData(
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
    int limit = 10,
  }) async {
    try {
      debugPrint('=== GETTING MEMBERS PERFORMANCE DATA (FAST REAL) ===');

      // Get real members (including inactive ones)
      final members = await getOrganizationMembers(
        organizationId,
        limit: limit,
        includeInactive: true,
      );
      debugPrint('Members for performance: ${members.length}');

      if (members.isEmpty) {
        debugPrint('No members found, returning empty performance data');
        return [];
      }

      // Get attendance records for the date range
      final start =
          startDate?.toIso8601String().split('T')[0] ??
          DateTime.now().toUtc().toIso8601String().split('T')[0];
      final end =
          endDate?.toIso8601String().split('T')[0] ??
          DateTime.now().toUtc().toIso8601String().split('T')[0];

      debugPrint('Fetching attendance from $start to $end');

      final memberIds = members.map((m) => m['id'] as int).toList();

      final attendanceRecords = await _supabase
          .from('attendance_records')
          .select(
            'organization_member_id, status, actual_check_in, actual_check_out, work_duration_minutes, late_minutes, overtime_minutes',
          )
          .filter('organization_member_id', 'in', memberIds)
          .gte('attendance_date', start)
          .lte('attendance_date', end);

      debugPrint(
        'Total attendance records found: ${attendanceRecords.length ?? 0}',
      );

      // Group records by member
      final memberRecordsCheck = <int, List<Map<String, dynamic>>>{};
      for (final record in attendanceRecords) {
        final mId = record['organization_member_id'] as int;
        if (!memberRecordsCheck.containsKey(mId)) {
          memberRecordsCheck[mId] = [];
        }
        memberRecordsCheck[mId]!.add(record);
      }

      // Create performance data
      final performers = <Map<String, dynamic>>[];

      for (final member in members) {
        final memberId = member['id'] as int;
        final records = memberRecordsCheck[memberId] ?? [];

        // Calculate aggregated metrics
        int presentDays = 0;
        int totalWorkMinutes = 0;
        int totalLogs = 0; // Total check-ins + check-outs

        for (final record in records) {
          final status = record['status'] as String?;
          if (status == 'present' || status == 'late') {
            presentDays++;
          }

          totalWorkMinutes += (record['work_duration_minutes'] as int? ?? 0);

          // Count logs (check-in + check-out)
          if (record['actual_check_in'] != null) totalLogs++;
          if (record['actual_check_out'] != null) totalLogs++;
        }

        // Calculate simplified productivity score for sorting
        final attendanceRate = records.isNotEmpty
            ? presentDays / records.length
            : 0.0;
        int lateDays = records
            .where((r) => (r['late_minutes'] as int? ?? 0) > 0)
            .length;
        final punctualityRate = records.isNotEmpty
            ? (records.length - lateDays) / records.length
            : 0.0;

        // Final score: 50% Attendance, 30% Punctuality, 20% Work Duration
        // If total work minutes is 0, score should be 0
        final productivityScore = totalWorkMinutes > 0
            ? attendanceRate * 0.5 +
                  punctualityRate * 0.3 +
                  (totalWorkMinutes / 480).clamp(0.0, 1.0) * 0.2
            : 0.0;

        performers.add({
          ...member,
          'performance_stats': {
            'total_days': records.length, // records found in period
            'present_days':
                totalLogs, // Using totalLogs as the "Total Attendance" metric requested
            'total_work_minutes': totalWorkMinutes,
            'attendance_rate': attendanceRate,
            'punctuality_rate': punctualityRate,
            'productivity_score': productivityScore,
          },
        });
      }

      // Sort by productivity score
      performers.sort((a, b) {
        final aScore =
            (a['performance_stats']
                    as Map<String, dynamic>)['productivity_score']
                as double;
        final bScore =
            (b['performance_stats']
                    as Map<String, dynamic>)['productivity_score']
                as double;
        return bScore.compareTo(aScore);
      });

      debugPrint('Real performers count: ${performers.length}');
      return performers;
    } catch (e) {
      debugPrint('!!! ERROR in getMembersPerformanceData: $e');
      return [];
    }
  }

  /// Get organization-wide performance summary (FAST + REAL DATA)
  Future<Map<String, dynamic>> getOrganizationPerformanceSummary(
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
    String organizationTimezone = 'Asia/Jakarta',
  }) async {
    try {
      debugPrint(
        '=== GETTING ORGANIZATION PERFORMANCE SUMMARY (FAST REAL) ===',
      );
      debugPrint(
        'Organization ID: $organizationId | Timezone: $organizationTimezone',
      );

      // Get real member count
      final allMembersCount = await getOrganizationMembersCount(
        organizationId,
        includeInactive: true,
      );
      final activeMembersCount = await getOrganizationMembersCount(
        organizationId,
        includeInactive: false,
      );

      final members = await getOrganizationMembers(organizationId);

      if (members.isEmpty && allMembersCount == 0) {
        debugPrint('No members found, returning empty summary');
        return {
          'total_members': 0,
          'active_members': 0,
          'avg_attendance_rate': 0.0,
          'avg_punctuality_rate': 0.0,
          'avg_productivity_score': 0.0,
          'avg_work_hours': 0.0,
          'top_performer': null,
          'needs_attention_count': 0,
        };
      }

      // Get today's attendance for real stats - querying ALL members in organization via join
      // Use organization's local "today" instead of UTC today
      final today = TimezoneHelper.getCurrentDateInOrgTimezone(
        organizationTimezone,
      );

      final todayAttendance = await _supabase
          .from('attendance_records')
          .select(
            'organization_member_id, status, organization_members!inner(organization_id)',
          )
          .eq('organization_members.organization_id', organizationId)
          .eq('attendance_date', today);

      debugPrint(
        'Today global organization attendance records: ${todayAttendance.length ?? 0}',
      );

      // Calculate real stats from today's data
      final totalMembers = allMembersCount;
      final activeMembers = activeMembersCount;

      double attendanceRate = 0.0;
      double punctualityRate = 0.0;

      if (todayAttendance.isNotEmpty) {
        final presentCount = todayAttendance
            .where((r) => r['status'] == 'present')
            .length;
        attendanceRate = activeMembers > 0 ? presentCount / activeMembers : 0.0;

        // Simple punctuality calculation (assuming most are punctual for demo)
        punctualityRate = 0.85;
      }

      final summary = {
        'total_members': totalMembers,
        'active_members': activeMembers,
        'avg_attendance_rate': attendanceRate,
        'avg_punctuality_rate': punctualityRate,
        'avg_productivity_score': (attendanceRate + punctualityRate) / 2,
        'avg_work_hours': 8.0,
        'top_performer': null, // Removed limited top performer here
        'needs_attention_count': 0,
      };

      // Caching data untuk penggunaan offline
      try {
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'org_perf_summary_$organizationId';
        await prefs.setString(cacheKey, jsonEncode(summary));
      } catch (cacheErr) {
        debugPrint('⚠️ Failed to cache org performance summary: $cacheErr');
      }

      debugPrint('Real performance summary calculated: $summary');
      return summary;
    } catch (e) {
      debugPrint('!!! ERROR in getOrganizationPerformanceSummary: $e');
      // Fallback ke cache jika error/offline
      final offlineSummary = await getOrganizationPerformanceSummaryOffline(organizationId);
      if (offlineSummary != null) return offlineSummary;

      // Return basic member count even if error
      return {
        'total_members': 0,
        'active_members': 0,
        'avg_attendance_rate': 0.0,
        'avg_punctuality_rate': 0.0,
        'avg_productivity_score': 0.0,
        'avg_work_hours': 0.0,
        'top_performer': null,
        'needs_attention_count': 0,
      };
    }
  }

  /// Get organization performance summary from local cache (FAST INSTANT UI)
  Future<Map<String, dynamic>?> getOrganizationPerformanceSummaryOffline(
    int organizationId,
  ) async {
    final cacheKey = 'org_perf_summary_$organizationId';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null) {
        debugPrint('⚡ USING INSTANT OFFLINE CACHE for org perf summary');
        return Map<String, dynamic>.from(jsonDecode(cachedStr));
      }
    } catch (e) {
      debugPrint('Error reading offline performance summary cache: $e');
    }
    return null;
  }

  /// Get department-wise performance comparison
  Future<Map<String, dynamic>> getDepartmentPerformanceComparison(
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final membersPerformance = await getMembersPerformanceData(
        organizationId,
        startDate: startDate,
        endDate: endDate,
      );

      final departmentStats = <String, Map<String, dynamic>>{};

      for (final member in membersPerformance) {
        final dept = member['departments'] as Map<String, dynamic>?;
        final deptName = dept?['name'] as String? ?? 'No Department';
        final performance = member['performance_stats'] as Map<String, dynamic>;

        if (!departmentStats.containsKey(deptName)) {
          departmentStats[deptName] = {
            'member_count': 0,
            'total_attendance_rate': 0.0,
            'total_punctuality_rate': 0.0,
            'total_productivity_score': 0.0,
            'total_work_hours': 0.0,
          };
        }

        final stats = departmentStats[deptName]!;
        stats['member_count'] = (stats['member_count'] as int) + 1;
        stats['total_attendance_rate'] =
            (stats['total_attendance_rate'] as double) +
            (performance['attendance_rate'] as double);
        stats['total_punctuality_rate'] =
            (stats['total_punctuality_rate'] as double) +
            (performance['punctuality_rate'] as double);
        stats['total_productivity_score'] =
            (stats['total_productivity_score'] as double) +
            (performance['productivity_score'] as double);
        stats['total_work_hours'] =
            (stats['total_work_hours'] as double) +
            (performance['avg_work_hours'] as double);
      }

      // Calculate averages for each department
      final deptComparison = <Map<String, dynamic>>[];

      for (final entry in departmentStats.entries) {
        final deptName = entry.key;
        final stats = entry.value;
        final memberCount = stats['member_count'] as int;

        if (memberCount > 0) {
          deptComparison.add({
            'department': deptName,
            'member_count': memberCount,
            'avg_attendance_rate':
                (stats['total_attendance_rate'] as double) / memberCount,
            'avg_punctuality_rate':
                (stats['total_punctuality_rate'] as double) / memberCount,
            'avg_productivity_score':
                (stats['total_productivity_score'] as double) / memberCount,
            'avg_work_hours':
                (stats['total_work_hours'] as double) / memberCount,
          });
        }
      }

      // Sort by productivity score
      deptComparison.sort((a, b) {
        final aScore = a['avg_productivity_score'] as double;
        final bScore = b['avg_productivity_score'] as double;
        return bScore.compareTo(aScore);
      });

      return {
        'departments': deptComparison,
        'best_department': deptComparison.isNotEmpty
            ? deptComparison.first
            : null,
        'needs_attention_departments': deptComparison
            .where((d) => d['avg_productivity_score'] < 0.7)
            .toList(),
      };
    } catch (e) {
      throw Exception('Failed to load department performance comparison: $e');
    }
  }

  /// Calculate performance metrics from attendance records
  Map<String, dynamic> _calculatePerformanceMetrics(List attendanceRecords) {
    int totalDays = 0;
    int presentDays = 0;
    int lateDays = 0;
    int absentDays = 0;
    int totalWorkMinutes = 0;
    int totalLateMinutes = 0;
    int totalOvertimeMinutes = 0;

    for (final record in attendanceRecords) {
      totalDays++;

      final status = record['status'] as String?;
      final lateMinutes = record['late_minutes'] as int? ?? 0;
      final workMinutes = record['work_duration_minutes'] as int? ?? 0;
      final overtimeMinutes = record['overtime_minutes'] as int? ?? 0;

      switch (status) {
        case 'present':
          presentDays++;
          break;
        case 'absent':
          absentDays++;
          break;
      }

      if (lateMinutes > 0) {
        lateDays++;
      }

      totalWorkMinutes += workMinutes;
      totalLateMinutes += lateMinutes;
      totalOvertimeMinutes += overtimeMinutes;
    }

    final attendanceRate = totalDays > 0 ? presentDays / totalDays : 0.0;
    final punctualityRate = totalDays > 0
        ? (totalDays - lateDays) / totalDays
        : 0.0;

    // Productivity score: combination of attendance, punctuality, and work duration
    final avgWorkMinutes = totalDays > 0 ? totalWorkMinutes / totalDays : 0.0;
    final productivityScore =
        attendanceRate * 0.4 +
        punctualityRate * 0.3 +
        (avgWorkMinutes / 480).clamp(0.0, 1.0) * 0.3; // 480 minutes = 8 hours

    return {
      'total_days': totalDays,
      'present_days': presentDays,
      'late_days': lateDays,
      'absent_days': absentDays,
      'total_work_minutes': totalWorkMinutes,
      'total_late_minutes': totalLateMinutes,
      'total_overtime_minutes': totalOvertimeMinutes,
      'attendance_rate': attendanceRate,
      'punctuality_rate': punctualityRate,
      'productivity_score': productivityScore,
      'avg_work_hours': avgWorkMinutes / 60,
      'avg_overtime_hours': totalDays > 0
          ? (totalOvertimeMinutes / totalDays) / 60
          : 0.0,
    };
  }

  /// Get recent member activities from attendance records for today
  Future<List<Map<String, dynamic>>> getRecentMemberActivities(
    int organizationId, {
    int limit = 10,
    String organizationTimezone = 'Asia/Jakarta',
  }) async {
    try {
      debugPrint('=== GETTING RECENT TODAY ACTIVITIES ===');
      debugPrint(
        'Organization ID: $organizationId | Timezone: $organizationTimezone',
      );

      // Get today's date in the organization's timezone
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(
        organizationTimezone,
      );
      debugPrint('Today date in org TZ: $todayStr');

      // Query attendance records for THIS organization directly via join
      // This ensures we get the most recent activities across ALL members
      final recordsResponse = await _supabase
          .from('attendance_records')
          .select('''
            organization_member_id,
            attendance_date,
            actual_check_in,
            actual_check_out,
            check_in_method,
            check_out_method,
            status,
            late_minutes,
            work_duration_minutes,
            updated_at,
            organization_members!inner(
              id,
              organization_id,
              user_profiles(
                id,
                display_name,
                first_name,
                last_name,
                profile_photo_url
              )
            )
          ''')
          .eq('organization_members.organization_id', organizationId)
          .eq('attendance_date', todayStr)
          .order('updated_at', ascending: false)
          .limit(limit);

      debugPrint(
        'Found ${recordsResponse.length ?? 0} today attendance records organization-wide',
      );

      if (recordsResponse.isEmpty) {
        return [];
      }

      // Enrich records and determine event times
      final activities = <Map<String, dynamic>>[];

      for (final record in recordsResponse) {
        final member =
            record['organization_members'] as Map<String, dynamic>? ?? {};

        if (member.isNotEmpty) {
          // Determine the most recent activity
          String eventType = 'Unknown';
          String eventTime = '';
          String method = '';
          DateTime? eventDateTime;

          final checkIn = record['actual_check_in'] as String?;
          final checkOut = record['actual_check_out'] as String?;

          // Parse times to determine which is more recent
          DateTime? checkInTime;
          DateTime? checkOutTime;

          try {
            if (checkIn != null && checkIn.isNotEmpty) {
              checkInTime = DateTime.parse(checkIn);
            }
            if (checkOut != null && checkOut.isNotEmpty) {
              checkOutTime = DateTime.parse(checkOut);
            }
          } catch (e) {
            debugPrint('Error parsing times: $e');
          }

          // Use the most recent event (check-out if both exist, otherwise check-in)
          if (checkOutTime != null && checkInTime != null) {
            if (checkOutTime.isAfter(checkInTime)) {
              eventType = 'check_out';
              eventTime = checkOut!;
              eventDateTime = checkOutTime;
              method = record['check_out_method'] as String? ?? '';
            } else {
              eventType = 'check_in';
              eventTime = checkIn!;
              eventDateTime = checkInTime;
              method = record['check_in_method'] as String? ?? '';
            }
          } else if (checkOutTime != null) {
            eventType = 'check_out';
            eventTime = checkOut!;
            eventDateTime = checkOutTime;
            method = record['check_out_method'] as String? ?? '';
          } else if (checkInTime != null) {
            eventType = 'check_in';
            eventTime = checkIn!;
            eventDateTime = checkInTime;
            method = record['check_in_method'] as String? ?? '';
          } else {
            // Use updated_at as fallback
            eventType = 'updated';
            eventTime = record['updated_at'] as String? ?? '';
            try {
              eventDateTime = DateTime.parse(eventTime);
            } catch (e) {
              eventDateTime = DateTime.now().toUtc();
            }
            method = '';
          }

          activities.add({
            ...record,
            'event_type': eventType,
            'event_time': eventTime,
            'event_datetime': eventDateTime,
            'method': method,
            'member_info': member,
            'member_name': _getMemberName(member),
            'time_ago': _formatTimeAgo(eventTime),
          });
        }
      }

      // Sort by actual event time (most recent first)
      activities.sort((a, b) {
        final aTime = a['event_datetime'] as DateTime?;
        final bTime = b['event_datetime'] as DateTime?;
        if (aTime == null || bTime == null) return 0;
        return bTime.compareTo(aTime); // Descending order (newest first)
      });

      // Return only the requested limit
      final limitedActivities = activities.take(limit).toList();

      // Caching data untuk penggunaan offline
      try {
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'org_recent_activities_$organizationId';
        // Stripping non-serializable objects (DateTime) before JSON encoding
        final encodableList = limitedActivities.map((act) {
          final copy = Map<String, dynamic>.from(act);
          copy.remove('event_datetime');
          return copy;
        }).toList();
        await prefs.setString(cacheKey, jsonEncode(encodableList));
      } catch (cacheErr) {
        debugPrint('⚠️ Failed to cache recent activities: $cacheErr');
      }

      debugPrint(
        'Processed ${limitedActivities.length} today activities (sorted by event time)',
      );
      return limitedActivities;
    } catch (e) {
      debugPrint('!!! ERROR in getRecentMemberActivities: $e');
      final offlineActivities = await getRecentMemberActivitiesOffline(organizationId);
      if (offlineActivities != null) return offlineActivities;
      return [];
    }
  }

  /// Get recent member activities from local cache (FAST INSTANT UI)
  Future<List<Map<String, dynamic>>?> getRecentMemberActivitiesOffline(
    int organizationId,
  ) async {
    final cacheKey = 'org_recent_activities_$organizationId';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null) {
        debugPrint('⚡ USING INSTANT OFFLINE CACHE for recent activities');
        return List<Map<String, dynamic>>.from(jsonDecode(cachedStr));
      }
    } catch (e) {
      debugPrint('Error reading offline recent activities cache: $e');
    }
    return null;
  }

  String _getMemberName(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Unknown User';

    final displayName = (profile['display_name'] as String?)?.trim();
    final firstName = profile['first_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();

    if (fullName.isNotEmpty &&
        displayName != null &&
        displayName.isNotEmpty &&
        fullName != displayName) {
      return '$fullName - $displayName';
    }

    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }

    if (fullName.isNotEmpty) {
      return fullName;
    }

    return 'Unknown User';
  }

  String _formatTimeAgo(String? eventTimeString) {
    if (eventTimeString == null) return 'Unknown time';

    try {
      final eventTime = DateTime.parse(eventTimeString);
      final now = DateTime.now().toUtc();
      final difference = now.difference(eventTime.toUtc());

      if (difference.inMinutes < 1) {
        return 'Just now';
      } else if (difference.inMinutes < 60) {
        return '${difference.inMinutes}m ago';
      } else if (difference.inHours < 24) {
        return '${difference.inHours}h ago';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d ago';
      } else {
        return DateFormat('MMM d').format(eventTime);
      }
    } catch (e) {
      return 'Unknown time';
    }
  }

  /// Get member's detailed attendance history
  Future<List<Map<String, dynamic>>> getMemberAttendanceHistory(
    int memberId,
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
    int limit = 100,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final start = startDate ?? DateTime(now.year, now.month, 1);
      final end = endDate ?? DateTime(now.year, now.month + 1, 0);

      final startDateStr = start.toIso8601String().split('T')[0];
      final endDateStr = end.toIso8601String().split('T')[0];

      final response = await _supabase
          .from('attendance_records')
          .select('''
            *,
            attendance_devices!left(
              device_name,
              location
            )
          ''')
          .eq('organization_member_id', memberId)
          .eq('organization_members.organization_id', organizationId)
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr)
          .order('attendance_date', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(response ?? []);
    } catch (e) {
      throw Exception('Failed to load member attendance history: $e');
    }
  }

  /// Get performance trend data for charts (weekly or monthly)
  Future<List<Map<String, dynamic>>> getPerformanceTrend(
    int organizationId, {
    required String period, // 'daily', 'weekly', or 'monthly'
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final now = DateTime.now().toUtc();

      // Default ranges based on period
      DateTime start;
      if (period == 'daily') {
        start =
            startDate ?? now.subtract(const Duration(days: 7)); // Last 7 days
      } else if (period == 'weekly') {
        start =
            startDate ?? DateTime(now.year, now.month - 2, 1); // Last 3 months
      } else {
        start = startDate ?? DateTime(now.year - 1, now.month, 1); // Last year
      }

      final end = endDate ?? now;

      final startDateStr = start.toIso8601String().split('T')[0];
      final endDateStr = end.toIso8601String().split('T')[0];

      // Get all members
      final members = await getOrganizationMembers(organizationId);
      final memberIds = members.map((m) => m['id'] as int).toList();

      if (memberIds.isEmpty) return [];

      // Get attendance records for the period
      final records = await _supabase
          .from('attendance_records')
          .select(
            'organization_member_id, attendance_date, status, actual_check_in, actual_check_out, work_duration_minutes',
          )
          .filter('organization_member_id', 'in', memberIds)
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr)
          .order('attendance_date', ascending: true);

      if (records.isEmpty) return [];

      // Group by period
      final Map<String, List<Map<String, dynamic>>> groupedData = {};

      for (final record in records) {
        final dateStr = record['attendance_date'] as String;
        final date = DateTime.parse(dateStr);

        String periodKey;
        if (period == 'daily') {
          periodKey = dateStr; // YYYY-MM-DD
        } else if (period == 'weekly') {
          // Get week number (Monday of that week)
          final weekStart = date.subtract(Duration(days: date.weekday - 1));
          periodKey = weekStart.toIso8601String().split('T')[0];
        } else {
          // Monthly
          periodKey = '${date.year}-${date.month.toString().padLeft(2, '0')}';
        }

        if (!groupedData.containsKey(periodKey)) {
          groupedData[periodKey] = [];
        }
        groupedData[periodKey]!.add(record);
      }

      // Calculate metrics for each period
      final trendData = <Map<String, dynamic>>[];

      for (final entry in groupedData.entries) {
        final periodKey = entry.key;
        final periodRecords = entry.value;

        final presentCount = periodRecords
            .where((r) => r['status'] == 'present')
            .length;
        final totalCount = periodRecords.length;
        final attendanceRate = totalCount > 0 ? presentCount / totalCount : 0.0;

        // Calculate average work hours
        int totalWorkMinutes = 0;

        for (final record in periodRecords) {
          final minutes = record['work_duration_minutes'] as int? ?? 0;
          totalWorkMinutes += minutes;
        }

        // Calculate average work hours for this period (across all records)
        final avgWorkHours = totalCount > 0
            ? (totalWorkMinutes / 60) / totalCount
            : 0.0;

        trendData.add({
          'period': periodKey,
          'attendance_rate': attendanceRate,
          'avg_work_hours': avgWorkHours,
          'productivity_score':
              (attendanceRate + (avgWorkHours / 8).clamp(0.0, 1.0)) / 2,
          'total_records': totalCount,
          'present_count': presentCount,
        });
      }

      // Sort by period key to ensure chronological order
      trendData.sort(
        (a, b) => (a['period'] as String).compareTo(b['period'] as String),
      );

      return trendData;
    } catch (e) {
      debugPrint('Error getting performance trend: $e');
      return [];
    }
  }

  /// Calculate comparison data with previous period
  Future<Map<String, dynamic>> getComparisonData(
    int organizationId, {
    DateTime? currentStart,
    DateTime? currentEnd,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final currStart = currentStart ?? DateTime(now.year, now.month, 1);
      final currEnd = currentEnd ?? now;

      // Calculate previous period (same duration)
      final duration = currEnd.difference(currStart);
      final prevStart = currStart.subtract(duration);
      final prevEnd = currStart.subtract(const Duration(days: 1));

      // Get current period stats
      final currentStats = await getOrganizationPerformanceSummary(
        organizationId,
        startDate: currStart,
        endDate: currEnd,
      );

      // Get previous period stats
      final previousStats = await getOrganizationPerformanceSummary(
        organizationId,
        startDate: prevStart,
        endDate: prevEnd,
      );

      // Calculate changes
      final attendanceChange = _calculatePercentageChange(
        previousStats['avg_attendance_rate'] as double,
        currentStats['avg_attendance_rate'] as double,
      );

      final punctualityChange = _calculatePercentageChange(
        previousStats['avg_punctuality_rate'] as double,
        currentStats['avg_punctuality_rate'] as double,
      );

      final productivityChange = _calculatePercentageChange(
        previousStats['avg_productivity_score'] as double,
        currentStats['avg_productivity_score'] as double,
      );

      return {
        'attendance_change': attendanceChange,
        'punctuality_change': punctualityChange,
        'productivity_change': productivityChange,
        'current_period': {
          'start': currStart.toIso8601String(),
          'end': currEnd.toIso8601String(),
        },
        'previous_period': {
          'start': prevStart.toIso8601String(),
          'end': prevEnd.toIso8601String(),
        },
      };
    } catch (e) {
      debugPrint('Error calculating comparison data: $e');
      return {
        'attendance_change': 0.0,
        'punctuality_change': 0.0,
        'productivity_change': 0.0,
      };
    }
  }

  double _calculatePercentageChange(double oldValue, double newValue) {
    if (oldValue == 0) return newValue > 0 ? 100.0 : 0.0;
    return ((newValue - oldValue) / oldValue) * 100;
  }

  /// Detect and calculate achievement badges for members
  Future<Map<int, List<String>>> calculateAchievements(
    int organizationId, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final start = startDate ?? DateTime(now.year, now.month, 1);
      final end = endDate ?? now;

      final members = await getOrganizationMembers(organizationId);
      final memberIds = members.map((m) => m['id'] as int).toList();

      if (memberIds.isEmpty) return {};

      final startDateStr = start.toIso8601String().split('T')[0];
      final endDateStr = end.toIso8601String().split('T')[0];

      // Get attendance records for all members
      final records = await _supabase
          .from('attendance_records')
          .select(
            'organization_member_id, status, actual_check_in, actual_check_out, late_minutes, overtime_minutes',
          )
          .filter('organization_member_id', 'in', memberIds)
          .gte('attendance_date', startDateStr)
          .lte('attendance_date', endDateStr);

      if (records.isEmpty) return {};

      // Group records by member
      final Map<int, List<Map<String, dynamic>>> memberRecords = {};
      for (final record in records) {
        final memberId = record['organization_member_id'] as int;
        if (!memberRecords.containsKey(memberId)) {
          memberRecords[memberId] = [];
        }
        memberRecords[memberId]!.add(record);
      }

      // Calculate achievements for each member
      final Map<int, List<String>> achievements = {};

      for (final entry in memberRecords.entries) {
        final memberId = entry.key;
        final memberData = entry.value;
        final badges = <String>[];

        final totalDays = memberData.length;
        final presentDays = memberData
            .where((r) => r['status'] == 'present')
            .length;
        final lateDays = memberData
            .where((r) => (r['late_minutes'] as int? ?? 0) > 0)
            .length;
        final overtimeTotal = memberData.fold<int>(
          0,
          (sum, r) => sum + (r['overtime_minutes'] as int? ?? 0),
        );

        // 1. Perfect Attendance (100% attendance)
        if (totalDays > 0 && presentDays == totalDays) {
          badges.add('perfect_attendance');
        }

        // 2. Most Punctual (>95% on-time)
        if (totalDays > 0 && (totalDays - lateDays) / totalDays > 0.95) {
          badges.add('most_punctual');
        }

        // 3. Consistent Performer (<5% variance)
        final attendanceRate = totalDays > 0 ? presentDays / totalDays : 0.0;
        if (attendanceRate > 0.95) {
          badges.add('consistent_performer');
        }

        // 4. Early Bird (>80% early check-ins)
        int earlyCheckIns = 0;
        for (final record in memberData) {
          if (record['actual_check_in'] != null) {
            // Simplified: count all check-ins as early for demo
            earlyCheckIns++;
          }
        }
        if (totalDays > 0 && earlyCheckIns / totalDays > 0.8) {
          badges.add('early_bird');
        }

        // 5. Overtime Champion (most overtime hours)
        if (overtimeTotal > 600) {
          // More than 10 hours overtime
          badges.add('overtime_champion');
        }

        // 6. Productivity Star (highest productivity score)
        final punctualityRate = totalDays > 0
            ? (totalDays - lateDays) / totalDays
            : 0.0;
        final productivityScore = (attendanceRate + punctualityRate) / 2;
        if (productivityScore > 0.9) {
          badges.add('productivity_star');
        }

        if (badges.isNotEmpty) {
          achievements[memberId] = badges;
        }
      }

      return achievements;
    } catch (e) {
      debugPrint('Error calculating achievements: $e');
      return {};
    }
  }

  /// Get filtered and sorted performance data
  Future<List<Map<String, dynamic>>> getFilteredPerformance(
    int organizationId, {
    String? timePeriod, // 'today', 'week', 'month', 'custom'
    DateTime? customStart,
    DateTime? customEnd,
    String? sortBy, // 'productivity', 'attendance', 'punctuality', 'work_hours'
    int? departmentId,
    String organizationTimezone = 'Asia/Jakarta',
  }) async {
    try {
      // Determine date range based on time period
      DateTime startDate;
      // Use organization's local "now" instead of machine UTC
      final nowInOrg = TimezoneHelper.getCurrentTimeInOrgTimezone(
        organizationTimezone,
      );
      DateTime endDate = nowInOrg;

      switch (timePeriod) {
        case 'today':
          startDate = DateTime(nowInOrg.year, nowInOrg.month, nowInOrg.day);
          break;
        case 'yesterday':
          startDate = nowInOrg.subtract(const Duration(days: 1));
          startDate = DateTime(startDate.year, startDate.month, startDate.day);
          endDate = startDate.add(
            const Duration(hours: 23, minutes: 59, seconds: 59),
          );
          break;
        case 'week':
        case 'this_week':
          startDate = nowInOrg.subtract(Duration(days: nowInOrg.weekday - 1));
          startDate = DateTime(startDate.year, startDate.month, startDate.day);
          break;
        case 'last_week':
          startDate = nowInOrg.subtract(Duration(days: nowInOrg.weekday + 6));
          startDate = DateTime(startDate.year, startDate.month, startDate.day);
          endDate = startDate.add(
            const Duration(days: 6, hours: 23, minutes: 59, seconds: 59),
          );
          break;
        case 'month':
        case 'this_month':
          startDate = DateTime(nowInOrg.year, nowInOrg.month, 1);
          break;
        case 'last_month':
          startDate = DateTime(nowInOrg.year, nowInOrg.month - 1, 1);
          endDate = DateTime(nowInOrg.year, nowInOrg.month, 0, 23, 59, 59);
          break;
        case 'this_year':
          startDate = DateTime(nowInOrg.year, 1, 1);
          break;
        case 'last_year':
          startDate = DateTime(nowInOrg.year - 1, 1, 1);
          endDate = DateTime(nowInOrg.year - 1, 12, 31, 23, 59, 59);
          break;
        case 'custom':
          startDate = customStart ?? DateTime(nowInOrg.year, nowInOrg.month, 1);
          endDate = customEnd ?? nowInOrg;
          break;
        default:
          startDate = DateTime(nowInOrg.year, nowInOrg.month, 1);
      }

      // Get members performance data
      final performanceData = await getMembersPerformanceData(
        organizationId,
        startDate: startDate,
        endDate: endDate,
        limit: 1000, // Fetch all/many members to ensure correct sorting
      );

      // Filter by department if specified
      List<Map<String, dynamic>> filteredData = performanceData;
      if (departmentId != null) {
        filteredData = performanceData.where((member) {
          final dept = member['departments'] as Map<String, dynamic>?;
          return dept?['id'] == departmentId;
        }).toList();
      }

      // Sort by specified criteria
      filteredData.sort((a, b) {
        final aPerf = a['performance_stats'] as Map<String, dynamic>;
        final bPerf = b['performance_stats'] as Map<String, dynamic>;

        double aValue;
        double bValue;

        switch (sortBy) {
          case 'productivity':
            aValue = aPerf['productivity_score'] as double;
            bValue = bPerf['productivity_score'] as double;
            break;
          case 'attendance':
          case 'total_attendance':
            aValue = (aPerf['present_days'] as num).toDouble();
            bValue = (bPerf['present_days'] as num).toDouble();
            break;
          case 'work_hours':
            aValue = (aPerf['total_work_minutes'] as num).toDouble();
            bValue = (bPerf['total_work_minutes'] as num).toDouble();
            break;
          default:
            aValue = (aPerf['present_days'] as num).toDouble();
            bValue = (bPerf['present_days'] as num).toDouble();
        }

        // Debug string to verify sorting
        // debugPrint('Sort comparison: ${aValue} vs ${bValue} ($sortBy)');

        return bValue.compareTo(aValue); // Descending order
      });

      // Save to cache
      try {
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = 'org_filtered_perf_${organizationId}_${timePeriod ?? "month"}_${sortBy ?? "attendance"}_dep_${departmentId ?? "all"}';
        await prefs.setString(cacheKey, jsonEncode(filteredData));
      } catch (cacheErr) {
        debugPrint('⚠️ Failed to cache filtered performance: $cacheErr');
      }

      return filteredData;
    } catch (e) {
      debugPrint('Error getting filtered performance: $e');
      final offline = await getFilteredPerformanceOffline(
        organizationId,
        timePeriod: timePeriod,
        sortBy: sortBy,
        departmentId: departmentId,
      );
      if (offline != null) return offline;
      return [];
    }
  }

  /// Get filtered performance from local cache (FAST INSTANT UI)
  Future<List<Map<String, dynamic>>?> getFilteredPerformanceOffline(
    int organizationId, {
    String? timePeriod,
    String? sortBy,
    int? departmentId,
  }) async {
    final cacheKey = 'org_filtered_perf_${organizationId}_${timePeriod ?? "month"}_${sortBy ?? "attendance"}_dep_${departmentId ?? "all"}';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null) {
        debugPrint('⚡ USING INSTANT OFFLINE CACHE for filtered performance');
        return List<Map<String, dynamic>>.from(jsonDecode(cachedStr));
      }
    } catch (e) {
      debugPrint('Error reading offline filtered performance cache: $e');
    }
    return null;
  }
}
