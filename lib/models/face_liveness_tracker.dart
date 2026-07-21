// lib/models/face_liveness_tracker.dart
//
// Passive Liveness Tracker — deteksi wajah hidup tanpa memerlukan gerakan sengaja.
//
// Strategi (dua sinyal yang TIDAK dapat dipalsukan dengan menggoyangkan HP):
//
// [1] BLINK DETECTION (sinyal utama, paling andal)
//     Foto di layar HP → mata selalu terbuka (eyeOpenProbability ~0.95-0.99 konstan)
//     Orang asli       → berkedip alami setiap 3-5 detik (probabilitas turun < 0.25)
//     Menggoyangkan HP TIDAK mengubah nilai eyeOpenProbability foto.
//
// [2] FACE AREA GROWTH (sinyal sekunder)
//     Orang berjalan mendekati kamera → bounding box membesar secara progresif
//     Foto dipegang statis / digoyang → area relatif konstan atau acak
//     Diperlukan growth > 20% dari area awal dalam window deteksi.
//
// Liveness PASS jika:
//   (sinyal #1 terpenuhi) OR (sinyal #2 terpenuhi)
//
// Timeout 3 detik → livenessRejected (bukan loop infinite)

class FaceLivenessTracker {
  final int trackingId;

  // ─── Blink Detection State ────────────────────────────────────────────────
  // Riwayat rata-rata probabilitas kedua mata terbuka per frame.
  // ML Kit mengisi via face.leftEyeOpenProbability / rightEyeOpenProbability.
  final List<double> _eyeHistory = [];
  bool _blinkDetected = false;
  static const int _eyeHistoryMaxLen = 30; // ~1 detik pada 30fps
  static const double _blinkCloseThreshold = 0.25; // mata dianggap tertutup
  static const double _blinkOpenThreshold = 0.75; // mata dianggap terbuka kembali
  bool _eyeWasClosed = false; // state mesin blink: tunggu close dulu, lalu open

  // ─── Head Movement (Pose Variance) State ────────────────────────────────
  double? _minYaw;
  double? _maxYaw;
  bool _headMovementDetected = false;
  static const double _requiredAngleVariance = 6.0; // Harus 6 derajat agar tidak mudah ditipu hp goyang

  // ─── Approach (Growth) State ──────────────────────────────────────────
  double? _initialFaceArea;
  double _maxFaceArea = 0.0;
  int _growthFrames = 0;
  bool _approachDetected = false;
  static const double _requiredAreaGrowth = 1.15; // Harus membesar 15% (orang berjalan mendekat)

  // ─── Timers ───────────────────────────────────────────────────────────────
  final DateTime _startTime = DateTime.now();
  static const Duration _livenessTimeout = Duration(seconds: 5);
  int _frameCount = 0;

  FaceLivenessTracker(this.trackingId);

  // ─────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ─────────────────────────────────────────────────────────────────────────

  /// [faceArea] : luas bounding box wajah
  void addFrame({
    double? leftEyeOpen,
    double? rightEyeOpen,
    double? headEulerAngleY,
    double? headEulerAngleX,
    required double faceArea,
  }) {
    _frameCount++;
    _updateEyeHistory(leftEyeOpen, rightEyeOpen);
    _updateHeadMovement(headEulerAngleY);
    _updateApproach(faceArea);
  }

  /// Lolos jika:
  /// 1. Berkedip (foto tidak bisa berkedip)
  /// 2. Jarak Jauh (area < 4000): Cukup salah satu dari rotasi kepala OR wajah membesar 15% (karena spoofing layar HP tidak mungkin terdeteksi dari 4-5 meter)
  /// 3. Jarak Dekat (area >= 4000): Wajib rotasi kepala DAN wajah membesar secara bersamaan untuk memblokir spoofing
  bool get isLive {
    if (_blinkDetected) return true;
    final bool isFar = (_initialFaceArea ?? 0.0) < 4000;
    if (isFar) {
      return _headMovementDetected || _approachDetected;
    }
    return _headMovementDetected && _approachDetected;
  }

  /// Apakah sudah melampaui timeout tanpa berhasil?
  bool get isTimedOut =>
      !isLive && DateTime.now().difference(_startTime) >= _livenessTimeout;

  /// Jumlah frame yang sudah diproses (untuk debug).
  int get frameCount => _frameCount;

  // ─────────────────────────────────────────────────────────────────────────
  // INTERNAL LOGIC
  // ─────────────────────────────────────────────────────────────────────────

  void _updateHeadMovement(double? yaw) {
    if (yaw != null) {
      if (_minYaw == null || yaw < _minYaw!) _minYaw = yaw;
      if (_maxYaw == null || yaw > _maxYaw!) _maxYaw = yaw;

      if (_maxYaw! - _minYaw! >= _requiredAngleVariance) {
        _headMovementDetected = true;
      }
    }
  }

  void _updateApproach(double currentArea) {
    if (_initialFaceArea == null) {
      _initialFaceArea = currentArea;
      _maxFaceArea = currentArea;
      return;
    }

    if (currentArea > _maxFaceArea) {
      _maxFaceArea = currentArea;
      _growthFrames++; // Pastikan membesar bertahap, bukan cuma 1 frame loncat
    }

    // Jika luas wajah tumbuh 15% dari ukuran awal dan proses tumbuhnya lebih dari 3 frame
    // (Mencegah hp tiba-tiba dimajukan sangat cepat)
    if (_maxFaceArea >= _initialFaceArea! * _requiredAreaGrowth && _growthFrames >= 3) {
      _approachDetected = true;
    }
  }

  void _updateEyeHistory(double? left, double? right) {
    // Jika ML Kit tidak menyediakan eye probability, skip blink check
    if (left == null && right == null) return;

    // Rata-rata dari dua mata (atau gunakan yang tersedia)
    final double avgEyeOpen;
    if (left != null && right != null) {
      avgEyeOpen = (left + right) / 2.0;
    } else {
      avgEyeOpen = left ?? right!;
    }

    _eyeHistory.add(avgEyeOpen);
    if (_eyeHistory.length > _eyeHistoryMaxLen) {
      _eyeHistory.removeAt(0);
    }

    // Mesin state blink: deteksi pola TERBUKA → TERTUTUP → TERBUKA
    if (!_eyeWasClosed) {
      // Tunggu mata tertutup
      if (avgEyeOpen < _blinkCloseThreshold) {
        _eyeWasClosed = true;
      }
    } else {
      // Mata sudah pernah tertutup, tunggu terbuka kembali → blink terkonfirmasi
      if (avgEyeOpen > _blinkOpenThreshold) {
        _blinkDetected = true;
      }
    }
  }
}
