// lib/attendance/screens/fingerprint_registration_page.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/fingerprint_service.dart';
import '../services/biometric_service.dart';

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

  String _instructionText =
      'Ketuk tombol Mulai untuk mendaftarkan sidik jari Anda.';
  Uint8List? _currentImage;
  bool _isScannerStarted = false;
  bool _isRegistering = false;
  int _registrationStep = 0; // 0: Idle, 1, 2, 3: Scans

  AnimationController? _pulseController;
  StreamSubscription? _statusSubscription;
  StreamSubscription? _imageSubscription;
  StreamSubscription? _registerSubscription;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _initScanner();
  }

  @override
  void dispose() {
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
          _instructionText = 'Pendaftaran Berhasil!';
        });
        await _saveFingerprintTemplate(template);
      }
    });

    final result = await _fingerprintService.startScanner();
    if (result == 'success') {
      if (mounted) {
        setState(() {
          _isScannerStarted = true;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isScannerStarted = false;
        });
      }
    }
  }

  void _handleStatusUpdates(String status) {
    final lowerStatus = status.toLowerCase();

    // Ignore transient capture/extract errors during active registration unless terminal
    if (_isRegistering &&
        (lowerStatus.contains('capture error') ||
            lowerStatus.contains('extract error'))) {
      if (lowerStatus.contains('not found')) {
        _instructionText = 'Scanner terputus. Pastikan kabel terpasang.';
        _isRegistering = false;
      }
      return;
    }

    if (status.contains('Press finger')) {
      if (status.contains('1/3')) {
        _registrationStep = 1;
        _instructionText = 'Tempelkan Jari Anda (Kali Pertama)';
      } else if (status.contains('2/3')) {
        _registrationStep = 2;
        _instructionText = 'Tempelkan Jari yang SAMA (Kali Kedua)';
      } else if (status.contains('3/3')) {
        _registrationStep = 3;
        _instructionText = 'Tempelkan Sekali Lagi (Terakhir)';
      } else {
        if (_registrationStep == 0) _registrationStep = 1;
        _instructionText = 'Tempelkan jari pada sensor...';
      }
    } else if (status.contains('Lift finger')) {
      _instructionText = 'Angkat Jari Anda sebentar...';
    } else if (status.contains('Registration successful')) {
      _instructionText = 'Pendaftaran Selesai!';
      _registrationStep = 3;
    } else if (status.contains('already enrolled')) {
      _instructionText = 'Sidik Jari ini sudah terdaftar sebelumnya.';
      _isRegistering = false;
    } else if (status.contains('Please press same finger')) {
      _instructionText = 'Gagal: Harus menggunakan jari yang sama!';
      _isRegistering = false;
      _registrationStep = 0;
    } else if (lowerStatus.contains('failed')) {
      if (lowerStatus.contains('enroll') ||
          lowerStatus.contains('merge') ||
          lowerStatus.contains('save')) {
        _instructionText = 'Registrasi Gagal. Silakan coba lagi.';
        _isRegistering = false;
        _registrationStep = 0;
      }
    }
  }

  Future<void> _startRegistration() async {
    if (!_isScannerStarted) return;
    setState(() {
      _isRegistering = true;
      _registrationStep = 1;
      _instructionText = 'Tempelkan Jari Anda (Langkah 1 dari 3)';
    });
    await _fingerprintService.register(widget.organizationMemberId.toString());
  }

  Future<void> _saveFingerprintTemplate(String templateData) async {
    try {
      setState(() => _instructionText = 'Menyimpan sidik jari...');
      await _biometricService.registerFingerprintTemplate(
        organizationMemberId: widget.organizationMemberId,
        templateBase64: templateData,
      );
      if (mounted) _showSuccessDialog();
    } catch (e) {
      if (mounted) setState(() => _instructionText = 'Gagal menyimpan: $e');
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 10),
            Text('Berhasil'),
          ],
        ),
        content: const Text(
          'Sidik jari Anda telah berhasil didaftarkan ke sistem.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context, true);
            },
            child: const Text(
              'OK',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF4A1E79),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Registrasi Sidik Jari',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF4A1E79),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            children: [
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
              const SizedBox(height: 8),
              const Text(
                'Ikuti langkah-langkah di bawah untuk mendaftarkan sidik jari Anda.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),

              const Spacer(),

              // STEP INDICATOR
              if (_isRegistering) _buildStepIndicator(),

              const SizedBox(height: 20),

              // FINGERPRINT PREVIEW AREA
              _buildFpPreview(),

              const SizedBox(height: 30),

              // INSTRUCTION TEXT (Large & Bold)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A1E79).withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFF4A1E79).withOpacity(0.1),
                  ),
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

              // ACTION BUTTON
              SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton(
                  onPressed: (_isScannerStarted && !_isRegistering)
                      ? _startRegistration
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4A1E79),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 4,
                    shadowColor: const Color(0xFF4A1E79).withOpacity(0.4),
                  ),
                  child: Text(
                    _isRegistering ? 'Proses Scan...' : 'Mulai Scan Jari',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 15),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Batal',
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
    );
  }

  Widget _buildStepIndicator() {
    return Column(
      children: [
        Text(
          "Langkah $_registrationStep dari 3",
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF4A1E79),
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            bool active = index < _registrationStep;
            bool current = index == (_registrationStep - 1);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: current ? 32 : 12,
              height: 12,
              decoration: BoxDecoration(
                color: active ? const Color(0xFF4A1E79) : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(6),
              ),
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
                color: const Color(0xFF4A1E79).withOpacity(0.1 + (pulse * 0.2)),
                blurRadius: 15 + (pulse * 20),
                spreadRadius: 2 + (pulse * 5),
              ),
            ],
            border: Border.all(
              color: const Color(
                0xFF4A1E79,
              ).withOpacity(_isRegistering ? 0.5 : 0.1),
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
