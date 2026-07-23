import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/timezone_helper.dart';
import '../../services/offline_database_service.dart';

class MemberDetailLogPage extends StatefulWidget {
  final int memberId;
  final String memberName;
  final bool isDarkMode;
  final String? profilePhotoUrl;
  final String? departmentName;
  final int? organizationId;

  const MemberDetailLogPage({
    super.key,
    required this.memberId,
    required this.memberName,
    this.isDarkMode = false,
    this.profilePhotoUrl,
    this.departmentName,
    this.organizationId,
  });

  @override
  State<MemberDetailLogPage> createState() => _MemberDetailLogPageState();
}

class _MemberDetailLogPageState extends State<MemberDetailLogPage> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _attendanceLogs = [];
  int _totalAttendanceCount = 0;
  int _onTimeCount = 0;
  int _lateCount = 0;
  final String _organizationTimezone = 'Asia/Jakarta';

  @override
  void initState() {
    super.initState();
    _fetchMemberAttendanceData();
  }

  Future<void> _fetchMemberAttendanceData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final List<Map<String, dynamic>> combinedLogs = [];
      final Set<String> processedKeys = {};

      // 1. Fetch offline attendances from SQLite
      final offlineRecords = await OfflineDatabaseService()
          .getAttendancesByMemberId(widget.memberId);

      for (var record in offlineRecords) {
        final createdAtStr = record['created_at']?.toString() ?? record['timestamp']?.toString() ?? '';
        final eventType = record['event_type']?.toString() ?? 'check_in';
        final key = '${eventType}_$createdAtStr';
        processedKeys.add(key);

        final DateTime? parsedDate = DateTime.tryParse(createdAtStr);

        combinedLogs.add({
          'id': record['id'],
          'event_type': eventType,
          'method': record['method'] ?? 'face_recognition',
          'event_time': createdAtStr,
          'parsed_time': parsedDate ?? DateTime.now(),
          'is_synced': (record['is_synced'] as num?)?.toInt() == 1,
          'status': record['notes'] ?? ((record['late_minutes'] as num? ?? 0) > 0 ? 'late' : 'on_time'),
          'photo_url': record['captured_photo_base64'] ?? record['profile_photo_base64'] ?? record['photo_path'],
          'is_offline': true,
        });
      }

      // 2. Fetch online attendance logs / records from Supabase if available
      try {
        final supabase = Supabase.instance.client;

        // Try querying attendance_logs first
        final onlineLogs = await supabase
            .from('attendance_logs')
            .select('''
              id,
              event_type,
              event_time,
              method,
              raw_data,
              organization_member_id,
              attendance_records(
                status,
                late_minutes,
                attendance_date
              )
            ''')
            .eq('organization_member_id', widget.memberId)
            .order('event_time', ascending: false)
            .limit(100);

        for (var log in onlineLogs) {
          final eventTimeStr = log['event_time']?.toString() ?? '';
          final eventType = log['event_type']?.toString() ?? 'check_in';
          final key = '${eventType}_$eventTimeStr';
          if (processedKeys.contains(key)) continue;
          processedKeys.add(key);

          final DateTime? parsedDate = DateTime.tryParse(eventTimeStr);
          final rec = log['attendance_records'] as Map<String, dynamic>?;
          final status = rec?['status']?.toString() ?? 'on_time';
          final lateMin = (rec?['late_minutes'] as num?)?.toInt() ?? 0;

          combinedLogs.add({
            'id': log['id'],
            'event_type': eventType,
            'method': log['method'] ?? 'face_recognition',
            'event_time': eventTimeStr,
            'parsed_time': parsedDate ?? DateTime.now(),
            'is_synced': true,
            'status': lateMin > 0 ? 'late' : status,
            'photo_url': null,
            'is_offline': false,
          });
        }

        // Fallback: Query attendance_records if logs empty
        if (onlineLogs.isEmpty) {
          final onlineRecords = await supabase
              .from('attendance_records')
              .select('*')
              .eq('organization_member_id', widget.memberId)
              .order('attendance_date', ascending: false)
              .limit(100);

          for (var rec in onlineRecords) {
            final checkInTime = rec['actual_check_in']?.toString() ?? rec['created_at']?.toString() ?? '';
            final key = 'check_in_$checkInTime';
            if (processedKeys.contains(key)) continue;
            processedKeys.add(key);

            final DateTime? parsedDate = DateTime.tryParse(checkInTime);
            final lateMin = (rec['late_minutes'] as num?)?.toInt() ?? 0;

            combinedLogs.add({
              'id': rec['id'],
              'event_type': 'check_in',
              'method': rec['check_in_method'] ?? 'face_recognition',
              'event_time': checkInTime,
              'parsed_time': parsedDate ?? DateTime.now(),
              'is_synced': true,
              'status': lateMin > 0 ? 'late' : (rec['status'] ?? 'on_time'),
              'photo_url': rec['check_in_photo_url'],
              'is_offline': false,
            });
          }
        }
      } catch (e) {
        debugPrint('Supabase attendance history notice: $e');
        // Offline database data is safely retained
      }

      // Sort chronologically descending
      combinedLogs.sort((a, b) {
        final timeA = a['parsed_time'] as DateTime;
        final timeB = b['parsed_time'] as DateTime;
        return timeB.compareTo(timeA);
      });

      // Calculate statistics
      int onTime = 0;
      int late = 0;

      for (var item in combinedLogs) {
        final st = item['status']?.toString().toLowerCase() ?? '';
        if (st.contains('late') || st.contains('terlambat')) {
          late++;
        } else {
          onTime++;
        }
      }

      if (mounted) {
        setState(() {
          _attendanceLogs = combinedLogs;
          _totalAttendanceCount = combinedLogs.length;
          _onTimeCount = onTime;
          _lateCount = late;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching member attendance logs: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final bgColor = isDark ? const Color(0xFF190B28) : const Color(0xFFF8F9FD);
    final cardBgColor = isDark ? const Color(0xFF281343) : Colors.white;
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF1E293B);
    final secondaryTextColor = isDark ? Colors.white70 : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF230C3E) : const Color(0xFF4A1E79),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          'Detail Log Absensi',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: _fetchMemberAttendanceData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchMemberAttendanceData,
        color: const Color(0xFF8B5CF6),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Member Profile & Summary Card
              _buildHeaderCard(cardBgColor, primaryTextColor, secondaryTextColor, isDark),
              const SizedBox(height: 20),

              // 2. Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Riwayat Absensi',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: primaryTextColor,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_attendanceLogs.length} Catatan',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8B5CF6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 3. Body Content (Loading / Error / Empty / Log List)
              _buildLogsContent(primaryTextColor, secondaryTextColor, cardBgColor, isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderCard(
    Color cardBgColor,
    Color primaryTextColor,
    Color secondaryTextColor,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Avatar
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8B5CF6), Color(0xFFD946EF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: widget.profilePhotoUrl != null && widget.profilePhotoUrl!.isNotEmpty
                      ? Image.network(
                          widget.profilePhotoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => _buildAvatarInitials(),
                        )
                      : _buildAvatarInitials(),
                ),
              ),
              const SizedBox(width: 16),
              // Member info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.memberName,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: primaryTextColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'ID: ${widget.memberId}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8B5CF6),
                            ),
                          ),
                        ),
                        if (widget.departmentName != null && widget.departmentName!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.departmentName!,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: secondaryTextColor,
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
          const SizedBox(height: 20),
          Divider(
            color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade200,
            height: 1,
          ),
          const SizedBox(height: 16),

          // Summary Stats Chips Row
          Row(
            children: [
              Expanded(
                child: _buildSummaryChip(
                  label: 'Total Absen',
                  value: '$_totalAttendanceCount',
                  icon: Icons.event_available_rounded,
                  color: const Color(0xFF8B5CF6),
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSummaryChip(
                  label: 'Tepat Waktu',
                  value: '$_onTimeCount',
                  icon: Icons.check_circle_outline_rounded,
                  color: const Color(0xFF10B981),
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSummaryChip(
                  label: 'Terlambat',
                  value: '$_lateCount',
                  icon: Icons.access_time_rounded,
                  color: const Color(0xFFF59E0B),
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAvatarInitials() {
    return Center(
      child: Text(
        _getInitials(widget.memberName),
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildSummaryChip({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white60 : const Color(0xFF64748B),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLogsContent(
    Color primaryTextColor,
    Color secondaryTextColor,
    Color cardBgColor,
    bool isDark,
  ) {
    if (_isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40.0),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6)),
              ),
              const SizedBox(height: 16),
              Text(
                'Memuat riwayat absensi...',
                style: TextStyle(color: secondaryTextColor, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 20),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Text(
              'Gagal Memuat Riwayat',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: primaryTextColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: secondaryTextColor),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _fetchMemberAttendanceData,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Coba Lagi'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_attendanceLogs.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 20),
        padding: const EdgeInsets.all(32),
        width: double.infinity,
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade200,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.assignment_outlined,
              size: 64,
              color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'Belum Ada Riwayat Absensi',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: primaryTextColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Belum ada catatan absensi terdaftar untuk anggota ini.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: secondaryTextColor),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _attendanceLogs.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = _attendanceLogs[index];
        return _buildAttendanceLogCard(item, cardBgColor, primaryTextColor, secondaryTextColor, isDark);
      },
    );
  }

  Widget _buildAttendanceLogCard(
    Map<String, dynamic> item,
    Color cardBgColor,
    Color primaryTextColor,
    Color secondaryTextColor,
    bool isDark,
  ) {
    final DateTime parsedTime = item['parsed_time'] as DateTime;
    final DateTime localTime = TimezoneHelper.convertUtcToOrgTimezone(
      parsedTime,
      _organizationTimezone,
    );

    final dateStr = TimezoneHelper.formatDateLong(localTime);
    final hourStr = localTime.hour.toString().padLeft(2, '0');
    final minuteStr = localTime.minute.toString().padLeft(2, '0');
    final timeStr = '$hourStr:$minuteStr WIB';

    final eventType = item['event_type']?.toString().toLowerCase() ?? 'check_in';
    final method = item['method']?.toString().toLowerCase() ?? 'face_recognition';
    final status = item['status']?.toString().toLowerCase() ?? 'on_time';
    final isSynced = item['is_synced'] as bool? ?? true;

    // Config event type label & color
    String eventLabel = 'Masuk';
    IconData eventIcon = Icons.login_rounded;
    Color eventColor = const Color(0xFF10B981);

    if (eventType.contains('check_out') || eventType.contains('keluar')) {
      eventLabel = 'Keluar';
      eventIcon = Icons.logout_rounded;
      eventColor = const Color(0xFFF97316);
    } else if (eventType.contains('break_out')) {
      eventLabel = 'Istirahat Keluar';
      eventIcon = Icons.free_breakfast_outlined;
      eventColor = const Color(0xFFF59E0B);
    } else if (eventType.contains('break_in')) {
      eventLabel = 'Istirahat Masuk';
      eventIcon = Icons.coffee_outlined;
      eventColor = const Color(0xFF3B82F6);
    }

    // Config method icon & label
    IconData methodIcon = Icons.face_rounded;
    String methodLabel = 'Wajah';
    if (method.contains('rfid')) {
      methodIcon = Icons.credit_card_rounded;
      methodLabel = 'RFID';
    } else if (method.contains('fingerprint')) {
      methodIcon = Icons.fingerprint_rounded;
      methodLabel = 'Fingerprint';
    } else if (method.contains('manual')) {
      methodIcon = Icons.edit_calendar_rounded;
      methodLabel = 'Manual';
    }

    // Config status badge
    String statusText = 'Tepat Waktu';
    Color statusColor = const Color(0xFF10B981);

    if (!isSynced) {
      statusText = 'Belum Sync';
      statusColor = const Color(0xFF3B82F6);
    } else if (status.contains('late') || status.contains('terlambat')) {
      statusText = 'Terlambat';
      statusColor = const Color(0xFFF59E0B);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade200,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          // Event Type Icon Container
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: eventColor.withValues(alpha: isDark ? 0.2 : 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(eventIcon, color: eventColor, size: 22),
          ),
          const SizedBox(width: 14),

          // Main Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      eventLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: primaryTextColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(methodIcon, size: 11, color: secondaryTextColor),
                          const SizedBox(width: 3),
                          Text(
                            methodLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: secondaryTextColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  dateStr,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryTextColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Time & Status Pill
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                timeStr,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: primaryTextColor,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: isDark ? 0.2 : 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
