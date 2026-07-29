import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Request object to send to Isolate
class InferenceRequest {
  final int requestId;
  final String? imagePath; // Optional now
  final Uint8List? imageBytes; // NEW: For stream data
  final int? imageWidth;
  final int? imageHeight;
  final int? rotation; // NEW: Rotation in degrees
  final Map<String, dynamic> faceData;
  final bool allowSidePose;

  InferenceRequest({
    required this.requestId,
    this.imagePath,
    this.imageBytes,
    this.imageWidth,
    this.imageHeight,
    this.rotation, // NEW
    required this.faceData,
    this.allowSidePose = false,
    this.debugPath, // NEW: Path to save debug image
  });

  final String? debugPath;
}

/// Response object from Isolate
class InferenceResponse {
  final int requestId;
  final List<double>? embedding;
  final double? qualityScore;
  final List<List<double>>? landmarks3d; // NEW: 68 points (x, y, z)
  final String? error;

  InferenceResponse({
    required this.requestId,
    this.embedding,
    this.qualityScore,
    this.landmarks3d,
    this.error,
  });
}

class IsolateInferenceService {
  static final IsolateInferenceService _instance =
      IsolateInferenceService._internal();

  factory IsolateInferenceService() {
    return _instance;
  }

  IsolateInferenceService._internal();

  Isolate? _isolate;
  SendPort? _sendPort;

  // We don't need a StreamController here if we are just using Completers map
  bool _isInitialized = false;
  int _requestIdCounter = 0;
  final Map<int, Completer<InferenceResponse>> _activeRequests = {};
  Completer<void>? _initCompleter;

  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();

    try {
      final receivePort = ReceivePort();
      final rootIsolateToken = RootIsolateToken.instance;

      // Load optimized InsightFace/MobileFaceNet/FaceNet model bytes in main isolate
      ByteData? modelData;
      const modelCandidates = [
        'assets/models/facenet.tflite',
        'assets/models/mobilefacenet.tflite',
        'assets/models/w600k_mbf.tflite',
        'assets/models/mobile_face_net.tflite',
      ];
      for (final candidate in modelCandidates) {
        try {
          modelData = await rootBundle.load(candidate);
          debugPrint('✅ Loaded face recognition model asset: $candidate');
          break;
        } catch (_) {}
      }

      if (modelData == null) {
        throw Exception(
          'Unable to load face recognition model from assets. Checked: ${modelCandidates.join(", ")}',
        );
      }
      final modelBytes = modelData.buffer.asUint8List();

      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateInitData(
          receivePort.sendPort,
          rootIsolateToken!,
          modelBytes,
          Uint8List(0), // No landmark model
        ),
      );

      // Listen to the port - this handles BOTH the initial SendPort and subsequent responses
      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _isInitialized = true;
          _initCompleter?.complete();
        } else if (message is InferenceResponse) {
          final completer = _activeRequests.remove(message.requestId);
          if (completer != null) {
            completer.complete(message);
          }
        }
      });

      await _initCompleter!.future;
    } catch (e) {
      _initCompleter?.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  Future<InferenceResponse> processFace({
    required String imagePath,
    required Map<String, dynamic> faceData,
    bool allowSidePose = false,
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final requestId = _requestIdCounter++;
    final completer = Completer<InferenceResponse>();
    _activeRequests[requestId] = completer;

    _sendPort!.send(
      InferenceRequest(
        requestId: requestId,
        imagePath: imagePath,
        faceData: faceData,
        allowSidePose: allowSidePose,
      ),
    );

    return completer.future;
  }

  // ✅ NEW: method for stream bytes
  Future<InferenceResponse> processFaceFromBytes({
    required Uint8List imageBytes,
    required int width,
    required int height,
    required int rotation, // NEW
    required Map<String, dynamic> faceData,
    bool allowSidePose = false,
    String? debugPath, // NEW
  }) async {
    if (!_isInitialized) {
      await initialize();
    }

    final requestId = _requestIdCounter++;
    final completer = Completer<InferenceResponse>();
    _activeRequests[requestId] = completer;

    _sendPort!.send(
      InferenceRequest(
        requestId: requestId,
        imageBytes: imageBytes,
        imageWidth: width,
        imageHeight: height,
        rotation: rotation, // NEW
        faceData: faceData,
        allowSidePose: allowSidePose,
        debugPath: debugPath,
      ),
    );

    return completer.future;
  }

  void dispose() {
    _isolate?.kill();
    _isInitialized = false;
    _initCompleter = null;
  }
}

class _IsolateInitData {
  final SendPort sendPort;
  final RootIsolateToken rootToken;
  final Uint8List recognitionModelBytes;
  final Uint8List landmarkModelBytes;

  _IsolateInitData(
    this.sendPort,
    this.rootToken,
    this.recognitionModelBytes,
    this.landmarkModelBytes,
  );
}

// Global function for Isolate entry point
Future<void> _isolateEntryPoint(_IsolateInitData initData) async {
  // Initialize services inside isolate (needed for some plugins, though maybe not for loading from buffer)
  BackgroundIsolateBinaryMessenger.ensureInitialized(initData.rootToken);

  final receivePort = ReceivePort();
  initData.sendPort.send(receivePort.sendPort);

  // Load Recognition Model
  Interpreter? recognitionInterpreter;
  int recognitionInputSize = 160;
  int embeddingSize = 512;

  int landmarkInputSize = 0;

  try {
    // 1. Define Options with Threads
    InterpreterOptions recognitionOptions = InterpreterOptions()..threads = 4;
    InterpreterOptions landmarkOptions = InterpreterOptions()..threads = 2;

    if (Platform.isAndroid) {
      // ❌ NNAPI DIMATIKAN
      debugPrint('ISOLATE: Using XNNPack CPU Acceleration (Extremely fast & stable)');
    } else if (Platform.isIOS) {
      // ✅ IOS: Use Metal/CoreML if available (GpuDelegate for iOS)
      try {
        final gpuDelegate = GpuDelegate();
        recognitionOptions.addDelegate(gpuDelegate);
        landmarkOptions.addDelegate(gpuDelegate);
        debugPrint('ISOLATE: Using iOS GPU Acceleration');
      } catch (e) {
        debugPrint('ISOLATE: iOS GPU initialization failed: $e');
      }
    }

    try {
      recognitionInterpreter = Interpreter.fromBuffer(
        initData.recognitionModelBytes,
        options: recognitionOptions,
      );
    } catch (e) {
      debugPrint(
        'ISOLATE: Accelerated initialization failed, falling back to CPU: $e',
      );
      // ✅ ATTEMPT 2: Standard CPU (Final Fallback)
      recognitionOptions = InterpreterOptions()..threads = 4;
      landmarkOptions = InterpreterOptions()..threads = 2;

      recognitionInterpreter = Interpreter.fromBuffer(
        initData.recognitionModelBytes,
        options: recognitionOptions,
      );
    }

    // Configure Recognition Model
    final recInTensor = recognitionInterpreter.getInputTensor(0);
    final recOutTensor = recognitionInterpreter.getOutputTensor(0);
    if (recInTensor.shape.length >= 3) {
      recognitionInputSize = recInTensor.shape[1];
    }
    if (recOutTensor.shape.length >= 2) {
      embeddingSize = recOutTensor.shape[1];
    }
  } catch (e) {
    debugPrint('ISOLATE CRITICAL ERROR: Failed to load models: $e');
  }

  receivePort.listen((message) async {
    if (message is InferenceRequest) {
      try {
        img.Image? faceImage;
        if (message.imagePath != null) {
          final imageFile = File(message.imagePath!);
          if (!await imageFile.exists()) {
            throw Exception('Image file not found: ${message.imagePath}');
          }
          final imageBytes = await imageFile.readAsBytes();
          final rawDecoded = img.decodeImage(imageBytes);
          if (rawDecoded == null) {
            throw Exception('Failed to decode image');
          }
          final fullImage = img.bakeOrientation(rawDecoded);

          // ✅ CRITICAL FIX: Crop face region from full upright image
          final box = message.faceData['boundingBox'] as Map<String, dynamic>;
          final fLeft = (box['left'] as num).toDouble();
          final fTop = (box['top'] as num).toDouble();
          final fWidth = (box['width'] as num).toDouble();
          final fHeight = (box['height'] as num).toDouble();

          // Add margin around face (same 25% as stream path)
          const margin = 0.25;
          final marginW = fWidth * margin;
          final marginH = fHeight * margin;

          int cropX = max(0, (fLeft - marginW).toInt());
          int cropY = max(0, (fTop - marginH).toInt());
          int cropW = min(fullImage.width - cropX, (fWidth + marginW * 2).toInt());
          int cropH = min(fullImage.height - cropY, (fHeight + marginH * 2).toInt());

          if (cropW <= 0 || cropH <= 0) {
            // Fallback: use full image if crop fails
            faceImage = img.copyResize(fullImage, width: recognitionInputSize, height: recognitionInputSize);
          } else {
            final cropped = img.copyCrop(fullImage, x: cropX, y: cropY, width: cropW, height: cropH);
            faceImage = img.copyResize(cropped, width: recognitionInputSize, height: recognitionInputSize);
          }
        } else if (message.imageBytes != null &&
            message.imageWidth != null &&
            message.imageHeight != null) {
          // ✅ TURBO: Single-Pass Conversion for stream
          faceImage = _convertYUVRegionToImage(
            message.imageBytes!,
            message.imageWidth!,
            message.imageHeight!,
            message.faceData,
            recognitionInputSize,
            message.rotation ?? 0,
          );
        }

        if (faceImage == null) {
          throw Exception('Gagal memproses gambar wajah (null)');
        }

        if (recognitionInterpreter == null) {
          throw Exception(
            'Model AI belum siap. Harap tunggu sebentar atau muat ulang halaman.',
          );
        }

        // 1. Run Recognition Model (W600K)
        final img.Image recImage = (faceImage.width == recognitionInputSize)
            ? faceImage
            : img.copyResize(
                faceImage,
                width: recognitionInputSize,
                height: recognitionInputSize,
              );

        final embedding = _runInference(
          recognitionInterpreter,
          recImage,
          recognitionInputSize,
          embeddingSize,
        );

        final landmarks3d = null;

        initData.sendPort.send(
          InferenceResponse(
            requestId: message.requestId,
            embedding: embedding,
            landmarks3d: landmarks3d,
            qualityScore: 1.0,
          ),
        );
      } catch (e) {
        initData.sendPort.send(
          InferenceResponse(requestId: message.requestId, error: e.toString()),
        );
      }
    }
  });
}

// --- Helper Functions in Isolate ---

// ✅ OPTIMIZED: Region-Based YUV420 / BGRA to RGB conversion (Rotation Aware)
img.Image _convertYUVRegionToImage(
  Uint8List frameBytes,
  int frameWidth,
  int frameHeight,
  Map<String, dynamic> faceData,
  int targetSize,
  int rotation,
) {
  final box = faceData['boundingBox'] as Map<String, dynamic>;
  double sLeft = (box['left'] as num).toDouble();
  double sTop = (box['top'] as num).toDouble();
  double sWidth = (box['width'] as num).toDouble();
  double sHeight = (box['height'] as num).toDouble();

  // 1. UN-ROTATE coordinates from "Screen/MLKit" space to "Raw Buffer" space
  double bLeft, bTop, bWidth, bHeight;

  if (rotation == 90) {
    bLeft = sTop;
    bTop = frameHeight - sLeft - sWidth;
    bWidth = sHeight;
    bHeight = sWidth;
  } else if (rotation == 270) {
    bLeft = frameWidth - sTop - sHeight;
    bTop = sLeft;
    bWidth = sHeight;
    bHeight = sWidth;
  } else if (rotation == 180) {
    bLeft = frameWidth - sLeft - sWidth;
    bTop = frameHeight - sTop - sHeight;
    bWidth = sWidth;
    bHeight = sHeight;
  } else {
    bLeft = sLeft;
    bTop = sTop;
    bWidth = sWidth;
    bHeight = sHeight;
  }

  // 2. Calculate Crop Area with margin
  const margin = 0.25;
  final marginW = bWidth * margin;
  final marginH = bHeight * margin;

  int startX = max(0, (bLeft - marginW).toInt());
  int startY = max(0, (bTop - marginH).toInt());
  int endX = min(frameWidth - 1, (bLeft + bWidth + marginW).toInt());
  int endY = min(frameHeight - 1, (bTop + bHeight + marginH).toInt());

  int cropW = endX - startX;
  int cropH = endY - startY;

  if (cropW <= 0 || cropH <= 0) {
    startX = 0;
    startY = 0;
    cropW = min(frameWidth, 200);
    cropH = min(frameHeight, 200);
  }

  final image = img.Image(width: targetSize, height: targetSize);
  final int frameSize = frameWidth * frameHeight;
  final bool isBgra = frameBytes.length >= frameSize * 4;

  final double scaleX = cropW / targetSize;
  final double scaleY = cropH / targetSize;

  const int c1 = 1403; // 1.370705 * 1024
  const int c2 = 346; // 0.337633 * 1024
  const int c3 = 715; // 0.698001 * 1024
  const int c4 = 1774; // 1.732446 * 1024

  for (int y = 0; y < targetSize; y++) {
    final int sourceY = startY + (y * scaleY).toInt();
    if (sourceY < 0 || sourceY >= frameHeight) continue;

    final int yOffset = sourceY * frameWidth;
    final int uvY = sourceY >> 1;
    final int uvRowStart = frameSize + (uvY * frameWidth);

    for (int x = 0; x < targetSize; x++) {
      final int sourceX = startX + (x * scaleX).toInt();
      if (sourceX < 0 || sourceX >= frameWidth) continue;

      int r = 0, g = 0, b = 0;

      if (isBgra) {
        final int pxIndex = (yOffset + sourceX) * 4;
        if (pxIndex + 2 < frameBytes.length) {
          b = frameBytes[pxIndex];
          g = frameBytes[pxIndex + 1];
          r = frameBytes[pxIndex + 2];
        }
      } else {
        final int yIndex = yOffset + sourceX;
        if (yIndex >= frameSize) continue;

        final int yVal = frameBytes[yIndex];
        final int uvX = sourceX & ~1;
        final int uvIndex = uvRowStart + uvX;

        int uVal = 128;
        int vVal = 128;
        if (uvIndex + 1 < frameBytes.length) {
          vVal = frameBytes[uvIndex];
          uVal = frameBytes[uvIndex + 1];
        }

        final int r8 = vVal - 128;
        final int u8 = uVal - 128;

        r = yVal + ((c1 * r8) >> 10);
        g = yVal - ((c2 * u8 + c3 * r8) >> 10);
        b = yVal + ((c4 * u8) >> 10);

        r = r < 0 ? 0 : (r > 255 ? 255 : r);
        g = g < 0 ? 0 : (g > 255 ? 255 : g);
        b = b < 0 ? 0 : (b > 255 ? 255 : b);
      }

      int dx, dy;
      if (rotation == 90) {
        dx = targetSize - 1 - y;
        dy = x;
      } else if (rotation == 270) {
        dx = y;
        dy = targetSize - 1 - x;
      } else if (rotation == 180) {
        dx = targetSize - 1 - x;
        dy = targetSize - 1 - y;
      } else {
        dx = x;
        dy = y;
      }

      image.setPixelRgb(dx, dy, r, g, b);
    }
  }

  return image;
}

List<double> _dequantize(Tensor tensor, dynamic output) {
  if (tensor.type == TensorType.float32) {
    if (output is List<List<double>>) return List<double>.from(output[0]);
    if (output is List<double>) return List<double>.from(output);
    final list = (output is List) ? output[0] as List : output as List;
    return list.map((e) => (e as num).toDouble()).toList();
  }

  double scale = 1.0;
  int zeroPoint = 0;

  try {
    final params = tensor.params;
    scale = params.scale;
    zeroPoint = params.zeroPoint;
  } catch (_) {}

  final List<dynamic> rawList =
      (output is List && output.isNotEmpty && output[0] is List)
      ? output[0]
      : (output as List);

  return rawList.map((q) => ((q as num).toInt() - zeroPoint) * scale).toList();
}

List<double> _runInference(
  Interpreter interpreter,
  img.Image faceImage,
  int inputSize,
  int embeddingSize,
) {
  final inputTensor = interpreter.getInputTensor(0);
  final inputType = inputTensor.type;

  Object input;

  if (inputType == TensorType.uint8) {
    input = _preprocessImageUint8(faceImage, inputSize);
  } else if (inputType == TensorType.int8) {
    input = _preprocessImageInt8(faceImage, inputSize);
  } else {
    input = _preprocessImageFloat(faceImage, inputSize);
  }

  final outputTensor = interpreter.getOutputTensor(0);
  final dynamic output;

  if (outputTensor.type == TensorType.uint8 ||
      outputTensor.type == TensorType.int8) {
    output = List.generate(1, (_) => List<int>.filled(embeddingSize, 0));
  } else {
    output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));
  }

  interpreter.run(input, output);

  final embedding = _dequantize(outputTensor, output);
  return _normalizeEmbedding(embedding);
}

List<List<List<List<double>>>> _preprocessImageFloat(img.Image image, int inputSize) {
  final input = <List<List<List<double>>>>[];
  final batch = <List<List<double>>>[];

  for (int y = 0; y < inputSize; y++) {
    final row = <List<double>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      row.add([
        (pixel.r.toDouble() - 127.5) / 127.5,
        (pixel.g.toDouble() - 127.5) / 127.5,
        (pixel.b.toDouble() - 127.5) / 127.5,
      ]);
    }
    batch.add(row);
  }
  input.add(batch);
  return input;
}

List<List<List<List<int>>>> _preprocessImageUint8(
  img.Image image,
  int inputSize,
) {
  final input = <List<List<List<int>>>>[];
  final batch = <List<List<int>>>[];

  for (int y = 0; y < inputSize; y++) {
    final row = <List<int>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      row.add([pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()]);
    }
    batch.add(row);
  }
  input.add(batch);
  return input;
}

List<List<List<List<int>>>> _preprocessImageInt8(
  img.Image image,
  int inputSize,
) {
  final input = <List<List<List<int>>>>[];
  final batch = <List<List<int>>>[];

  for (int y = 0; y < inputSize; y++) {
    final row = <List<int>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      row.add([
        pixel.r.toInt() - 128,
        pixel.g.toInt() - 128,
        pixel.b.toInt() - 128,
      ]);
    }
    batch.add(row);
  }
  input.add(batch);
  return input;
}

List<double> _normalizeEmbedding(List<double> embedding) {
  double sumSquares = 0.0;
  for (var value in embedding) {
    sumSquares += value * value;
  }
  final magnitude = sqrt(sumSquares);
  if (magnitude < 1e-6) return embedding;
  return embedding.map((value) => value / magnitude).toList();
}
