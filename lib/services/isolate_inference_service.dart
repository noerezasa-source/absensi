import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
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
  static final IsolateInferenceService _instance = IsolateInferenceService._internal();

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
      
      // Load optimized W600K MBF model bytes in main isolate
      final modelData = await rootBundle.load('assets/models/w600k_mbf_optimized.tflite');
      final modelBytes = modelData.buffer.asUint8List();

      // Load 1K3D68 High-Precision Landmark model (Buffalo_S)
      final landmarkData = await rootBundle.load('assets/models/1k3d68_optimized.tflite');
      final landmarkBytes = landmarkData.buffer.asUint8List();

      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateInitData(
          receivePort.sendPort,
          rootIsolateToken!,
          modelBytes,
          landmarkBytes,
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

    _sendPort!.send(InferenceRequest(
      requestId: requestId,
      imagePath: imagePath,
      faceData: faceData,
      allowSidePose: allowSidePose,
    ));

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

    _sendPort!.send(InferenceRequest(
      requestId: requestId,
      imageBytes: imageBytes,
      imageWidth: width,
      imageHeight: height,
      rotation: rotation, // NEW
      faceData: faceData,
      allowSidePose: allowSidePose,
      debugPath: debugPath,
    ));

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

  _IsolateInitData(this.sendPort, this.rootToken, this.recognitionModelBytes, this.landmarkModelBytes);
}

// Global function for Isolate entry point
Future<void> _isolateEntryPoint(_IsolateInitData initData) async {
  // Initialize services inside isolate (needed for some plugins, though maybe not for loading from buffer)
  BackgroundIsolateBinaryMessenger.ensureInitialized(initData.rootToken);

  final receivePort = ReceivePort();
  initData.sendPort.send(receivePort.sendPort);

  // Load Recognition Model
  Interpreter? recognitionInterpreter;
  int recognitionInputSize = 112; 
  int embeddingSize = 512;

  // Load Landmark Model (Buffalo_S 1K3D68)
  Interpreter? landmarkInterpreter;
  int landmarkInputSize = 192; // Buffalo_S landmark standard

  try {
    recognitionInterpreter = Interpreter.fromBuffer(
      initData.recognitionModelBytes,
      options: InterpreterOptions()..threads = 4,
    );
    print('ISOLATE: Recognition Model loaded successfully');
    
    landmarkInterpreter = Interpreter.fromBuffer(
      initData.landmarkModelBytes,
      options: InterpreterOptions()..threads = 2,
    );
    print('ISOLATE: Landmark Model loaded successfully');

    // Configure Recognition Model
    final recInTensor = recognitionInterpreter.getInputTensor(0);
    final recOutTensor = recognitionInterpreter.getOutputTensor(0);
    if (recInTensor.shape.length >= 3) recognitionInputSize = recInTensor.shape[1];
    if (recOutTensor.shape.length >= 2) embeddingSize = recOutTensor.shape[1];
    
    // Configure Landmark Model
    final lanInTensor = landmarkInterpreter.getInputTensor(0);
    if (lanInTensor.shape.length >= 3) landmarkInputSize = lanInTensor.shape[1];

    print('ISOLATE: Models Configured. RecInput=$recognitionInputSize, LanInput=$landmarkInputSize, Emb=$embeddingSize');
    
  } catch (e) {
    print('ISOLATE: Failed to load models: $e');
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
          faceImage = img.decodeImage(imageBytes);
        } else if (message.imageBytes != null && message.imageWidth != null && message.imageHeight != null) {
          // ✅ TURBO: Single-Pass Conversion
          // Instead of converting twice (once for 112 and once for 192), 
          // we convert once to the highest needed resolution (LandmarkSize).
          final int maxNeededSize = max(recognitionInputSize, landmarkInputSize);
          
          faceImage = _convertYUVRegionToImage(
             message.imageBytes!, 
             message.imageWidth!, 
             message.imageHeight!, 
             message.faceData,
             maxNeededSize,
             message.rotation ?? 0
          );
        }

        if (faceImage == null) {
          throw Exception('Failed to decode or process image');
        }
        
        // 1. Run Recognition Model (W600K)
        // Resize if base image is larger than needed
        final img.Image recImage = (faceImage.width == recognitionInputSize) 
            ? faceImage 
            : img.copyResize(faceImage, width: recognitionInputSize, height: recognitionInputSize);
            
        final embedding = _runInference(recognitionInterpreter!, recImage, recognitionInputSize, embeddingSize);
        
        // 2. Run Landmark Model (1K3D68)
        final img.Image lanImage = (faceImage.width == landmarkInputSize)
            ? faceImage
            : img.copyResize(faceImage, width: landmarkInputSize, height: landmarkInputSize);

        final landmarks3d = _runLandmarkInference(landmarkInterpreter!, lanImage, landmarkInputSize);

        initData.sendPort.send(InferenceResponse(
          requestId: message.requestId,
          embedding: embedding,
          landmarks3d: landmarks3d,
          qualityScore: 1.0, 
        ));

      } catch (e) {
        initData.sendPort.send(InferenceResponse(
          requestId: message.requestId,
          error: e.toString(),
        ));
      }
    }
  });
}

// --- Helper Functions in Isolate ---

// ✅ OPTIMIZED: Region-Based YUV420 to RGB conversion (Rotation Aware)
img.Image _convertYUVRegionToImage(Uint8List yuvBytes, int frameWidth, int frameHeight, Map<String, dynamic> faceData, int targetSize, int rotation) {
  final box = faceData['boundingBox'] as Map<String, dynamic>;
  double sLeft = (box['left'] as num).toDouble();
  double sTop = (box['top'] as num).toDouble();
  double sWidth = (box['width'] as num).toDouble();
  double sHeight = (box['height'] as num).toDouble();

  // 1. UN-ROTATE coordinates from "Screen/MLKit" space to "Raw Buffer" space
  // ML Kit gives coordinates relative to the rotated InputImage.
  // We need to map them back to the raw yuvBytes buffer (usually landscape).
  double bLeft, bTop, bWidth, bHeight;
  
  if (rotation == 90) {
    // Portrait: Screen(720x1280) -> Buffer(1280x720)
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
    // 0 or default
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
     // Fallback to minimal sensible area if mapping fails
     startX = 0; startY = 0; cropW = min(frameWidth, 200); cropH = min(frameHeight, 200);
  }

  // 3. One-Pass Turbo Loop: Crop + Scale + Convert YUV
  final image = img.Image(width: targetSize, height: targetSize);
  final int frameSize = frameWidth * frameHeight;
  
  final double scaleX = cropW / targetSize;
  final double scaleY = cropH / targetSize;

  for (int y = 0; y < targetSize; y++) {
    final int sourceY = startY + (y * scaleY).toInt();
    final int yOffset = sourceY * frameWidth;
    final int uvY = sourceY >> 1;
    final int uvRowStart = frameSize + (uvY * frameWidth);

    for (int x = 0; x < targetSize; x++) {
      final int sourceX = startX + (x * scaleX).toInt();
      final int yIndex = yOffset + sourceX;
      
      if (yIndex >= frameSize) continue;
      final int yVal = yuvBytes[yIndex] & 0xFF;
      
      final int uvX = sourceX & ~1;
      final int uvIndex = uvRowStart + uvX;
      
      int uVal = 128;
      int vVal = 128;
      if (uvIndex + 1 < yuvBytes.length) {
        vVal = yuvBytes[uvIndex] & 0xFF;
        uVal = yuvBytes[uvIndex + 1] & 0xFF;
      }
      
      // Integer-only YUV conversion for speed
      int r = (yVal + (1.370705 * (vVal - 128)).toInt());
      int g = (yVal - (0.337633 * (uVal - 128)).toInt() - (0.698001 * (vVal - 128)).toInt());
      int b = (yVal + (1.732446 * (uVal - 128)).toInt());
      
      // Fast Clamp
      r = r < 0 ? 0 : (r > 255 ? 255 : r);
      g = g < 0 ? 0 : (g > 255 ? 255 : g);
      b = b < 0 ? 0 : (b > 255 ? 255 : b);
      
      image.setPixelRgb(x, y, r, g, b);
    }
  }

  // 4. Final Processing (Rotation)
  var faceImage = image;
  if (rotation != 0) {
    faceImage = img.copyRotate(faceImage, angle: rotation);
  }

  // lighting normalization removed here to preserve speed on low-end.
  // We rely on TFLite model's own normalization if possible.
  return faceImage;
}

// ✅ NEW: Robust Lighting Normalization (CLAHE-lite)
img.Image _normalizeLighting(img.Image image) {
  // 1. Calculate average luminance
  double totalLuminance = 0;
  final numPixels = image.width * image.height;
  
  for (final pixel in image) {
    // Standard luminance formula: 0.299R + 0.587G + 0.114B
    totalLuminance += (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b);
  }
  
  final avgLuminance = totalLuminance / numPixels;
  final targetLuminance = 128.0; // Aim for middle gray
  
  // 2. Adjust brightness (Gamma-like shift)
  // If image is too dark, boost it. If too bright, dim it.
  double adjustmentFactor = targetLuminance / (avgLuminance + 1.0);
  
  // Clamp adjustment to prevent extreme artifacts
  adjustmentFactor = adjustmentFactor.clamp(0.5, 2.0);

  if ((adjustmentFactor - 1.0).abs() < 0.05) return image; // No significant adjustment needed

  return img.adjustColor(
    image,
    brightness: adjustmentFactor,
    contrast: 1.1, // Slight contrast boost for features
  );
}

img.Image _enhanceImage(img.Image image) {
  // ✅ Deprecated: Replaced by _normalizeLighting
  return image;
}

img.Image _cropAndAlignFace(img.Image image, Map<String, dynamic> faceData, int inputSize) {
  // 1. Crop face with margin first
  final box = faceData['boundingBox'] as Map<String, dynamic>;
  final left = (box['left'] as num).toDouble();
  final top = (box['top'] as num).toDouble();
  final width = (box['width'] as num).toDouble();
  final height = (box['height'] as num).toDouble();

  // Wide margin to allow for rotation without black corners
  const margin = 0.35; 
  final marginW = width * margin;
  final marginH = height * margin;

  final x = max(0, (left - marginW).toInt());
  final y = max(0, (top - marginH).toInt());
  final w = min(image.width - x, (width + 2 * marginW).toInt());
  final h = min(image.height - y, (height + 2 * marginH).toInt());

  var croppedFace = img.copyCrop(image, x: x, y: y, width: w, height: h);

  // 2. Calculate rotation from landmarks (now in cropped space)
  final landmarks = faceData['landmarks'] as Map<String, dynamic>?;
  if (landmarks != null) {
    final leftEye = landmarks['leftEye'] as Map<String, dynamic>?;
    final rightEye = landmarks['rightEye'] as Map<String, dynamic>?;
    
    if (leftEye != null && rightEye != null) {
      // Adjust landmark coordinates to cropped space
      final leftX = (leftEye['x'] as num).toDouble() - x;
      final leftY = (leftEye['y'] as num).toDouble() - y;
      final rightX = (rightEye['x'] as num).toDouble() - x;
      final rightY = (rightEye['y'] as num).toDouble() - y;

      final dx = rightX - leftX;
      final dy = rightY - leftY;
      final angle = atan2(dy, dx) * (180.0 / pi);

      // Only rotate if angle is significant
      if (angle.abs() >= 5.0) {
        // Rotate around center
        croppedFace = img.copyRotate(croppedFace, angle: -angle);
      }
    }
  }

  // 3. Resize to model input
  return img.copyResize(
    croppedFace,
    width: inputSize,
    height: inputSize,
    interpolation: img.Interpolation.cubic,
  );
}

/// Helper to dequantize TFLite output tensors correctly
List<double> _dequantize(Tensor tensor, dynamic output) {
  // If the model is already float32, just cast and return
  if (tensor.type == TensorType.float32) {
    if (output is List<List<double>>) return List<double>.from(output[0]);
    if (output is List<double>) return List<double>.from(output);
    // Dynamic cast if needed
    final list = (output is List) ? output[0] as List : output as List;
    return list.map((e) => (e as num).toDouble()).toList();
  }

  // Dequantization: real_value = (quantized_value - zero_point) * scale
  double scale = 1.0;
  int zeroPoint = 0;

  try {
    final params = tensor.params;
    scale = params.scale;
    zeroPoint = params.zeroPoint;
  } catch (e) {
    print('ISOLATE: Warning - could not read quantization params: $e');
  }

  final List<dynamic> rawList = (output is List && output.isNotEmpty && output[0] is List) 
      ? output[0] 
      : (output as List);
      
  return rawList.map((q) => ((q as num).toInt() - zeroPoint) * scale).toList();
}

List<double> _runInference(Interpreter interpreter, img.Image faceImage, int inputSize, int embeddingSize) {
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

  // Allocate output buffer based on model type
  if (outputTensor.type == TensorType.uint8 || outputTensor.type == TensorType.int8) {
    output = List.generate(1, (_) => List<int>.filled(embeddingSize, 0));
  } else {
    output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));
  }

  interpreter.run(input, output);
  
  final embedding = _dequantize(outputTensor, output);
  return _normalizeEmbedding(embedding);
}

/// ✅ NEW: High-Precision 3D Landmark Inference (Buffalo_S 1K3D68)
List<List<double>> _runLandmarkInference(Interpreter interpreter, img.Image image, int inputSize) {
  // Landmarks model usually expects 0..255 or -1..1. Buffalo_S 1k3d68 usually expects 0..255.
  final input = _preprocessImageUint8(image, inputSize);
  
  final outTensor = interpreter.getOutputTensor(0);
  final outShape = outTensor.shape;
  final dynamic output;
  
  if (outShape.length == 3) {
    // [1, N, M] - e.g. [1, 68, 3]
    if (outTensor.type == TensorType.uint8 || outTensor.type == TensorType.int8) {
       output = List.generate(outShape[0], (_) => List.generate(outShape[1], (_) => List<int>.filled(outShape[2], 0)));
    } else {
       output = List.generate(outShape[0], (_) => List.generate(outShape[1], (_) => List<double>.filled(outShape[2], 0.0)));
    }
    
    interpreter.run(input, output);
    
    // Process and dequantize
    final result = <List<double>>[];
    final List<dynamic> batch = output[0];
    for (var point in batch) {
       final List<dynamic> p = point as List;
       // We can't use _dequantize here easily for individual points because it expects the whole tensor
       // but we can manually apply the params if it's quantized.
       if (outTensor.type != TensorType.float32) {
          final s = outTensor.params.scale;
          final z = outTensor.params.zeroPoint;
          result.add(p.map((v) => ((v as num).toInt() - z) * s).toList());
       } else {
          result.add(p.map((v) => (v as num).toDouble()).toList());
       }
    }
    return result;
  } else {
    // Flat output like [1, 3309] or [1, 204]
    final flatSize = outShape.reduce((a, b) => a * b);
    if (outTensor.type == TensorType.uint8 || outTensor.type == TensorType.int8) {
       output = List.generate(1, (_) => List<int>.filled(flatSize, 0));
    } else {
       output = List.generate(1, (_) => List<double>.filled(flatSize, 0.0));
    }
    
    interpreter.run(input, output);
    
    final flatList = _dequantize(outTensor, output);
    
    // Reshape to points with x,y,z (Assume triplets)
    final points = <List<double>>[];
    final numPoints = flatList.length ~/ 3;
    
    for (int i = 0; i < numPoints; i++) {
      points.add([flatList[i * 3], flatList[i * 3 + 1], flatList[i * 3 + 2]]);
    }
    return points;
  }
}

// Standard Float32 Preprocessing (-1 to 1)
List<List<List<List<double>>>> _preprocessImageFloat(img.Image image, int inputSize) {
  final input = <List<List<List<double>>>>[];
  final batch = <List<List<double>>>[];
  
  for (int y = 0; y < inputSize; y++) {
    final row = <List<double>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      row.add([
        (pixel.r / 127.5) - 1.0,
        (pixel.g / 127.5) - 1.0,
        (pixel.b / 127.5) - 1.0,
      ]);
    }
    batch.add(row);
  }
  input.add(batch);
  return input;
}

// Uint8 Preprocessing (0 to 255)
List<List<List<List<int>>>> _preprocessImageUint8(img.Image image, int inputSize) {
  final input = <List<List<List<int>>>>[];
  final batch = <List<List<int>>>[];
  
  for (int y = 0; y < inputSize; y++) {
    final row = <List<int>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      row.add([
        pixel.r.toInt(),
        pixel.g.toInt(),
        pixel.b.toInt(),
      ]);
    }
    batch.add(row);
  }
  input.add(batch);
  return input;
}

// Int8 Preprocessing (-128 to 127)
List<List<List<List<int>>>> _preprocessImageInt8(img.Image image, int inputSize) {
  final input = <List<List<List<int>>>>[];
  final batch = <List<List<int>>>[];
  
  for (int y = 0; y < inputSize; y++) {
    final row = <List<int>>[];
    for (int x = 0; x < inputSize; x++) {
      final pixel = image.getPixel(x, y);
      // Shift 0..255 to -128..127
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
