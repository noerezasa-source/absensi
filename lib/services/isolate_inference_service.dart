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
  final String? error;

  InferenceResponse({
    required this.requestId,
    this.embedding,
    this.qualityScore,
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

      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _IsolateInitData(
          receivePort.sendPort,
          rootIsolateToken!,
          modelBytes,
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
  final Uint8List modelBytes;

  _IsolateInitData(this.sendPort, this.rootToken, this.modelBytes);
}

// Global function for Isolate entry point
Future<void> _isolateEntryPoint(_IsolateInitData initData) async {
  // Initialize services inside isolate (needed for some plugins, though maybe not for loading from buffer)
  BackgroundIsolateBinaryMessenger.ensureInitialized(initData.rootToken);

  final receivePort = ReceivePort();
  initData.sendPort.send(receivePort.sendPort);

  // Load W600K MBF optimized model from buffer
  Interpreter? interpreter;
  int inputSize = 112; 
  int embeddingSize = 512; // W600K model output size
  
  try {
    // Determine the buffer length and address if necessary, or just copy it.
    // TFLite Flutter's fromBuffer accepts Uint8List directly.
    interpreter = Interpreter.fromBuffer(
      initData.modelBytes,
      options: InterpreterOptions()..threads = 4,
    );
    
    print('ISOLATE: Model loaded successfully');
    
    // Update shapes
    final inputTensor = interpreter.getInputTensor(0);
    final outputTensor = interpreter.getOutputTensor(0);
    
    final inputShape = inputTensor.shape;
    final outputShape = outputTensor.shape;
    
    print('ISOLATE: Input Tensor: Shape=$inputShape, Type=${inputTensor.type}');
    print('ISOLATE: Output Tensor: Shape=$outputShape, Type=${outputTensor.type}');

    if (inputShape.length >= 3) inputSize = inputShape[1];
    if (outputShape.length >= 2) embeddingSize = outputShape[1];
    
    print('ISOLATE: Configured inputSize=$inputSize, embeddingSize=$embeddingSize');
    
  } catch (e) {
    print('ISOLATE: Failed to load model: $e');
  }

  receivePort.listen((message) async {
    if (message is InferenceRequest) {
      try {
        img.Image? image;

        if (message.imagePath != null) {
          final imageFile = File(message.imagePath!);
          if (!await imageFile.exists()) {
             throw Exception('Image file not found: ${message.imagePath}');
          }
          final imageBytes = await imageFile.readAsBytes();
          image = img.decodeImage(imageBytes);
        } else if (message.imageBytes != null && message.imageWidth != null && message.imageHeight != null) {
           // Provide raw YUV/NV21 handling if needed, or assume it's already converted to RGB?
           // The concatenating planes in main thread creates a rough YUV buffer.
           // However, converting YUV to RGB effectively in Dart is slow.
           // BETTER: Since we used `takePicture` before, that was JPEG.
           // Now we send raw bytes from `cameraImage`.
           // Ideally, we should do YUV -> RGB here. 
           image = _convertYUV420ToImage(message.imageBytes!, message.imageWidth!, message.imageHeight!);
           
           // Rotate if needed! (Crucial for correct coordinates)
           if (message.rotation != null && message.rotation != 0) {
             image = img.copyRotate(image!, angle: message.rotation!);
           }
        }

        if (image == null) {
          throw Exception('Failed to decode or process image');
        }

        // Process
        final enhancedImage = _enhanceImage(image);
        // Combined Crop & Align (Fixes rotation coordinate issues)
        final faceImage = _cropAndAlignFace(enhancedImage, message.faceData, inputSize);
        
        // ✅ DEBUG: Save cropped face to check alignment/rotation
        if (message.debugPath != null) {
           try {
             final debugFile = File('${message.debugPath}/debug_face_${DateTime.now().millisecondsSinceEpoch}.png');
             debugFile.writeAsBytesSync(img.encodePng(faceImage));
             print('DEBUG: Saved face crop to ${debugFile.path}');
           } catch (e) {
             print('DEBUG: Failed to save face crop: $e');
           }
        }

        final embedding = _runInference(interpreter!, faceImage, inputSize, embeddingSize);
        
        initData.sendPort.send(InferenceResponse(
          requestId: message.requestId,
          embedding: embedding,
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

// Simple YUV420 to RGB conversion (Approximation for performance)
img.Image _convertYUV420ToImage(Uint8List yuvBytes, int width, int height) {
  final image = img.Image(width: width, height: height);
  
  int frameSize = width * height;
  
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
       int yIndex = y * width + x;
       if (yIndex >= yuvBytes.length) break;
       
       int yVal = yuvBytes[yIndex] & 0xFF;
       
       // NV21 Logic (Standard Android)
       int uvIndex = frameSize + (y >> 1) * width + (x & ~1);
       int uVal = 128;
       int vVal = 128;
       
       if (uvIndex + 1 < yuvBytes.length) {
         vVal = yuvBytes[uvIndex] & 0xFF;
         uVal = yuvBytes[uvIndex + 1] & 0xFF;
       }
       
       int r = (yVal + 1.370705 * (vVal - 128)).toInt();
       int g = (yVal - 0.337633 * (uVal - 128) - 0.698001 * (vVal - 128)).toInt();
       int b = (yVal + 1.732446 * (uVal - 128)).toInt();
       
       image.setPixelRgb(x, y, 
         r.clamp(0, 255), 
         g.clamp(0, 255), 
         b.clamp(0, 255)
       );
    }
  }
  return image;
}

img.Image _enhanceImage(img.Image image) {
  // ✅ TUNED: Less aggressive enhancement to preserve natural features
  return img.adjustColor(
    image,
    brightness: 1.0,  // Neutral
    contrast: 1.0,    // Neutral
    saturation: 1.0,  // Neutral
    gamma: 1.0,       // Neutral
  );
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

  // Handle output type
  final outputTensor = interpreter.getOutputTensor(0);
  final outputType = outputTensor.type;
  
  Object output;
  if (outputType == TensorType.uint8 || outputType == TensorType.int8) {
    // Both uint8 and int8 use integer lists for output buffer
    output = List.generate(1, (_) => List<int>.filled(embeddingSize, 0));
  } else {
    output = List.generate(1, (_) => List<double>.filled(embeddingSize, 0.0));
  }

  interpreter.run(input, output);
  
  List<double> embedding;
  if (output is List<List<int>>) {
    // Apply Dequantization: real_value = (quantized_value - zero_point) * scale
    // If params are missing, assume symmetric (zp=0, scale=1 or arbitrary since we normalize)
    // But checking params is safer.
    
    // params map might be empty or specific structure in newer tflite_flutter
    // We try to access scale and zeroPoint directly if exposed, or through params
    
    double scale = 1.0;
    int zeroPoint = 0;
    
    try {
      // Accessing quantization params - API depends on version.
      // Assuming Tensor.params is available and contains scale/zeroPoint
      // If version 0.10+:
      final params = outputTensor.params; 
      scale = params.scale;
      zeroPoint = params.zeroPoint;
    } catch (e) {
      // Fallback or old version
      // If int8, usually symmetric around 0.
      print('ISOLATE: Warning - could not read quantization params: $e');
    }

    final rawIntList = output[0];
    embedding = rawIntList.map((q) => (q - zeroPoint) * scale).toList();
    
  } else {
    embedding = List<double>.from((output as List)[0]);
  }

  return _normalizeEmbedding(embedding);
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
