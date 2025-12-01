import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/attendance_record.dart';
import '../services/attendance_service.dart';
import '../helpers/timezone_helper.dart';

class RfidAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const RfidAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<RfidAttendancePage> createState() => _RfidAttendancePageState();
}

class _RfidAttendancePageState extends State<RfidAttendancePage> {
  final AttendanceService _attendanceService = AttendanceService();
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _cardController = TextEditingController();
  final FocusNode _cardFocusNode = FocusNode();

  final List<_AttendanceEntry> _entries = [];
  String _organizationTimezone = 'Asia/Jakarta'; // Default timezone
  String _organizationName = ''; // Organization name
  String _attendanceMode = 'check_in'; // 'check_in', 'check_out'
  DateTime _currentTime = DateTime.now();

  int? get _organizationId =>
      widget.memberData['organization_id'] as int?;

  @override
  void initState() {
    super.initState();
    _loadOrganizationData();
    _startClock();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _cardFocusNode.requestFocus();
      }
    });
  }

  void _startClock() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(minutes: 1));
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
        return true;
      }
      return false;
    });
  }

  Future<void> _loadOrganizationData() async {
    final organizationId = _organizationId;
    if (organizationId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', organizationId)
          .maybeSingle();

      if (org != null) {
        setState(() {
          if (org['timezone'] != null) {
            _organizationTimezone = org['timezone'] as String;
          }
          if (org['name'] != null) {
            _organizationName = org['name'] as String;
          }
        });
        debugPrint('Organization data loaded: $_organizationName ($_organizationTimezone)');
      }
    } catch (e) {
      debugPrint('Error loading organization data: $e');
    }
  }

  @override
  void dispose() {
    _cardController.dispose();
    _cardFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          _organizationName.isEmpty ? 'RFID Attendance Mode' : _organizationName,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: const Color(0xFF9333EA),
        foregroundColor: Colors.white,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: const Icon(
              Icons.credit_card,
              size: 28,
            ),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => _cardFocusNode.requestFocus(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Clock and Mode Switcher Card
              _buildClockAndModeCard(),
              const SizedBox(height: 16),
              // Hidden field untuk menangkap input dari scanner
              Offstage(
                offstage: true,
                child: TextField(
                  controller: _cardController,
                  focusNode: _cardFocusNode,
                  autofocus: true,
                  enableInteractiveSelection: false,
                  decoration: const InputDecoration(border: InputBorder.none),
                  onSubmitted: (_) => _handleCardScan(),
                ),
              ),
              Expanded(
                child: _entries.isEmpty
                    ? const Center(
                        child: Text(
                          'Belum ada kartu RFID yang tercatat hari ini.',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (_, index) =>
                            _buildEntryCard(_entries[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClockAndModeCard() {
    // Convert current time to organization timezone
    final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
      _currentTime.toUtc(),
      _organizationTimezone,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Clock Section
          Expanded(
            child: Row(
              children: [
                const Icon(
                  Icons.access_time,
                  color: Color(0xFF9333EA),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  _formatTime(orgTime)!,
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9333EA),
                  ),
                ),
              ],
            ),
          ),
          // Mode Switcher Toggle
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Mode',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildToggleButton('In', 'check_in'),
                    _buildToggleButton('Out', 'check_out'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, String mode) {
    final isSelected = _attendanceMode == mode;
    Color buttonColor;
    
    if (mode == 'check_in') {
      buttonColor = Colors.green;
    } else {
      buttonColor = Colors.red;
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _attendanceMode = mode;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? buttonColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _findMemberByCard(String cardNumber) async {
    final orgId = _organizationId;
    if (orgId == null) return null;

    return _supabase
        .from('rfid_cards')
        .select('''
        id,
        card_number,
        organization_member_id,
        organization_members!inner(
          id,
          organization_id,
          user_id,
          user_profiles (
            display_name,
            first_name,
            last_name,
            profile_photo_url
          )
        )
      ''')
        .eq('card_number', cardNumber)
        .eq('organization_members.organization_id', orgId)
        .eq('is_active', true)
        .maybeSingle();
  }

  Future<void> _handleCardScan() async {
    final cardNumber = _cardController.text.trim();
    if (cardNumber.isEmpty) {
      return;
    }

    try {
      final cardData = await _findMemberByCard(cardNumber);
      if (cardData == null) return;

      final memberInfo =
          cardData['organization_members'] as Map<String, dynamic>? ?? {};
      final memberId =
          cardData['organization_member_id'] as int? ?? memberInfo['id'] as int?;

      if (memberId == null) return;

      // Verify that the member belongs to the current organization
      final memberOrgId = memberInfo['organization_id'] as int?;
      if (memberOrgId != _organizationId) {
        debugPrint('Member belongs to different organization: $memberOrgId vs $_organizationId');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kartu RFID tidak terdaftar di organisasi ini'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final todayRecord = await _attendanceService.getTodayAttendance(
        memberId,
        organizationTimezone: _organizationTimezone,
      );

      AttendanceRecord record;
      String action;
      
      if (_attendanceMode == 'check_in') {
        // Force check in mode
        record = await _attendanceService.checkIn(
          organizationMemberId: memberId,
          photoUrl: '',
          method: 'rfid_card_mobile',
          organizationTimezone: _organizationTimezone,
          rawData: {
            'card_number': cardNumber,
            'scanned_by_member_id': widget.organizationMemberId,
          },
        );
        action = 'check_in';
      } else {
        // Force check out mode
        record = await _attendanceService.checkOut(
          organizationMemberId: memberId,
          photoUrl: '',
          method: 'rfid_card_mobile',
          organizationTimezone: _organizationTimezone,
          rawData: {
            'card_number': cardNumber,
            'scanned_by_member_id': widget.organizationMemberId,
          },
        );
        action = 'check_out';
      }

      setState(() {
        final existingIndex =
            _entries.indexWhere((entry) => entry.memberId == memberId);
        final newEntry = _AttendanceEntry(
          memberId: memberId,
          memberInfo: memberInfo,
          attendance: record,
          cardNumber: cardNumber,
          action: action,
          timestamp: DateTime.now(),
        );

        if (existingIndex >= 0) {
          _entries.removeAt(existingIndex);
        }
        _entries.insert(0, newEntry);
      });
    } finally {
      _cardController.clear();
      _cardFocusNode.requestFocus();
    }
  }

  Widget _buildEntryCard(_AttendanceEntry entry) {
    final memberName = _composeMemberName(entry.memberInfo);
    final profile =
        entry.memberInfo['user_profiles'] as Map<String, dynamic>? ?? {};
    final photoPath = profile['profile_photo_url'] as String?;

    ImageProvider? imageProvider;
    if (photoPath != null && photoPath.trim().isNotEmpty) {
      if (photoPath.startsWith('http')) {
        imageProvider = NetworkImage(photoPath);
      } else {
        imageProvider = NetworkImage(
          _supabase.storage
              .from('profile-photos')
              .getPublicUrl('mass-profile/$photoPath'),
        );
      }
    }

    final isCheckIn = entry.action == 'check_in';
    final isCheckOut = entry.action == 'check_out';

    // Convert UTC timestamps to organization timezone
    final checkInTime = entry.attendance.actualCheckIn != null
        ? TimezoneHelper.convertUtcToOrgTimezone(
            entry.attendance.actualCheckIn!,
            _organizationTimezone,
          )
        : null;

    final checkOutTime = entry.attendance.actualCheckOut != null
        ? TimezoneHelper.convertUtcToOrgTimezone(
            entry.attendance.actualCheckOut!,
            _organizationTimezone,
          )
        : null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundImage:
                    imageProvider ?? const AssetImage('images/logo.png'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      memberName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isCheckIn
                      ? Colors.green.shade50
                      : isCheckOut
                          ? Colors.blue.shade50
                          : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isCheckIn
                      ? 'CHECK IN'
                      : isCheckOut
                          ? 'CHECK OUT'
                          : 'COMPLETE',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isCheckIn
                        ? Colors.green.shade800
                        : isCheckOut
                            ? Colors.blue.shade800
                            : Colors.grey.shade800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildAttendanceInfoTile(
                  label: 'Check In',
                  value: _formatTime(checkInTime),
                  icon: Icons.login,
                  color: Colors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildAttendanceInfoTile(
                  label: 'Check Out',
                  value: _formatTime(checkOutTime),
                  icon: Icons.logout,
                  color: Colors.red,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceInfoTile({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  String _composeMemberName(Map<String, dynamic>? memberInfo) {
    final profile = memberInfo?['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Anggota';
    final displayName = (profile['display_name'] as String?)?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    final first = profile['first_name'] as String? ?? '';
    final last = profile['last_name'] as String? ?? '';
    final name = '$first $last'.trim();
    return name.isEmpty ? 'Anggota' : name;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final AttendanceRecord attendance;
  final String cardNumber;
  final String action;
  final DateTime timestamp;

  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.attendance,
    required this.cardNumber,
    required this.action,
    required this.timestamp,
  });
}