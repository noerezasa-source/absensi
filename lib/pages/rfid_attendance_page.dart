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
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  DateTime _currentTime = DateTime.now();
  
  String? _workTimeMode;
  Map<String, dynamic>? _memberSchedule;
  Timer? _scheduleCheckTimer;

  bool _isOnline = true;
  int _pendingSyncCount = 0;
  StreamSubscription<SyncStatus>? _syncStatusSub;

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
    _syncStatusSub = _syncService.syncStatusStream.listen((status) {
      if (mounted) _loadPendingSyncCount();
    });
    
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
      
      // Trigger initial mode selection after page loads
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _loadAvailableModes();
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
      if (mounted) {
        _updateModeBasedOnSchedule();
        if (_workTimeMode == null) setState(() {});
      }
    });
  }

  void _updateModeBasedOnSchedule() {
    if (_memberSchedule == null || _availableModes.isEmpty) return;
    
    final newWorkTimeMode = _getWorkTimeMode();
    if (newWorkTimeMode != _workTimeMode) {
      setState(() {
        _workTimeMode = newWorkTimeMode;
        // Auto-select mode based on work time mode
        _autoSelectModeFromWorkTimeMode();
      });
    }
    
    // Also check if we need to auto-select mode even if work time mode hasn't changed
    // This handles the case when modes are loaded after schedule is set
    if (_selectedMode == null && _availableModes.isNotEmpty) {
      _autoSelectModeFromWorkTimeMode();
    }
  }

  void _autoSelectModeFromWorkTimeMode() {
    if (_workTimeMode == null || _availableModes.isEmpty) return;
    
    // Find matching mode based on work time mode
    Map<String, dynamic>? matchingMode;
    for (var mode in _availableModes) {
      final modeCode = mode['code'] as String? ?? mode['name'] as String? ?? '';
      final modeName = mode['name'] as String? ?? '';
      
      if (_workTimeMode == 'break_time' && 
          (modeCode.toLowerCase().contains('break') || modeName.toLowerCase().contains('break'))) {
        matchingMode = mode;
        break;
      } else if (_workTimeMode == 'work_time' && 
          (modeCode.toLowerCase().contains('work') || modeName.toLowerCase().contains('kerja'))) {
        matchingMode = mode;
        break;
      } else if (_workTimeMode == 'overtime' && 
          (modeCode.toLowerCase().contains('overtime') || modeName.toLowerCase().contains('lembur'))) {
        matchingMode = mode;
        break;
      }
    }
    
    // If no specific match, select the first available mode
    if (matchingMode == null && _availableModes.isNotEmpty) {
      matchingMode = _availableModes.first;
    }
    
    if (matchingMode != null && _selectedMode?['id'] != matchingMode['id']) {
      setState(() {
        _selectedMode = matchingMode;
        _workTimeMode = matchingMode?['code'] as String? ?? matchingMode?['name'] as String? ?? _workTimeMode;
      });
    }
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
        final scheduleMap = schedule;
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
          final scheduleDataMap = scheduleData;
          setState(() {
            _memberSchedule = Map<String, dynamic>.from(scheduleMap)..addAll(scheduleDataMap);
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading schedule: $e');
    }
  }

  Future<void> _loadAvailableModes() async {
    if (_isLoadingModes) return;
    final orgId = _organizationId;
    if (orgId == null) return;

    setState(() => _isLoadingModes = true);
    try {
      final modes = await _supabase
          .from('shifts')
          .select('id, code, name, start_time, end_time, description')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('name', ascending: true);

      setState(() {
        _availableModes = List<Map<String, dynamic>>.from(modes);
      });
    } catch (e) {
      debugPrint('Error loading modes: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memuat mode: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingModes = false);
        // Trigger auto mode selection after modes are loaded
        _updateModeBasedOnSchedule();
      }
    }
  }

  Future<void> _openModePicker() async {
    await _loadAvailableModes();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'Pilih Mode Shift',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoadingModes)
                    const Expanded(child: Center(child: CircularProgressIndicator()))
                  else if (_availableModes.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Belum ada mode shift tersedia',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _availableModes.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, index) {
                          final mode = _availableModes[index];
                          final start = mode['start_time'] as String?;
                          final end = mode['end_time'] as String?;
                          final isSelected = _selectedMode?['id'] == mode['id'];
                          
                          return ListTile(
                            title: Text(
                              mode['name'] ?? '-',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: start != null && end != null
                                ? Text('$start - $end')
                                : null,
                            trailing: isSelected
                                ? const Icon(Icons.check_circle, color: Colors.green)
                                : null,
                            onTap: () => Navigator.of(context).pop(mode),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedMode = selected;
        _workTimeMode = selected['code'] as String? ?? selected['name'] as String?;
      });
      await _showInOutSelector();
    }
  }

  Future<void> _showInOutSelector() async {
    if (!mounted) return;
    final pickedMode = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_in'),
                        child: const Text('IN'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => Navigator.pop(context, 'check_out'),
                        child: const Text('OUT'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    if (pickedMode != null && mounted) {
      setState(() => _attendanceMode = pickedMode);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Mode ${pickedMode == 'check_in' ? 'IN' : 'OUT'} dipilih'
            '${_selectedMode != null ? ' • ${_selectedMode!['name']}' : ''}',
          ),
          backgroundColor: const Color(0xFF9333EA),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  String _currentModeLabel() {
    final modeName = _selectedMode?['name'] as String?;
    if (modeName == null || modeName.isEmpty) return 'Mode belum dipilih';
    return 'Mode: $modeName';
  }

  String _attendanceModeLabel() {
    return _attendanceMode == 'check_in' ? 'IN' : 'OUT';
  }

  String _modeButtonLabel() {
    final modeName = _selectedMode?['name'] as String?;
    return (modeName == null || modeName.isEmpty) ? 'Pilih mode' : modeName;
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
            departments!organization_members_department_id_fkey (id, name)
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
    _syncStatusSub?.cancel();
    _cardController.dispose();
    _cardFocusNode.dispose();
    _syncService.stopAutoSync();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _findMemberByCard(String cardNumber) async {
    final orgId = _organizationId;
    if (orgId == null) {
      debugPrint('❌ Organization ID is null');
      return null;
    }

    // Normalize card number (trim whitespace)
    final normalizedCardNumber = cardNumber.trim();
    if (normalizedCardNumber.isEmpty) {
      debugPrint('❌ Card number is empty after normalization');
      return null;
    }

    try {
      Map<String, dynamic>? cardData;
      
      debugPrint('🔍 Searching for card: "$normalizedCardNumber" (Org ID: $orgId, Online: $_isOnline)');
      
      // Try online first if connected
      if (_isOnline) {
        try {
          // First, try to find the card directly
          final cardResult = await _supabase
              .from('rfid_cards')
              .select('id, card_number, organization_member_id, is_active')
              .eq('card_number', normalizedCardNumber)
              .eq('is_active', true)
              .maybeSingle();
          
          debugPrint('📋 Card query result: ${cardResult != null ? "Found" : "Not found"}');
          
          if (cardResult != null) {
            final memberId = cardResult['organization_member_id'] as int?;
            debugPrint('👤 Found member ID: $memberId');
            
            if (memberId != null) {
              // Now fetch the full member data with organization check
              final memberData = await _supabase
                  .from('organization_members')
                  .select('''
                    id, organization_id, user_id, department_id,
                    user_profiles (display_name, first_name, last_name, profile_photo_url),
                    departments!organization_members_department_id_fkey (id, name)
                  ''')
                  .eq('id', memberId)
                  .eq('organization_id', orgId)
                  .eq('is_active', true)
                  .maybeSingle();
              
              debugPrint('👥 Member data query result: ${memberData != null ? "Found" : "Not found"}');
              
              if (memberData != null) {
                // Construct cardData in the expected format
                cardData = {
                  'id': cardResult['id'],
                  'card_number': cardResult['card_number'],
                  'organization_member_id': memberId,
                  'organization_members': memberData,
                };
                
                debugPrint('✅ Found card online, caching data...');
                await _offlineDb.cacheMemberData(cardData);
                
                final userName = _composeMemberName(memberData);
                debugPrint('👤 Member name: $userName');
              } else {
                debugPrint('⚠️ Member $memberId not found or not in organization $orgId or inactive');
              }
            } else {
              debugPrint('⚠️ Card found but organization_member_id is null');
            }
          } else {
            debugPrint('⚠️ Card "$normalizedCardNumber" not found in rfid_cards table or inactive');
            
            // Try case-insensitive search as fallback
            debugPrint('🔍 Trying case-insensitive search...');
            final allCards = await _supabase
                .from('rfid_cards')
                .select('id, card_number, organization_member_id, is_active')
                .eq('is_active', true)
                .limit(1000); // Reasonable limit
            
            final matchingCard = allCards.firstWhere(
              (card) => (card['card_number'] as String?)?.trim().toLowerCase() == normalizedCardNumber.toLowerCase(),
              orElse: () => {},
            );
            
            if (matchingCard.isNotEmpty) {
              debugPrint('✅ Found card with case-insensitive match: ${matchingCard['card_number']}');
              final memberId = matchingCard['organization_member_id'] as int?;
              
              if (memberId != null) {
                final memberData = await _supabase
                    .from('organization_members')
                    .select('''
                      id, organization_id, user_id, department_id,
                      user_profiles (display_name, first_name, last_name, profile_photo_url),
                      departments!organization_members_department_id_fkey (id, name)
                    ''')
                    .eq('id', memberId)
                    .eq('organization_id', orgId)
                    .eq('is_active', true)
                    .maybeSingle();
                
                if (memberData != null) {
                  cardData = {
                    'id': matchingCard['id'],
                    'card_number': matchingCard['card_number'],
                    'organization_member_id': memberId,
                    'organization_members': memberData,
                  };
                  
                  debugPrint('✅ Found card with case-insensitive match, caching...');
                  await _offlineDb.cacheMemberData(cardData);
                }
              }
            }
          }
        } catch (e, stackTrace) {
          debugPrint('❌ Error finding card online: $e');
          debugPrint('Stack trace: $stackTrace');
          // Fall back to cache if online fails
        }
      }
      
      // If online failed or offline, try cache
      if (cardData == null) {
        debugPrint('🔍 Searching in offline cache...');
        cardData = await _offlineDb.findMemberByCardInCache(normalizedCardNumber, orgId);
        if (cardData != null) {
          // Additional validation: if online, verify card still exists in server
          if (_isOnline) {
            debugPrint('⚠️ Found in cache but online - verifying card still exists...');
            final serverCardExists = await _supabase
                .from('rfid_cards')
                .select('id')
                .eq('card_number', normalizedCardNumber)
                .eq('is_active', true)
                .maybeSingle();
            
            if (serverCardExists == null) {
              debugPrint('🗑️ Card deleted from server, removing from cache and rejecting');
              await _offlineDb.deleteMemberFromCache(normalizedCardNumber);
              cardData = null;
            } else {
              final memberInfo = cardData['organization_members'] as Map<String, dynamic>?;
              final userName = _composeMemberName(memberInfo);
              debugPrint('✅ Found member in cache: $userName');
            }
          } else {
            final memberInfo = cardData['organization_members'] as Map<String, dynamic>?;
            final userName = _composeMemberName(memberInfo);
            debugPrint('✅ Found member in cache: $userName');
          }
        } else {
          debugPrint('❌ Card not found in cache');
        }
      }
      
      if (cardData == null) {
        debugPrint('❌ Card "$normalizedCardNumber" not found anywhere (online or cache)');
      }
      
      return cardData;
    } catch (e, stackTrace) {
      debugPrint('❌ Error finding card: $e');
      debugPrint('Stack trace: $stackTrace');
      return null;
    }
  }

  void _showDuplicateAlert(String name, String department, String mode) {
    // Show elegant overlay notification instead of snackbar
    if (!mounted) return;
    
    final overlay = Overlay.of(context);
    late OverlayEntry overlayEntry;
    
    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: 100,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.orange.shade500, Colors.orange.shade600],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sudah Absen',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$name • $mode',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    overlayEntry.remove();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      color: Colors.white.withValues(alpha: 0.8),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    overlay.insert(overlayEntry);
    
    // Auto remove after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (overlayEntry.mounted) {
        overlayEntry.remove();
      }
    });
  }

  Widget _buildInfoRow(IconData icon, String label, String value, {Color? valueColor}) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF9333EA).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: const Color(0xFF9333EA),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: valueColor ?? Colors.black87,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handleCardScan() async {
    final cardNumber = _cardController.text.trim();
    if (cardNumber.isEmpty) {
      debugPrint('⚠️ Empty card number');
      return;
    }

    debugPrint('📱 Card scanned: "$cardNumber"');

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
          final profile = memberInfo['user_profiles'] as Map<String, dynamic>? ?? {};
          final name = userName ?? profile['display_name'] ?? '${profile['first_name'] ?? ''} ${profile['last_name'] ?? ''}'.trim();
          final deptMap = memberInfo['departments'] as Map<String, dynamic>? ?? {};
          final deptName = deptMap['name'] as String? ?? '-';
          final mode = action == 'check_in' ? 'Check In' : 'Check Out';

          _showDuplicateAlert(name, deptName, mode);
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
    return '${time.day} ${months[time.month - 1]} ${time.year}';
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
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 15,
            offset: const Offset(0, 5),
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        children: [
          // Clock Section
          Expanded(
            flex: 3,
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
                const SizedBox(height: 2),
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
          const SizedBox(width: 20),
          // Mode Section
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: _openModePicker,
                  child: Text(
                    _modeButtonLabel(),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF9333EA),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
              ],
            ),
          ),
        ],
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
    
    // Get display mode name - use selected mode if available, otherwise format work time mode
    String displayMode;
    if (_selectedMode != null && _selectedMode!['name'] != null) {
      displayMode = _selectedMode!['name'] as String;
    } else {
      // Fallback to formatted work time mode
      displayMode = workTimeMode == 'break_time' ? 'Break Time' : 
                   workTimeMode == 'overtime' ? 'Overtime' : 'Work Time';
    }
    
    final modePrefix = isCheckIn ? displayMode : '$displayMode Out';

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
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(80, 50, 0, 0),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'mode_picker',
          child: Row(
            children: [
              Icon(Icons.tune, size: 18),
              SizedBox(width: 8),
              Text('Pilih mode'),
            ],
          ),
        ),
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
      case 'mode_picker':
        _openModePicker();
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