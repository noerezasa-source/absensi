// lib/attendance/screens/fingerprint_registration_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';
import '../../helpers/language_helper.dart';
import '../../services/tts_service.dart';

class FingerprintRegistrationPage extends StatefulWidget {
  final int organizationMemberId;
  final String? memberName;

  const FingerprintRegistrationPage({
    super.key,
    required this.organizationMemberId,
    this.memberName,
  });

  @override
  State<FingerprintRegistrationPage> createState() =>
      _FingerprintRegistrationPageState();
}

class _FingerprintRegistrationPageState
    extends State<FingerprintRegistrationPage>
    with SingleTickerProviderStateMixin {
  final FingerprintService _fingerprintService = FingerprintService();
  final BiometricService _biometricService = BiometricService();

  String _instructionText = AppLanguage.tr(
    'attendance.fingerprint.start_instruction',
  );
  Uint8List? _currentImage;
  bool _isScannerStarted = false;
  bool _isRegistering = false;
  int _registrationStep = 0; // 0: Idle, 1, 2, 3: Scans

  AnimationController? _pulseController;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _registerSubscription;

  DateTime? _lastTtsTime;
  DateTime? _lastErrorTtsTime;

  int _currentSpokenStep = 0;

  void _speakGuidanceKey(String key, {bool isNewStep = false, bool isError = false}) {
    final now = DateTime.now();

    if (isError) {
      if (_lastErrorTtsTime == null ||
          now.difference(_lastErrorTtsTime!) >= const Duration(seconds: 5)) {
        _lastErrorTtsTime = now;
        _lastTtsTime = now;
        TtsService().speakKey(key, prefix: 'attendance.fingerprint');
      }
      return;
    }

    if (isNewStep) {
      _lastTtsTime = now;
      TtsService().speakKey(key, prefix: 'attendance.fingerprint');
      return;
    }

    // Reminder (same step) only if 7 seconds of complete silence
    if (_lastTtsTime == null ||
        now.difference(_lastTtsTime!) >= const Duration(seconds: 7)) {
      _lastTtsTime = now;
      TtsService().speakKey(key, prefix: 'attendance.fingerprint');
    }
  }

  void _speakGuidanceText(String text, {bool isError = false}) {
    final now = DateTime.now();

    if (isError) {
      if (_lastErrorTtsTime == null ||
          now.difference(_lastErrorTtsTime!) >= const Duration(seconds: 5)) {
        _lastErrorTtsTime = now;
        _lastTtsTime = now; // Mute reminders for 7 seconds after this error
        TtsService().speak(text);
      }
      return;
    }

    // Normal text reminder
    if (_lastTtsTime == null ||
        now.difference(_lastTtsTime!) >= const Duration(seconds: 7)) {
      _lastTtsTime = now;
      TtsService().speak(text);
    }
  }

  @override
  void initState() {
    super.initState();
    TtsService().initialize();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _initScanner();
  }

  @override
  void dispose() {
    TtsService().stop();
    _statusSubscription?.cancel();
    _imageSubscription?.cancel();
    _registerSubscription?.cancel();
    _pulseController?.dispose();
    _fingerprintService.stopScanner();
    _fingerprintService.dispose();
    super.dispose();
  }

  Future<void> _initScanner() async {
    _statusSubscription = _fingerprintService.statusStream.listen((status) {
      if (mounted) {
        debugPrint('🔍 Fingerprint Status: $status');
        setState(() {
          _handleStatusUpdates(status);
        });
      }
    });

    _imageSubscription = _fingerprintService.imageStream.listen((image) {
      if (mounted) setState(() => _currentImage = image);
    });

    _registerSubscription = _fingerprintService.registerSuccessStream.listen((
      template,
    ) async {
      if (mounted) {
        setState(() {
          _registrationStep = 3;
          _isRegistering = false;
          _instructionText = AppLanguage.tr(
            'attendance.fingerprint.berhasil_selesai',
          );
        });
        await _saveFingerprintTemplate(template);
      }
    });

    try {
      final result = await _fingerprintService.startScanner();
      if (result == 'success') {
        if (mounted) {
          setState(() {
            _isScannerStarted = true;
            _instructionText = 'Scanner siap digunakan';
          });
          
          // Langsung mulai registrasi tanpa basa-basi (TTS akan dipanggil di _startRegistration)
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted && !_isRegistering) {
            _startRegistration();
          }
        }
      } else {
        // Scanner tidak ditemukan/gagal terhubung
        if (mounted) {
          setState(() {
            _isScannerStarted = false;
            _instructionText = AppLanguage.tr(
              'attendance.fingerprint.scanner_not_found',
            );
            if (_instructionText.contains('scanner_not_found')) {
              // Fallback jika key belum diterjemahkan
              _instructionText =
                  'Scanner tidak terdeteksi. Pastikan perangkat fingerprint terhubung.';
            }
          });
          TtsService().speak(
            'Scanner tidak terdeteksi. Pastikan perangkat fingerprint terhubung.',
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Scanner init error: $e');
      if (mounted) {
        setState(() {
          _isScannerStarted = false;
          _instructionText =
              'Gagal menghubungkan scanner. Periksa koneksi USB.';
        });
        TtsService().speak('Gagal menghubungkan scanner. Periksa koneksi USB.');
      }
    }
  }

  void _handleStatusUpdates(String status) {
    final lowerStatus = status.toLowerCase();

    // ── 1. SCANNER TERPUTUS (device not found) ──
    if (_isRegistering &&
        (lowerStatus.contains('capture error') || lowerStatus.contains('extract error'))) {
      if (lowerStatus.contains('not found')) {
        _instructionText = 'Scanner terputus. Pastikan kabel terpasang.';
        _isRegistering = false;
        _speakGuidanceText('Scanner terputus', isError: true);
      }
      // Capture/extract error TANPA 'not found' = sinyal idle SDK, abaikan.
      return;
    }

    // ── 2. LOGIKA KAGOK: Jari ditempel sekilas lalu diangkat terlalu cepat ──
    if (_isRegistering &&
        (lowerStatus.contains('try again') || lowerStatus.contains('incorrect') || lowerStatus.contains('lifted too fast') || lowerStatus.contains('mismatch'))) {
      _instructionText = 'Jangan langsung diangkat! Tempelkan jari dengan benar dan tahan selama 1-2 detik.';
      _speakGuidanceText(
        'Mohon jangan langsung diangkat. Tempelkan jari dengan benar dan tahan selama satu sampai dua detik.',
        isError: true,
      );
      return;
    }

    // ── 3. PROGRES LANGKAH (Press finger 1/3, 2/3, 3/3) ──
    if (status.contains('Press finger')) {
      if (status.contains('1/3')) {
        _registrationStep = 1;
        _instructionText = 'Silakan tempelkan jari Anda pada alat pemindai, dan tahan.';
        if (_currentSpokenStep != 1) _lastErrorTtsTime = null;
        _speakGuidanceKey('fingerprint_step_1', isNewStep: _currentSpokenStep != 1);
        _currentSpokenStep = 1;
      } else if (status.contains('2/3')) {
        _registrationStep = 2;
        _instructionText = 'Silakan tempelkan jari Anda kembali pada pemindai, dan tahan.';
        if (_currentSpokenStep != 2) _lastErrorTtsTime = null;
        _speakGuidanceKey('fingerprint_step_2', isNewStep: _currentSpokenStep != 2);
        _currentSpokenStep = 2;
      } else if (status.contains('3/3')) {
        _registrationStep = 3;
        _instructionText = 'Silakan tempelkan jari Anda sekali lagi untuk konfirmasi terakhir.';
        if (_currentSpokenStep != 3) _lastErrorTtsTime = null;
        _speakGuidanceKey('fingerprint_step_3', isNewStep: _currentSpokenStep != 3);
        _currentSpokenStep = 3;
      } else {
        if (_registrationStep == 0) _registrationStep = 1;
        _instructionText = 'Silakan tempelkan jari Anda pada alat pemindai, dan tahan.';
        _speakGuidanceKey('fingerprint_step_1', isNewStep: _currentSpokenStep != 1);
        _currentSpokenStep = 1;
      }

    // ── 4. ANGKAT JARI ──
    } else if (status.contains('Lift finger')) {
      _instructionText = AppLanguage.tr('attendance.fingerprint.lift_finger');

    // ── 5. BERHASIL ──
    } else if (status.contains('Registration successful')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.berhasil_selesai',
      );
      _registrationStep = 3;
      _speakGuidanceKey('registration_successful', isNewStep: true);

    // ── 6. SUDAH TERDAFTAR ──
    } else if (status.contains('already enrolled')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.already_enrolled',
      );
      _isRegistering = false;
      _speakGuidanceKey('already_enrolled', isError: true);

    // ── 7. JARI BERBEDA (Dipertahankan untuk kompatibilitas jika masih ada pesan ini, tapi tidak membatalkan) ──
    } else if (status.contains('Please press same finger')) {
      _instructionText = AppLanguage.tr(
        'attendance.fingerprint.not_same_finger',
      );
      // Removed: _isRegistering = false; _registrationStep = 0;
      _speakGuidanceKey('not_same_finger', isError: true);

    // ── 8. GAGAL TOTAL (enroll/merge/save) ──
    } else if (lowerStatus.contains('failed')) {
      if (lowerStatus.contains('enroll') ||
          lowerStatus.contains('merge') ||
          lowerStatus.contains('save')) {
        _instructionText = AppLanguage.tr(
          'attendance.fingerprint.registration_failed',
        );
        _isRegistering = false;
        _registrationStep = 0;
        _currentSpokenStep = 0;
        _speakGuidanceKey('registration_failed', isError: true);
      }

    // ── 9. CATCH-ALL: log status tak tertangkap untuk debugging ──
    } else {
      debugPrint('📋 Unhandled scanner status: "$status"');
    }
  }

  Future<void> _startRegistration() async {
    if (!_isScannerStarted) return;
    setState(() {
      _isRegistering = true;
      _registrationStep = 1;
      _instructionText = AppLanguage.tr('attendance.fingerprint.fingerprint_step_1');
    });

    // Panggil TTS eksplisit di awal agar instruksi bersuara langsung terdengar,
    // hal ini menyelesaikan masalah hening jika SDK terlambat merespon
    _speakGuidanceKey('fingerprint_step_1', isNewStep: true);
    _currentSpokenStep = 1;

    await _fingerprintService.register(widget.organizationMemberId.toString());
  }

  Future<void> _saveFingerprintTemplate(String templateData) async {
    try {
      setState(
        () =>
            _instructionText = AppLanguage.tr('attendance.fingerprint.saving'),
      );
      _speakGuidanceKey('saving');
      await _biometricService.registerFingerprintTemplate(
        organizationMemberId: widget.organizationMemberId,
        templateBase64: templateData,
      );
      if (mounted) {
        _speakGuidanceKey('complete');
        _showSuccessDialog();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _instructionText =
              '${AppLanguage.tr('attendance.fingerprint.registration_failed')}: $e',
        );
        _speakGuidanceKey('registration_failed');
      }
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        // Simpan NavigatorState SEBELUM delay agar tidak ada 'context across async gap'
        final nav = Navigator.of(dialogContext);
        Future.delayed(const Duration(seconds: 2), () {
          if (!mounted) return;
          nav.pop(); // Close dialog
          nav.pop(true); // Return to previous page with success
        });

        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Center(
            child: Text(
              AppLanguage.tr('attendance.fingerprint.success'),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                color: Colors.green,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white,
              const Color(0xFF4A1E79).withValues(alpha: 0.05),
            ],
          ),
        ),
        child: Stack(
          children: [
            // Background logo with transparency
            Positioned.fill(
              child: Opacity(
                opacity: 0.08,
                child: Image.asset(
                  'assets/logo/app_logo_terbaru.png',
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  width: 300,
                  height: 300,
                ),
              ),
            ),
            // Main content
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    // Custom App Bar
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back),
                          color: const Color(0xFF4A1E79),
                        ),
                        Expanded(
                          child: Text(
                            AppLanguage.tr('attendance.fingerprint.registration_title'),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                              color: Color(0xFF4A1E79),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(width: 48), // Balance the back button
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (widget.memberName != null)
                      Text(
                        widget.memberName!,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D1152),
                        ),
                      ),

                    const Spacer(),

                    // STEP INDICATOR
                    if (_isRegistering) _buildStepIndicator(),

                    const SizedBox(height: 10),

                    // FINGERPRINT PREVIEW AREA
                    _buildFpPreview(),

                    const SizedBox(height: 15),

                    // INSTRUCTION TEXT (Large & Bold)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF4A1E79).withValues(alpha: 0.2),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF4A1E79).withValues(alpha: 0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        _instructionText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF4A1E79),
                        ),
                      ),
                    ),

                    const Spacer(),

                    // CANCEL BUTTON ONLY (Registration auto-starts)
                    if (!_isRegistering)
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          AppLanguage.tr('attendance.fingerprint.cancel'),
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    return Column(
      children: [
        Text(
          "${AppLanguage.tr('attendance.fingerprint.step_label')} $_registrationStep ${AppLanguage.tr('attendance.fingerprint.step_from')}",
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF4A1E79),
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 15),
        // Flowchart dengan connecting lines
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            bool completed = index < _registrationStep;
            bool current = index == (_registrationStep - 1);
            
            return Row(
              children: [
                // Step circle
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: completed 
                        ? const Color(0xFF4A1E79)
                        : current
                            ? const Color(0xFF4A1E79).withValues(alpha: 0.3)
                            : Colors.grey.shade300,
                    border: Border.all(
                      color: current 
                          ? const Color(0xFF4A1E79)
                          : Colors.grey.shade400,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: completed
                        ? const Icon(Icons.check, color: Colors.white, size: 28)
                        : Text(
                            '${index + 1}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: current 
                                  ? const Color(0xFF4A1E79)
                                  : Colors.grey.shade600,
                            ),
                          ),
                  ),
                ),
                // Connecting line (except for last step)
                if (index < 2)
                  Container(
                    width: 40,
                    height: 3,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: completed 
                          ? const Color(0xFF4A1E79)
                          : current
                              ? const Color(0xFF4A1E79).withValues(alpha: 0.3)
                              : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
              ],
            );
          }),
        ),
        const SizedBox(height: 10),
        // Step labels
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            bool completed = index < _registrationStep;
            bool current = index == (_registrationStep - 1);
            
            return Row(
              children: [
                SizedBox(
                  width: 50,
                  child: Text(
                    index == 0 ? 'Scan 1' : index == 1 ? 'Scan 2' : 'Scan 3',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: current ? FontWeight.bold : FontWeight.normal,
                      color: completed 
                          ? const Color(0xFF4A1E79)
                          : current
                              ? const Color(0xFF4A1E79)
                              : Colors.grey.shade500,
                    ),
                  ),
                ),
                if (index < 2) const SizedBox(width: 44),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _buildFpPreview() {
    return AnimatedBuilder(
      animation: _pulseController!,
      builder: (context, child) {
        double pulse = _isRegistering ? _pulseController!.value : 0.0;
        return Container(
          width: 180,
          height: 180,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF4A1E79,
                ).withValues(alpha: 0.1 + (pulse * 0.2)),
                blurRadius: 15 + (pulse * 20),
                spreadRadius: 2 + (pulse * 5),
              ),
            ],
            border: Border.all(
              color: const Color(
                0xFF4A1E79,
              ).withValues(alpha: _isRegistering ? 0.5 : 0.1),
              width: 4,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: ClipOval(
              child: _currentImage != null
                  ? Image.memory(_currentImage!, fit: BoxFit.cover)
                  : Center(
                      child: Icon(
                        Icons.fingerprint,
                        size: 90,
                        color: _isRegistering
                            ? const Color(0xFF4A1E79)
                            : Colors.grey.shade300,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
