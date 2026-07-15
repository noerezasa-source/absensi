// lib/services/face_embedding_service.dart
//
// Service untuk Real-Time Face Recognition menggunakan TFLite di Background Isolate.
// Anti-lag karena semua inference berjalan di thread terpisah dari UI.
//
// Model yang dibutuhkan (taruh di assets/models/):
//   - blazeface.tflite     → deteksi wajah (BlazeFace short-range)
//   - mobilefacenet.tflite → ekstraksi 128-dim embedding
//
// Penggunaan:
//   final service = FaceEmbeddingService();
//   await service.initialize(); // di initState()
//   final result = await service.extractEmbedding(imageBytes, width, height);
//   service.dispose(); // di dispose()

import 'dart:async';
import 'dart:isolate';
import 'dart:math' show sqrt;
import 'dart:typed_data'; // Float32List untuk ObjectBox kompatibilitas

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA CLASSES — aman dikirim antar isolate (semua plain Dart objects)
// ─────────────────────────────────────────────────────────────────────────────

/// Hasil inference dari background isolate.
class FaceInferenceResult {
  /// True jika BlazeFace berhasil mendeteksi wajah.
  final bool faceDetected;

  /// 128 angka float (L2-normalized) dari MobileFaceNet.
  /// Float32List agar langsung kompatibel dengan ObjectBox @HnswIndex.
  /// Null jika tidak ada wajah terdeteksi atau terjadi error.
  final Float32List? embedding;

  /// Pesan error jika ada (null = sukses).
  final String? error;

  const FaceInferenceResult({
    required this.faceDetected,
    this.embedding,
    this.error,
  });

  /// Shortcut: apakah embedding valid dan siap digunakan untuk matching?
  bool get isValid => faceDetected && embedding != null && embedding!.length == 128;

  @override
  String toString() =>
      'FaceInferenceResult(detected=$faceDetected, dims=${embedding?.length ?? 0}, '
      'error=$error)';
}

/// Request yang dikirim dari main isolate ke inference isolate.
class _InferenceRequest {
  final SendPort replyPort;
  final Uint8List imageBytes; // RGB24 bytes
  final int imageWidth;
  final int imageHeight;

  const _InferenceRequest({
    required this.replyPort,
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
  });
}

/// Payload inisialisasi untuk Isolate.spawn (harus serializable).
class _IsolateInitPayload {
  final SendPort mainSendPort;
  final RootIsolateToken rootToken;
  final String blazeFaceAssetPath;
  final String mobileFaceNetAssetPath;

  const _IsolateInitPayload({
    required this.mainSendPort,
    required this.rootToken,
    required this.blazeFaceAssetPath,
    required this.mobileFaceNetAssetPath,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN SERVICE
// ─────────────────────────────────────────────────────────────────────────────

/// Service face recognition yang berjalan di Background Isolate.
///
/// Arsitektur:
/// ```
/// UI Thread ──send(request)──► Inference Isolate (TFLite)
///            ◄──send(result)──              │
///                                    BlazeFace (detect)
///                                    MobileFaceNet (embed)
///                                    L2 Normalize → 128-dim
/// ```
///
/// Keuntungan vs menjalankan TFLite di main thread:
/// - Camera preview tetap smooth 30fps
/// - Tidak ada "frozen frame" saat inference
/// - Memory TFLite terisolasi di isolate sendiri
class FaceEmbeddingService {
  // Path asset model — harus sesuai dengan entri di pubspec.yaml
  static const String _blazeFaceAsset = 'assets/models/blazeface.tflite';
  static const String _mobileFaceNetAsset = 'assets/models/mobilefacenet.tflite';

  // Threshold cosine distance untuk menganggap dua wajah "sama".
  // Nilai lebih kecil = lebih ketat. Range yang baik: 0.35 - 0.50
  static const double defaultMatchThreshold = 0.40;

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription? _portSubscription;
  Completer<SendPort>? _handshakeCompleter;

  bool _isInitialized = false;

  /// Apakah service sudah siap menerima request inference.
  bool get isInitialized => _isInitialized;

  // ── INITIALIZE ─────────────────────────────────────────────────────────────

  /// Memuat model BlazeFace dan MobileFaceNet di background isolate.
  ///
  /// Method ini **non-blocking** — UI tidak akan freeze walaupun file model
  /// berukuran beberapa MB. Panggil di [initState] sebelum kamera dibuka.
  ///
  /// Throws [TimeoutException] jika model tidak berhasil dimuat dalam 15 detik.
  /// Throws [Exception] jika file model tidak ditemukan di assets.
  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('ℹ️ FaceEmbeddingService sudah diinisialisasi.');
      return;
    }

    debugPrint('🧠 FaceEmbeddingService: Memulai inisialisasi...');

    final rootToken = RootIsolateToken.instance;
    if (rootToken == null) {
      throw Exception(
        'RootIsolateToken tidak tersedia. '
        'Pastikan initialize() dipanggil dari main thread Flutter.',
      );
    }

    _mainReceivePort = ReceivePort();
    _handshakeCompleter = Completer<SendPort>();

    // Listen ke semua pesan dari isolate
    _portSubscription = _mainReceivePort!.listen((message) {
      if (message is SendPort && !(_handshakeCompleter?.isCompleted ?? true)) {
        // Handshake: isolate mengirim SendPort-nya
        _handshakeCompleter!.complete(message);
      }
      // Pesan inference ditangani via ReceivePort individual di extractEmbedding()
    });

    // Spawn isolate — tidak memblokir UI
    _isolate = await Isolate.spawn(
      _isolateEntryPoint,
      _IsolateInitPayload(
        mainSendPort: _mainReceivePort!.sendPort,
        rootToken: rootToken,
        blazeFaceAssetPath: _blazeFaceAsset,
        mobileFaceNetAssetPath: _mobileFaceNetAsset,
      ),
      debugName: 'FaceEmbeddingIsolate',
    );

    // Tunggu handshake (max 15 detik)
    try {
      _isolateSendPort = await _handshakeCompleter!.future.timeout(
        const Duration(seconds: 15),
      );
      _isInitialized = true;
      debugPrint('✅ FaceEmbeddingService siap. Model dimuat di background isolate.');
    } on TimeoutException {
      await dispose();
      throw TimeoutException(
        'Model TFLite gagal dimuat dalam 15 detik.\n'
        'Pastikan file berikut ada di assets/models/:\n'
        '  - blazeface.tflite\n'
        '  - mobilefacenet.tflite',
      );
    }
  }

  // ── EXTRACT EMBEDDING ──────────────────────────────────────────────────────

  /// Jalankan inference pada satu frame kamera.
  ///
  /// [imageBytes]: raw bytes format RGB24 (3 bytes per pixel).
  /// [imageWidth], [imageHeight]: dimensi asli frame (sebelum resize).
  ///
  /// Returns [FaceInferenceResult] — periksa [isValid] sebelum matching.
  ///
  /// Contoh:
  /// ```dart
  /// final result = await service.extractEmbedding(
  ///   imageBytes: rgbBytes,
  ///   imageWidth: cameraImage.width,
  ///   imageHeight: cameraImage.height,
  /// );
  /// if (result.isValid) {
  ///   // cocokkan result.embedding! dengan ObjectBox KaryawanWajah
  /// }
  /// ```
  Future<FaceInferenceResult> extractEmbedding({
    required Uint8List imageBytes,
    required int imageWidth,
    required int imageHeight,
  }) async {
    if (!_isInitialized || _isolateSendPort == null) {
      return const FaceInferenceResult(
        faceDetected: false,
        error: 'Service belum diinisialisasi. Panggil initialize() terlebih dahulu.',
      );
    }

    // Buat receive port khusus untuk request ini (1 request = 1 port)
    final replyPort = ReceivePort();

    _isolateSendPort!.send(_InferenceRequest(
      replyPort: replyPort.sendPort,
      imageBytes: imageBytes,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    ));

    // Tunggu hasil dari isolate
    final result = await replyPort.first as FaceInferenceResult;
    replyPort.close();
    return result;
  }

  // ── COSINE SIMILARITY HELPER ───────────────────────────────────────────────

  /// Hitung cosine distance antara dua embedding (keduanya harus L2-normalized).
  ///
  /// Menerima Float32List (dari ObjectBox) atau List<double> (dari inference).
  /// Returns nilai antara 0.0 (identik) hingga 2.0 (berlawanan total).
  static double cosineDistance(List<double> a, List<double> b) {
    assert(a.length == b.length, 'Embedding harus memiliki dimensi yang sama');
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
    }
    return 1.0 - dot;
  }

  /// Periksa apakah dua embedding cocok berdasarkan threshold.
  static bool isMatch(
    List<double> queryEmbedding,
    List<double> storedEmbedding, {
    double threshold = defaultMatchThreshold,
  }) {
    return cosineDistance(queryEmbedding, storedEmbedding) < threshold;
  }

  // ── DISPOSE ────────────────────────────────────────────────────────────────

  /// Bersihkan resource. WAJIB dipanggil di [State.dispose].
  Future<void> dispose() async {
    _isInitialized = false;
    await _portSubscription?.cancel();
    _mainReceivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _mainReceivePort = null;
    _handshakeCompleter = null;
    debugPrint('🔴 FaceEmbeddingService: Disposed.');
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ISOLATE CODE — berjalan di thread terpisah (bukan UI thread)
  // ─────────────────────────────────────────────────────────────────────────

  /// Entry point untuk background isolate.
  /// Static method agar bisa di-spawn oleh [Isolate.spawn].
  static Future<void> _isolateEntryPoint(_IsolateInitPayload payload) async {
    // WAJIB: daftarkan token agar bisa mengakses rootBundle dari isolate
    BackgroundIsolateBinaryMessenger.ensureInitialized(payload.rootToken);

    // Setup receive port untuk menerima request dari main isolate
    final receivePort = ReceivePort();

    // Kirim sendPort ke main isolate sebagai handshake
    payload.mainSendPort.send(receivePort.sendPort);

    // Load kedua model
    Interpreter? blazeFace;
    Interpreter? mobileFaceNet;

    try {
      debugPrint('[Isolate] 🔄 Memuat blazeface.tflite...');
      final blazeFaceData = await rootBundle.load(payload.blazeFaceAssetPath);
      blazeFace = Interpreter.fromBuffer(
        blazeFaceData.buffer.asUint8List(),
        options: InterpreterOptions()..threads = 2,
      );
      debugPrint('[Isolate] ✅ blazeface.tflite dimuat.');

      debugPrint('[Isolate] 🔄 Memuat mobilefacenet.tflite...');
      final mobileFaceNetData = await rootBundle.load(payload.mobileFaceNetAssetPath);
      mobileFaceNet = Interpreter.fromBuffer(
        mobileFaceNetData.buffer.asUint8List(),
        options: InterpreterOptions()..threads = 2,
      );
      debugPrint('[Isolate] ✅ mobilefacenet.tflite dimuat. Siap inference.');
    } catch (e) {
      debugPrint('[Isolate] ❌ Gagal memuat model: $e');
      // Isolate tetap jalan — setiap request akan return error
    }

    // Event loop: proses request inference satu per satu
    await for (final message in receivePort) {
      if (message is _InferenceRequest) {
        final result = _runInference(
          request: message,
          blazeFace: blazeFace,
          mobileFaceNet: mobileFaceNet,
        );
        // Kirim hasil kembali ke pengirim (replyPort spesifik request ini)
        message.replyPort.send(result);
      }
    }

    // Cleanup ketika isolate dihentikan
    blazeFace?.close();
    mobileFaceNet?.close();
  }

  // ── CORE INFERENCE ────────────────────────────────────────────────────────

  /// Jalankan pipeline BlazeFace → MobileFaceNet → L2 Normalize.
  static FaceInferenceResult _runInference({
    required _InferenceRequest request,
    required Interpreter? blazeFace,
    required Interpreter? mobileFaceNet,
  }) {
    if (blazeFace == null || mobileFaceNet == null) {
      return const FaceInferenceResult(
        faceDetected: false,
        error: 'Model tidak berhasil dimuat saat inisialisasi.',
      );
    }

    try {
      // ── STEP 1: BlazeFace Detection ──────────────────────────────────────
      // Input shape : [1, 128, 128, 3] float32, range [-1.0, 1.0]
      // Output shape: {0: [1, 896, 1] scores, 1: [1, 896, 16] boxes}
      final detInput = _resizeAndNormalize(
        request.imageBytes,
        request.imageWidth,
        request.imageHeight,
        targetSize: 128,
      );

      // Alokasi output buffer BlazeFace
      // Sesuaikan shape jika model Anda berbeda — cek via netron.app
      final detScores = [List.generate(896, (_) => [0.0])];   // [1, 896, 1]
      final detBoxes = [List.generate(896, (_) => List.filled(16, 0.0))]; // [1, 896, 16]

      blazeFace.runForMultipleInputs(
        [detInput],
        {0: detScores, 1: detBoxes},
      );

      // Cari skor maksimum dari semua anchor
      double maxScore = double.negativeInfinity;
      for (final anchor in detScores[0]) {
        final score = anchor[0];
        if (score > maxScore) maxScore = score;
      }

      // Tidak ada wajah
      if (maxScore < 0.75) {
        return const FaceInferenceResult(faceDetected: false);
      }

      // ── STEP 2: MobileFaceNet Embedding ──────────────────────────────────
      // Input shape : [1, 112, 112, 3] float32, range [-1.0, 1.0]
      // Output shape: [1, 128] float32
      final faceInput = _resizeAndNormalize(
        request.imageBytes,
        request.imageWidth,
        request.imageHeight,
        targetSize: 112,
      );

      // Alokasi output buffer
      final embOutput = [List.filled(128, 0.0)]; // [1, 128]
      mobileFaceNet.run(faceInput, embOutput);

      // ── STEP 3: L2 Normalization ──────────────────────────────────────────
      // Wajib agar cosine distance di ObjectBox @HnswIndex akurat
      final raw = List<double>.from(embOutput[0]);
      final normalizedList = _l2Normalize(raw);
      // Konversi ke Float32List untuk kompatibilitas langsung dengan ObjectBox
      final normalizedF32 = Float32List.fromList(normalizedList);

      return FaceInferenceResult(
        faceDetected: true,
        embedding: normalizedF32,
      );
    } catch (e, stack) {
      debugPrint('[Isolate] ❌ Inference error: $e\n$stack');
      return FaceInferenceResult(
        faceDetected: false,
        error: 'Inference error: $e',
      );
    }
  }

  // ── PREPROCESSING ─────────────────────────────────────────────────────────

  /// Resize frame ke [targetSize]×[targetSize] dan normalisasi ke [-1, 1].
  ///
  /// Returns tensor dengan shape [1, targetSize, targetSize, 3].
  static List _resizeAndNormalize(
    Uint8List rgbBytes,
    int srcWidth,
    int srcHeight, {
    required int targetSize,
  }) {
    return List.generate(1, (_) =>
      List.generate(targetSize, (y) {
        // Bilinear-lite: nearest-neighbor untuk performa maksimal di isolate
        final srcY = (y * srcHeight / targetSize).floor().clamp(0, srcHeight - 1);
        return List.generate(targetSize, (x) {
          final srcX = (x * srcWidth / targetSize).floor().clamp(0, srcWidth - 1);
          final pixelIdx = (srcY * srcWidth + srcX) * 3;
          return List.generate(3, (c) {
            final byteIdx = pixelIdx + c;
            if (byteIdx >= rgbBytes.length) return 0.0;
            // Normalisasi: [0,255] → [-1.0, 1.0]
            return (rgbBytes[byteIdx] / 127.5) - 1.0;
          });
        });
      }),
    );
  }

  /// L2 normalization — membuat panjang vektor menjadi 1.0.
  static List<double> _l2Normalize(List<double> v) {
    double sumSq = 0.0;
    for (final x in v) sumSq += x * x;
    final norm = sqrt(sumSq);
    if (norm < 1e-10) return v; // hindari division by zero
    return v.map((x) => x / norm).toList();
  }
}
