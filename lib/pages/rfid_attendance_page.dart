// lib/pages/rfid_attendance_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/offline_attendance.dart';
import '../services/offline_database_service.dart';
import '../services/attendance_sync_service.dart';
import '../helpers/timezone_helper.dart';
import '../helpers/sound_helper.dart';
import '../widgets/mode_confirmation_dialog.dart';
import 'manual_check_page.dart';

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
  final OfflineDatabaseService _offlineDb = OfflineDatabaseService();
  final AttendanceSyncService _syncService = AttendanceSyncService();
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _cardController = TextEditingController();
  final FocusNode _cardFocusNode = FocusNode();
  Timer? _clockTimer;

  final List<_AttendanceEntry> _entries = [];
  String _organizationTimezone = 'Asia/Jakarta';
  String _organizationName = '';
  String _attendanceMode = 'check_in';
  DateTime _currentTime = DateTime.now();
  
  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  Timer? _scheduleCheckTimer;

  bool _isOnline = true;
  int _pendingSyncCount = 0;

  int? get _organizationId => widget.memberData['organization_id'] as int?;

  List<_AttendanceEntry> get _filteredEntries {
    return _entries.where((entry) => entry.action == _attendanceMode).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadOrganizationData();
    _loadMemberSchedule();
    _startClock();
    _startScheduleCheck();
    _checkConnectivity();
    _loadPendingSyncCount();
    _syncService.startAutoSync();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _cardFocusNode.requestFocus();
      });
      
      // Cache member data after a short delay to ensure connectivity is checked
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _isOnline) {
          _cacheMemberData();
        } else {
          // Load offline attendance data when offline
          _loadOfflineAttendanceData();
        }
      });
    });
  }

  Future<void> _checkConnectivity() async {
    final result = await Connectivity().checkConnectivity();
    final isOnline = result != ConnectivityResult.none;
    setState(() {
      _isOnline = isOnline;
    });

    // Load offline data if offline
    if (!isOnline) {
      _loadOfflineAttendanceData();
    }

    Connectivity().onConnectivityChanged.listen((results) {
      if (mounted) {
        final isOnlineNow = results != ConnectivityResult.none;
        setState(() {
          _isOnline = isOnlineNow;
        });
        if (isOnlineNow) {
          _loadPendingSyncCount();
          _cacheMemberData(); // Cache member data when coming online
        } else {
          _loadOfflineAttendanceData(); // Load offline data when going offline
        }
      }
    });
  }

  Future<void> _loadPendingSyncCount() async {
    final count = await _offlineDb.getUnsyncedCount();
    if (mounted) {
      setState(() {
        _pendingSyncCount = count;
      });
    }
  }

  Future<void> _loadOfflineAttendanceData() async {
    try {
      final offlineAttendances = await _offlineDb.getAllAttendances(limit: 100);
      
      if (mounted && offlineAttendances.isNotEmpty) {
        final List<_AttendanceEntry> loadedEntries = [];
        
        for (final attendance in offlineAttendances) {
          // Find member data from cache
          final orgId = _organizationId;
          if (orgId == null) continue;
          
          final cardData = await _offlineDb.findMemberByCardInCache(
            attendance.cardNumber,
            orgId,
          );
          
          Map<String, dynamic> memberInfo = {};
          int? memberId;
          
          if (cardData != null) {
            memberInfo = cardData['organization_members'] as Map<String, dynamic>? ?? {};
            memberId = cardData['organization_member_id'] as int? ?? memberInfo['id'] as int?;
            
            // If user_profiles is missing or empty, but we have userName from attendance, use it
            final profile = memberInfo['user_profiles'] as Map<String, dynamic>?;
            if ((profile == null || profile.isEmpty) && 
                attendance.userName != null && 
                attendance.userName!.isNotEmpty) {
              final userName = attendance.userName!;
              final nameParts = userName.split(' ');
              memberInfo['user_profiles'] = {
                'display_name': userName,
                'first_name': nameParts.isNotEmpty ? nameParts.first : '',
                'last_name': nameParts.length > 1 
                    ? nameParts.sublist(1).join(' ')
                    : '',
              };
            }
          } else {
            // If cardData not found but we have userName from attendance, create minimal memberInfo
            if (attendance.userName != null && attendance.userName!.isNotEmpty) {
              final userName = attendance.userName!;
              final nameParts = userName.split(' ');
              memberInfo = {
                'user_profiles': {
                  'display_name': userName,
                  'first_name': nameParts.isNotEmpty ? nameParts.first : '',
                  'last_name': nameParts.length > 1 
                      ? nameParts.sublist(1).join(' ')
                      : '',
                },
              };
              memberId = attendance.organizationMemberId;
            }
          }
          
          // Use organizationMemberId from attendance if available
          if (memberId == null && attendance.organizationMemberId != null) {
            memberId = attendance.organizationMemberId;
          }
          
          if (memberId != null) {
            final timestamp = DateTime.parse(attendance.timestamp);
            loadedEntries.add(_AttendanceEntry(
              memberId: memberId,
              memberInfo: memberInfo,
              cardNumber: attendance.cardNumber,
              action: attendance.eventType,
              timestamp: timestamp,
              workTimeMode: attendance.workTimeMode,
            ));
          }
        }
        
        setState(() {
          _entries.clear();
          _entries.addAll(loadedEntries);
        });
      }
    } catch (e) {
      debugPrint('Error loading offline attendance data: $e');
    }
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      } else {
        timer.cancel();
      }
    });
  }

  void _startScheduleCheck() {
    _scheduleCheckTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
      if (mounted && _workTimeMode == null) setState(() {});
    });
  }

  Future<void> _loadMemberSchedule() async {
    try {
      final today = DateTime.now();
      final todayStr = today.toIso8601String().split('T')[0];
      
      final schedule = await _supabase
          .from('member_schedules')
          .select('id, work_schedule_id, shift_id, effective_date, end_date')
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('is_active', true)
          .lte('effective_date', todayStr)
          .or('end_date.is.null,end_date.gte.$todayStr')
          .order('effective_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (schedule != null) {
        final scheduleMap = schedule as Map<String, dynamic>;
        final shiftId = scheduleMap['shift_id'] as int?;
        final workScheduleId = scheduleMap['work_schedule_id'] as int?;
        
        Map<String, dynamic>? scheduleData;
        
        if (shiftId != null) {
          final shift = await _supabase
              .from('shifts')
              .select('id, start_time, end_time')
              .eq('id', shiftId)
              .maybeSingle();
          
          if (shift != null) {
            scheduleData = {'type': 'shift', 'shift': shift};
          }
        } else if (workScheduleId != null) {
          final dayOfWeek = today.weekday % 7;
          
          final detail = await _supabase
              .from('work_schedule_details')
              .select('day_of_week, start_time, end_time, break_start, break_end')
              .eq('work_schedule_id', workScheduleId)
              .eq('day_of_week', dayOfWeek)
              .maybeSingle();
          
          if (detail != null) {
            scheduleData = {'type': 'work_schedule', 'detail': detail};
          }
        }
        
        if (scheduleData != null) {
          final scheduleDataMap = scheduleData as Map<String, dynamic>;
          setState(() {
            _memberSchedule = Map<String, dynamic>.from(scheduleMap)..addAll(scheduleDataMap);
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading schedule: $e');
    }
  }

  String _getWorkTimeMode() {
    if (_workTimeMode != null) return _workTimeMode!;
    if (_memberSchedule == null) return 'work_time';

    final orgTime = TimezoneHelper.convertUtcToOrgTimezone(
      _currentTime.toUtc(),
      _organizationTimezone,
    );
    
    final currentMinutes = orgTime.hour * 60 + orgTime.minute;
    final scheduleType = _memberSchedule!['type'] as String?;
    
    if (scheduleType == 'shift') {
      final shift = _memberSchedule!['shift'] as Map<String, dynamic>?;
      if (shift != null) {
        final startTime = _parseTimeString(shift['start_time'] as String?);
        final endTime = _parseTimeString(shift['end_time'] as String?);
        
        if (startTime != null && endTime != null) {
          final startMin = startTime.hour * 60 + startTime.minute;
          final endMin = endTime.hour * 60 + endTime.minute;
          
          if (currentMinutes >= startMin && currentMinutes < endMin) {
            return 'work_time';
          }
        }
      }
    } else if (scheduleType == 'work_schedule') {
      final detail = _memberSchedule!['detail'] as Map<String, dynamic>?;
      if (detail != null) {
        final startTime = _parseTimeString(detail['start_time'] as String?);
        final breakStart = _parseTimeString(detail['break_start'] as String?);
        final breakEnd = _parseTimeString(detail['break_end'] as String?);
        
        if (startTime != null && breakStart != null && breakEnd != null) {
          final startMin = startTime.hour * 60 + startTime.minute;
          final breakStartMin = breakStart.hour * 60 + breakStart.minute;
          final breakEndMin = breakEnd.hour * 60 + breakEnd.minute;
          
          if (currentMinutes >= startMin && currentMinutes < breakStartMin) {
            return 'work_time';
          } else if (currentMinutes >= breakStartMin && currentMinutes < breakEndMin) {
            return 'break_time';
          } else if (currentMinutes >= breakEndMin) {
            return 'work_time';
          }
        }
      }
    }

    return 'work_time';
  }

  TimeOfDay? _parseTimeString(String? timeStr) {
    if (timeStr == null) return null;
    try {
      final parts = timeStr.split(':');
      if (parts.length >= 2) {
        return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      }
    } catch (e) {
      debugPrint('Error parsing time: $timeStr');
    }
    return null;
  }

  Future<void> _cacheMemberData() async {
    if (!_isOnline) return;
    
    try {
      final orgId = _organizationId;
      if (orgId == null) return;

      debugPrint('🔄 Starting to cache member data for organization: $orgId');

      // Cache all active RFID cards for this organization
      final cards = await _supabase
          .from('rfid_cards')
          .select('''
          id, card_number, organization_member_id,
          organization_members!inner(
            id, organization_id, user_id, department_id,
            user_profiles (display_name, first_name, last_name, profile_photo_url),
            departments (id, name)
          )
        ''')
          .eq('organization_members.organization_id', orgId)
          .eq('is_active', true);

      int cachedCount = 0;
      for (final card in cards) {
        try {
          await _offlineDb.cacheMemberData(card);
          cachedCount++;
        } catch (e) {
          debugPrint('❌ Failed to cache card ${card['card_number']}: $e');
        }
      }
      
      debugPrint('✅ Successfully cached $cachedCount/${cards.length} member cards for offline use');
    } catch (e) {
      debugPrint('❌ Error caching member data: $e');
    }
  }

  Future<void> _loadOrganizationData() async {
    final orgId = _organizationId;
    if (orgId == null) return;

    try {
      final org = await _supabase
          .from('organizations')
          .select('timezone, name')
          .eq('id', orgId)
          .maybeSingle();

      if (org != null && mounted) {
        setState(() {
          _organizationTimezone = org['timezone'] as String? ?? 'Asia/Jakarta';
          _organizationName = org['name'] as String? ?? '';
        });
      }
    } catch (e) {
      debugPrint('Error loading org data: $e');
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _scheduleCheckTimer?.cancel();
    _cardController.dispose();
    _cardFocusNode.dispose();
    _syncService.stopAutoSync();
    super.dispose();
  }

  Future<void> _handleModeChange(String newMode) async {
    if (_attendanceMode == newMode) return;

    final confirmed = await ModeConfirmationDialog.show(
      context: context,
      currentMode: _attendanceMode,
      newMode: newMode,
      onConfirm: () {
        setState(() => _attendanceMode = newMode);
      },
    );

    if (confirmed != true) return;
  }

  Future<Map<String, dynamic>?> _findMemberByCard(String cardNumber) async {
    final orgId = _organizationId;
    if (orgId == null) return null;

    try {
      Map<String, dynamic>? cardData;
      
      debugPrint('🔍 Searching for card: $cardNumber (Online: $_isOnline)');
      
      // Try online first if connected
      if (_isOnline) {
        try {
          cardData = await _supabase
              .from('rfid_cards')
              .select('''
              id, card_number, organization_member_id,
              organization_members!inner(
                id, organization_id, user_id, department_id,
                user_profiles (display_name, first_name, last_name, profile_photo_url),
                departments (id, name)
              )
            ''')
              .eq('card_number', cardNumber)
              .eq('organization_members.organization_id', orgId)
              .eq('is_active', true)
              .maybeSingle();
          
          if (cardData != null) {
            debugPrint('✅ Found card online, caching data...');
            await _offlineDb.cacheMemberData(cardData);
            
            final memberInfo = cardData['organization_members'] as Map<String, dynamic>?;
            final userName = _composeMemberName(memberInfo);
            debugPrint('👤 Member name: $userName');
          }
        } catch (e) {
          debugPrint('❌ Error finding card online: $e');
          // Fall back to cache if online fails
        }
      }
      
      // If online failed or offline, try cache
      if (cardData == null) {
        debugPrint('🔍 Searching in offline cache...');
        cardData = await _offlineDb.findMemberByCardInCache(cardNumber, orgId);
        if (cardData != null) {
          final memberInfo = cardData['organization_members'] as Map<String, dynamic>?;
          final userName = _composeMemberName(memberInfo);
          debugPrint('✅ Found member in cache: $userName');
        } else {
          debugPrint('❌ Card not found in cache');
        }
      }
      
      return cardData;
    } catch (e) {
      debugPrint('❌ Error finding card: $e');
      return null;
    }
  }

  Future<void> _handleCardScan() async {
    final cardNumber = _cardController.text.trim();
    if (cardNumber.isEmpty) return;

    debugPrint('📱 Card scanned: $cardNumber');

    try {
      final cardData = await _findMemberByCard(cardNumber);
      if (cardData == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Kartu RFID tidak terdaftar'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final memberInfo = cardData['organization_members'] as Map<String, dynamic>? ?? {};
      final memberId = cardData['organization_member_id'] as int? ?? memberInfo['id'] as int?;

      if (memberId == null) {
        debugPrint('❌ Member ID not found');
        return;
      }

      final memberOrgId = memberInfo['organization_id'] as int?;
      if (memberOrgId != _organizationId) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kartu tidak terdaftar di organisasi ini'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final action = _attendanceMode;
      final workTimeMode = _getWorkTimeMode();
      final userName = _composeMemberName(memberInfo);
      
      // Check for duplicate attendance
      final todayStr = TimezoneHelper.getCurrentDateInOrgTimezone(_organizationTimezone);
      bool hasDuplicate = false;

      // Check online database first if online (more accurate and real-time)
      if (_isOnline) {
        try {
          final existingRecord = await _supabase
              .from('attendance_records')
              .select('id, actual_check_in, actual_check_out')
              .eq('organization_member_id', memberId)
              .eq('attendance_date', todayStr)
              .maybeSingle();

          if (existingRecord != null) {
            if (action == 'check_in' && existingRecord['actual_check_in'] != null) {
              hasDuplicate = true;
              debugPrint('⚠️ Duplicate check_in found online for member $memberId on $todayStr');
            } else if (action == 'check_out' && existingRecord['actual_check_out'] != null) {
              hasDuplicate = true;
              debugPrint('⚠️ Duplicate check_out found online for member $memberId on $todayStr');
            }
          }
        } catch (e) {
          debugPrint('Error checking online duplicate: $e');
          // If online check fails, continue to check offline
        }
      }

      // Check offline database if not found duplicate online or if offline
      if (!hasDuplicate) {
        hasDuplicate = await _offlineDb.hasDuplicateAttendance(
          organizationMemberId: memberId,
          eventType: action,
          attendanceDate: todayStr,
        );
        
        if (hasDuplicate) {
          debugPrint('⚠️ Duplicate $action found offline for member $memberId on $todayStr');
        }
      }

      // Show popup if duplicate found (both online and offline)
      if (hasDuplicate) {
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (context) => AlertDialog(
              title: const Text('Peringatan'),
              content: const Text('Data absennya udah ada'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
        return;
      }
      
      debugPrint('💾 Saving attendance: $userName ($action, $workTimeMode)');
      
      // Save to offline database
      final offlineAttendance = OfflineAttendance(
        cardNumber: cardNumber,
        eventType: action,
        method: 'rfid_card_mobile',
        timestamp: DateTime.now().toUtc().toIso8601String(),
        workTimeMode: workTimeMode,
        organizationMemberId: memberId,
        userName: userName,
      );
      
      await _offlineDb.insertAttendance(offlineAttendance);
      await _loadPendingSyncCount();

      debugPrint('✅ Attendance saved successfully');

      // If online, sync will happen automatically via timer
      await SoundHelper.playSuccessSound();

      if (!mounted) return;
      setState(() {
        final newEntry = _AttendanceEntry(
          memberId: memberId,
          memberInfo: memberInfo,
          cardNumber: cardNumber,
          action: action,
          timestamp: DateTime.now(),
          workTimeMode: workTimeMode,
        );

        final existingIndex = _entries.indexWhere((e) => e.memberId == memberId);
        if (existingIndex >= 0) _entries.removeAt(existingIndex);
        _entries.insert(0, newEntry);
      });
      
    } catch (e) {
      debugPrint('❌ Error card scan: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _cardController.clear();
      _cardFocusNode.requestFocus();
    }
  }

  Future<void> _showSyncDialog() async {
    final stats = await _syncService.getSyncStats();
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Sinkronisasi Data'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total pending: ${stats['pending'] ?? 0}'),
            Text('Berhasil: ${stats['synced'] ?? 0}'),
            Text('Gagal: ${stats['failed'] ?? 0}'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await _syncService.syncAllPendingAttendances();
                await _loadPendingSyncCount();
              },
              child: const Text('Mulai Sinkronisasi'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
        ],
      ),
    );
  }

  String _composeMemberName(Map<String, dynamic>? memberInfo) {
    final profile = memberInfo?['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) {
      debugPrint('⚠️ No user profile found, using "Anggota"');
      return 'Anggota';
    }
    
    final displayName = (profile['display_name'] as String?)?.trim();
    if (displayName != null && displayName.isNotEmpty) {
      return displayName;
    }
    
    final first = profile['first_name'] as String? ?? '';
    final last = profile['last_name'] as String? ?? '';
    final name = '$first $last'.trim();
    
    if (name.isEmpty) {
      debugPrint('⚠️ No name found, using "Anggota"');
      return 'Anggota';
    }
    
    return name;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    return '${time.hour.toString().padLeft(2, '0')}:'
           '${time.minute.toString().padLeft(2, '0')}:'
           '${time.second.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime? time) => _formatTime(time);

  String _formatDate(DateTime? time) {
    if (time == null) return '-';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${time.day.toString().padLeft(2, '0')} ${months[time.month - 1]} ${time.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(
          _organizationName.isEmpty ? 'RFID Attendance' : _organizationName,
          style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        foregroundColor: Colors.white,
        leadingWidth: 48,
        titleSpacing: 8,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_note),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ManualCheckPage(
                    organizationMemberId: widget.organizationMemberId,
                    memberData: widget.memberData,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => _cardFocusNode.requestFocus(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _buildClockAndModeCard(),
              const SizedBox(height: 16),
              Offstage(
                offstage: true,
                child: TextField(
                  controller: _cardController,
                  focusNode: _cardFocusNode,
                  showCursor: false,
                  enableInteractiveSelection: false,
                  decoration: const InputDecoration(border: InputBorder.none),
                  onSubmitted: (_) => _handleCardScan(),
                ),
              ),
              Expanded(
                child: _filteredEntries.isEmpty
                    ? const Center(
                        child: Text(
                          'Scan kartu di sini',
                          style: TextStyle(
                            color: Colors.grey,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredEntries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, index) => _buildEntryCard(_filteredEntries[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClockAndModeCard() {
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
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 20,
            offset: const Offset(0, 8),
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatDateTime(orgTime),
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF9333EA),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(orgTime),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _getWorkTimeMode() == 'break_time' ? 'Break time' : 'Work time',
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
          if (!_isOnline || _pendingSyncCount > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _isOnline ? Colors.orange.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isOnline ? Colors.orange.shade200 : Colors.red.shade200,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isOnline ? Icons.cloud_queue : Icons.cloud_off,
                    size: 16,
                    color: _isOnline ? Colors.orange : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isOnline 
                          ? 'Mode Online - $_pendingSyncCount data pending'
                          : 'Mode Offline - Data akan tersinkron otomatis',
                      style: TextStyle(
                        fontSize: 12,
                        color: _isOnline ? Colors.orange.shade900 : Colors.red.shade900,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToggleButton(String label, String mode) {
    final isSelected = _attendanceMode == mode;
    final buttonColor = mode == 'check_in' ? Colors.green : Colors.red;

    return GestureDetector(
      onTap: () => _handleModeChange(mode),
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

  Widget _buildEntryCard(_AttendanceEntry entry) {
    final memberName = _composeMemberName(entry.memberInfo);
    final profile = entry.memberInfo['user_profiles'] as Map<String, dynamic>? ?? {};
    final photoPath = profile['profile_photo_url'] as String?;
    
    final department = entry.memberInfo['departments'] as Map<String, dynamic>?;
    final departmentName = department?['name'] as String? ?? '-';

    // Use icon when offline or when photo is not available
    final bool useIcon = _isOnline == false || photoPath == null || photoPath.trim().isEmpty;

    ImageProvider? imageProvider;
    if (!useIcon && photoPath != null) {
      if (photoPath.startsWith('http')) {
        imageProvider = NetworkImage(photoPath);
      } else {
        imageProvider = NetworkImage(
          _supabase.storage.from('profile-photos').getPublicUrl('mass-profile/$photoPath'),
        );
      }
    }

    final isCheckIn = entry.action == 'check_in';
    final timeString = _formatTime(entry.timestamp);
    final workTimeMode = entry.workTimeMode ?? 'work_time';
    final modePrefix = workTimeMode == 'break_time' ? 'Break time in' : 'Work time in';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          useIcon
              ? Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.person,
                    size: 28,
                    color: Colors.grey.shade600,
                  ),
                )
              : CircleAvatar(
                  radius: 24,
                  backgroundImage: imageProvider,
                  onBackgroundImageError: (_, __) {
                    // Fallback to icon if image fails to load
                  },
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  memberName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$modePrefix - $departmentName',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isCheckIn ? Colors.green.shade50 : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  isCheckIn ? 'IN' : 'OUT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isCheckIn ? Colors.green.shade800 : Colors.blue.shade800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                timeString,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final currentMode = _getWorkTimeMode();
    final isAutoMode = _workTimeMode == null;
    
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(80, 50, 0, 0),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'work_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'work_time' && !isAutoMode 
                    ? Icons.radio_button_checked 
                    : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Work time', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'break_time',
          child: Row(
            children: [
              Icon(
                currentMode == 'break_time' && !isAutoMode 
                    ? Icons.radio_button_checked 
                    : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Break time', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'auto',
          child: Row(
            children: [
              Icon(
                isAutoMode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('Auto (berdasarkan jadwal)', style: TextStyle(fontSize: 14)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'sign_data',
          child: Row(
            children: [
              Icon(
                _pendingSyncCount > 0 ? Icons.sync_problem : Icons.sync,
                color: _pendingSyncCount > 0 ? Colors.orange : const Color(0xFF9333EA),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Sinkronisasi data${_pendingSyncCount > 0 ? ' ($_pendingSyncCount)' : ''}',
                style: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value != null) _handleMenuSelection(value);
    });
  }

  void _handleMenuSelection(String value) {
    switch (value) {
      case 'work_time':
        setState(() => _workTimeMode = 'work_time');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Work time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'break_time':
        setState(() => _workTimeMode = 'break_time');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Break time'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'auto':
        setState(() => _workTimeMode = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mode diubah ke Auto (berdasarkan jadwal)'),
            backgroundColor: Color(0xFF9333EA),
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case 'sign_data':
        _showSyncDialog();
        break;
    }
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final String cardNumber;
  final String action;
  final DateTime timestamp;
  final String? workTimeMode;

  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.cardNumber,
    required this.action,
    required this.timestamp,
    this.workTimeMode,
  });
}