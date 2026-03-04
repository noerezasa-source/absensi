// lib/attendance/screens/fingerprint_attendance_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';
import '../../helpers/sound_helper.dart';
import '../../helpers/timezone_helper.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';
import '../services/attendance_service.dart';
import '../../models/work_schedule_models.dart';

class FingerprintAttendancePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const FingerprintAttendancePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<FingerprintAttendancePage> createState() =>
      _FingerprintAttendancePageState();
}

class _FingerprintAttendancePageState extends State<FingerprintAttendancePage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final AttendanceService _attendanceService = AttendanceService();
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();

  final List<_AttendanceEntry> _entries = [];
  Timer? _clockTimer;
  DateTime _currentTime = DateTime.now();

  String _attendanceMode = 'check_in';
  Map<String, dynamic>? _selectedMode;
  List<Map<String, dynamic>> _availableModes = [];
  bool _isLoadingModes = false;
  DailySchedule? _dailySchedule;
  String _organizationTimezone = 'Asia/Jakarta';

  // Duplicate Prevention
  final Map<String, DateTime> _lastAttendanceTime = {};
  static const Duration _duplicateCooldown = Duration(minutes: 5);

  // Fingerprint State
  bool _isScannerReady = false;
  String _statusMessage = 'Menghubungkan ke scanner...';
  Uint8List? _capturedImage;
  bool _isProcessing = false;
  List<Map<String, dynamic>> _allTemplates = [];

  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _resultSubscription;

  int? get _organizationId => widget.memberData['organization_id'] as int?;

  @override
  void initState() {
    super.initState();
    _organizationTimezone =
        widget.userProfile?['organization']?['timezone'] ?? 'Asia/Jakarta';
    _startClock();
    _loadAvailableModes();
    _loadMemberSchedule();
    _setupFingerprintListeners();
    _initializeFlow();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _resultSubscription?.cancel();
    _fingerprintService.stopScanner();
    super.dispose();
  }

  void _startClock() {
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });
  }

  Future<void> _loadMemberSchedule() async {
    try {
      final dailySched = await _attendanceService.getTodaySchedule(
        widget.organizationMemberId,
        organizationTimezone: _organizationTimezone,
      );
      if (mounted) setState(() => _dailySchedule = dailySched);
    } catch (e) {
      debugPrint('Error loading schedule: $e');
    }
  }

  ({bool canBreakOut, bool canBreakIn, String? hint})
  _computeBreakButtonState() {
    final schedule = _dailySchedule;
    if (schedule == null)
      return (canBreakOut: false, canBreakIn: false, hint: 'Memuat jadwal...');

    final bStartStr = schedule.breakStart;
    final bEndStr = schedule.breakEnd;
    if (bStartStr == null || bEndStr == null)
      return (
        canBreakOut: false,
        canBreakIn: false,
        hint: 'Tidak ada jadwal istirahat',
      );

    TimeOfDay? parseTime(String s) {
      try {
        final p = s.split(':');
        return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
      } catch (_) {
        return null;
      }
    }

    final bStart = parseTime(bStartStr);
    final bEnd = parseTime(bEndStr);
    if (bStart == null || bEnd == null)
      return (canBreakOut: true, canBreakIn: true, hint: null);

    final now = TimezoneHelper.convertUtcToOrgTimezone(
      DateTime.now().toUtc(),
      _organizationTimezone,
    );
    final nowMin = now.hour * 60 + now.minute;
    final bStartMin = bStart.hour * 60 + bStart.minute;
    final bEndMin = bEnd.hour * 60 + bEnd.minute;

    const window = 30;
    final can = nowMin >= (bStartMin - window) && nowMin <= (bEndMin + window);

    String? hint;
    if (!can) {
      String fmt(TimeOfDay t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      hint = 'Istirahat tersedia pukul ${fmt(bStart)} - ${fmt(bEnd)}';
    }

    return (canBreakOut: can, canBreakIn: can, hint: hint);
  }

  void _setupFingerprintListeners() {
    _statusSubscription = _fingerprintService.onStatusUpdate.listen((status) {
      if (mounted) {
        setState(() {
          _statusMessage = _translateStatus(status);
          if (status.contains('Ready') ||
              status.contains('Identification') ||
              status.contains('connect success')) {
            _isScannerReady = true;
          } else if (status.contains('error') || status.contains('fail')) {
            _isScannerReady = false;
          }
        });
      }
    });

    _imageSubscription = _fingerprintService.onImageCaptured.listen((image) {
      if (mounted) setState(() => _capturedImage = image);
    });

    _resultSubscription = _fingerprintService.onIdentificationResult.listen((
      result,
    ) {
      if (mounted && !_isProcessing) _handleIdentificationMatch(result);
    });
  }

  String _translateStatus(String status) {
    if (status.contains('Identification active') || status.contains('Ready'))
      return 'Siap memindai jari...';
    if (status.contains('connect success')) return 'Scanner terhubung!';
    if (status.contains('connect failed') || status.contains('failed!'))
      return 'Gagal menghubungkan scanner.';
    if (status.contains('Capture error'))
      return status.contains('not found')
          ? 'Scanner tidak terdeteksi.'
          : 'Gagal membaca sidik jari.';
    if (status.contains('Not recognized')) return 'Jari tidak dikenali.';
    if (status.contains('Identify success')) return 'Sidik jari dikenali!';
    return status;
  }

  Future<void> _initializeFlow() async {
    await _loadAllTemplates();
    await _startScanner();
  }

  Future<void> _loadAllTemplates() async {
    final orgId = _organizationId;
    if (orgId == null) return;
    try {
      final templates = await _biometricService
          .getAllActiveFingerprintTemplates(orgId);
      setState(() => _allTemplates = templates);
    } catch (e) {
      debugPrint('Error loading templates: $e');
    }
  }

  Future<void> _startScanner() async {
    try {
      bool permission = await _fingerprintService.requestPermission();
      if (!permission) {
        setState(() => _statusMessage = 'Izin akses USB ditolak');
        return;
      }

      final result = await _fingerprintService.startScanner();
      if (result != 'success') {
        setState(() {
          _statusMessage = result ?? 'Gagal memulai scanner';
          _isScannerReady = false;
        });
        return;
      }

      if (_allTemplates.isNotEmpty) {
        final List<Map<String, dynamic>> formatted = _allTemplates
            .map(
              (t) => {
                'memberId': t['organization_member_id'].toString(),
                'template': t['template_data'],
              },
            )
            .toList();
        await _fingerprintService.loadTemplates(formatted);
        await _fingerprintService.startIdentification();
      } else {
        setState(() => _statusMessage = 'Database sidik jari belum ada');
      }
    } catch (e) {
      setState(() => _statusMessage = 'Terjadi kesalahan sistem: $e');
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
          .select('id, code, name, start_time, end_time')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('name', ascending: true);
      setState(() {
        _availableModes = List<Map<String, dynamic>>.from(modes);
        if (_availableModes.isNotEmpty) _selectedMode = _availableModes.first;
      });
    } catch (e) {
      debugPrint('Error loading modes: $e');
    } finally {
      if (mounted) setState(() => _isLoadingModes = false);
    }
  }

  Future<void> _handleIdentificationMatch(Map<String, dynamic> result) async {
    final mid = int.tryParse(result['memberId']?.toString() ?? '');
    if (mid == null) return;

    final info = _allTemplates.firstWhere(
      (t) => t['organization_member_id'] == mid,
      orElse: () => {},
    );
    if (info.isEmpty) return;

    final action = _attendanceMode;
    final workMode = _selectedMode?['code'] ?? _selectedMode?['name'];
    final cooldownKey = "${mid}_${action}_${workMode}";

    // Check Cooldown
    if (_lastAttendanceTime.containsKey(cooldownKey)) {
      final lastTime = _lastAttendanceTime[cooldownKey]!;
      final diff = DateTime.now().difference(lastTime);
      if (diff < _duplicateCooldown) {
        final remaining = 5 - diff.inMinutes;
        _showDuplicateOverlay(
          "${info['display_name'] ?? 'Member'} sudah absen $action. Coba lagi dalam $remaining menit.",
        );
        return;
      }
    }

    setState(() => _isProcessing = true);
    try {
      await SoundHelper.playSuccessSound();
      _recordAttendance(mid, _organizationTimezone, action, workMode);

      // Update cooldown
      _lastAttendanceTime[cooldownKey] = DateTime.now();

      if (mounted) {
        setState(() {
          _entries.insert(
            0,
            _AttendanceEntry(
              memberId: mid,
              memberInfo: info,
              action: action,
              timestamp: DateTime.now(),
              workTimeMode: workMode,
            ),
          );
          if (_entries.length > 50) _entries.removeRange(50, _entries.length);
        });
      }
    } catch (e) {
      debugPrint('Error: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showDuplicateOverlay(String message) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry oe;
    oe = OverlayEntry(
      builder: (c) => Positioned(
        top: 100,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.orange.shade500, Colors.orange.shade700],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => oe.remove(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(oe);
    Future.delayed(const Duration(seconds: 3), () {
      if (oe.mounted) oe.remove();
    });
  }

  Future<void> _recordAttendance(
    int mid,
    String tz,
    String action,
    String? workMode,
  ) async {
    try {
      switch (action) {
        case 'check_in':
          await _attendanceService.checkInFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
          );
          break;
        case 'check_out':
          await _attendanceService.checkOutFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
          );
          break;
        case 'break_start':
          await _attendanceService.breakOutFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
          );
          break;
        case 'break_end':
          await _attendanceService.breakInFingerprint(
            organizationMemberId: mid,
            organizationTimezone: tz,
          );
          break;
      }
    } catch (e) {
      debugPrint('Record failed: $e');
    }
  }

  String _formatTimeShort(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  String _formatAmPm(DateTime time) => time.hour >= 12 ? 'PM' : 'AM';
  String _formatDate(DateTime time) {
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MEI',
      'JUN',
      'JUL',
      'AGU',
      'SEP',
      'OKT',
      'NOV',
      'DES',
    ];
    return '${time.day} ${months[time.month - 1]} ${time.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 20),
                _buildClockHeader(),
                const SizedBox(height: 30),
                _buildShiftCard(),
                const SizedBox(height: 20),
                // Fingerprint Preview Area Always Visible at Top
                _buildFingerprintPreview(),
                const SizedBox(height: 10),
                Expanded(child: _buildAttendanceList()),
              ],
            ),
          ),
          Positioned(
            top: 40,
            left: 20,
            child: SafeArea(
              child: CircleAvatar(
                backgroundColor: Colors.grey.shade200.withOpacity(0.8),
                radius: 20,
                child: IconButton(
                  icon: const Icon(
                    Icons.chevron_left,
                    color: Colors.black,
                    size: 24,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClockHeader() {
    final t = _formatTimeShort(_currentTime);
    final ap = _formatAmPm(_currentTime);
    final d = _formatDate(_currentTime);
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              ap,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.transparent,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              t,
              style: const TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.w400,
                color: Colors.black87,
                letterSpacing: -2,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              ap,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
        Text(
          d,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _buildShiftCard() {
    String label = 'Select Shift';
    if (_selectedMode != null) {
      String act = _attendanceMode.toUpperCase().replaceAll('_', ' ');
      if (_attendanceMode == 'break_start') act = 'ISTIRAHAT MASUK';
      if (_attendanceMode == 'break_end') act = 'ISTIRAHAT KELUAR';
      if (_attendanceMode == 'check_in') act = 'IN';
      if (_attendanceMode == 'check_out') act = 'OUT';
      label = '${_selectedMode!['name']} - $act';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: InkWell(
        onTap: _openShiftSelectionSheet,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF9333EA), Color(0xFF7E22CE)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF9333EA).withOpacity(0.3),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.swap_horiz,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFingerprintPreview() {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            _buildPulseCircle(140, 0.1),
            _buildPulseCircle(120, 0.05),
            Container(
              width: 100,
              height: 100,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 15,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Center(
                child: _capturedImage != null
                    ? ClipOval(
                        child: Image.memory(
                          _capturedImage!,
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Icon(
                        Icons.fingerprint,
                        size: 60,
                        color: _isScannerReady
                            ? const Color(0xFF9333EA)
                            : Colors.redAccent,
                      ),
              ),
            ),
            if (_isProcessing)
              const SizedBox(
                width: 110,
                height: 110,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF9333EA),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          _statusMessage,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildPulseCircle(double size, double opacity) {
    return TweenAnimationBuilder(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(seconds: 2),
      builder: (context, double value, child) => Container(
        width: size + (value * 15),
        height: size + (value * 15),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF9333EA).withOpacity(opacity * (1 - value)),
            width: 1,
          ),
        ),
      ),
      onEnd: () => setState(() {}),
    );
  }

  Widget _buildAttendanceList() {
    if (_entries.isEmpty)
      return Center(
        child: Text(
          "Belum ada data absen hari ini",
          style: TextStyle(color: Colors.grey.shade400),
        ),
      );
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) => _buildEntryCard(_entries[index]),
    );
  }

  Widget _buildEntryCard(_AttendanceEntry entry) {
    final p = entry.memberInfo['organization_members']?['user_profiles'] ?? {};
    final n = p['display_name'] ?? '${p['first_name']} ${p['last_name']}';
    final photo = p['profile_photo_url'];
    final d =
        entry.memberInfo['organization_members']?['departments']?['name'] ??
        '-';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundImage: photo != null ? NetworkImage(photo) : null,
            child: photo == null ? const Icon(Icons.person, size: 20) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  d,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTimeShort(entry.timestamp),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF9333EA),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              _buildActionBadge(entry.action),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActionBadge(String action) {
    Color color = Colors.green;
    String label = 'MASUK';
    if (action == 'check_out') {
      color = Colors.red;
      label = 'KELUAR';
    }
    if (action == 'break_start') {
      color = Colors.orange;
      label = 'ISTIRAHAT MASUK';
    }
    if (action == 'break_end') {
      color = Colors.blue;
      label = 'ISTIRAHAT KELUAR';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Future<void> _openShiftSelectionSheet() async {
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Select Your Shift',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9333EA),
              ),
            ),
            const SizedBox(height: 24),
            ..._availableModes.map((mode) {
              bool sel = _selectedMode?['id'] == mode['id'];
              return ListTile(
                tileColor: sel ? const Color(0xFFF3E8FF) : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  mode['name'] ?? 'Shift',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: sel ? Colors.black : Colors.black87,
                  ),
                ),
                subtitle: Text('${mode['start_time']} - ${mode['end_time']}'),
                trailing: sel
                    ? const Icon(Icons.check_circle, color: Color(0xFF9333EA))
                    : null,
                onTap: () => Navigator.pop(context, mode),
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _selectedMode = selected);
      await _showInOutSelector();
    }
  }

  Future<void> _showInOutSelector() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
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
              const SizedBox(height: 12),
              StatefulBuilder(
                builder: (context, setState2) {
                  final b = _computeBreakButtonState();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: b.canBreakOut
                                    ? Colors.orange
                                    : Colors.grey.shade400,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                              onPressed: b.canBreakOut
                                  ? () => Navigator.pop(context, 'break_start')
                                  : null,
                              child: Text(
                                AppLanguage.tr('attendance.rfid.break_in'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: b.canBreakIn
                                    ? Colors.blue
                                    : Colors.grey.shade400,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                              onPressed: b.canBreakIn
                                  ? () => Navigator.pop(context, 'break_end')
                                  : null,
                              child: Text(
                                AppLanguage.tr('attendance.rfid.break_out'),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (b.hint != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            b.hint!,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _attendanceMode = picked);
  }
}

class _AttendanceEntry {
  final int memberId;
  final Map<String, dynamic> memberInfo;
  final String action;
  final DateTime timestamp;
  final String? workTimeMode;
  _AttendanceEntry({
    required this.memberId,
    required this.memberInfo,
    required this.action,
    required this.timestamp,
    this.workTimeMode,
  });
}
