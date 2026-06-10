import 'dart:ui' show Rect;
import 'package:flutter/material.dart';

/// ✅ SYNC: Optimized Custom Painter for all faces (matching wajah project)
class FaceDetectorPainter extends CustomPainter {
  final Size absoluteImageSize;
  final List<Map<String, dynamic>> faces;
  final bool isFrontCamera;

  FaceDetectorPainter({
    required this.absoluteImageSize,
    required this.faces,
    required this.isFrontCamera,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (absoluteImageSize.width == 0 || absoluteImageSize.height == 0) return;

    final double scaleX = size.width / absoluteImageSize.width;
    final double scaleY = size.height / absoluteImageSize.height;

    final Paint bracketPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    final Paint boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final face in faces) {
      final rect = face['rect'] as Rect;
      final color = face['color'] as Color;
      final nameLabel = face['name'] as String?;

      // Apply scaling and mirroring
      double left, right;
      if (isFrontCamera) {
        left = (absoluteImageSize.width - rect.right) * scaleX;
        right = (absoluteImageSize.width - rect.left) * scaleX;
      } else {
        left = rect.left * scaleX;
        right = rect.right * scaleX;
      }
      final top = rect.top * scaleY;
      final bottom = rect.bottom * scaleY;

      final mappedRect = Rect.fromLTRB(left, top, right, bottom);

      // 1. Draw main rounded box with low opacity
      boxPaint.color = color.withValues(alpha: 0.4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(mappedRect, const Radius.circular(12)),
        boxPaint,
      );

      // 2. Draw Brackets
      bracketPaint.color = color;
      const bSize = 20.0;

      // Top-Left
      canvas.drawLine(
        Offset(left, top + bSize),
        Offset(left, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, top),
        Offset(left + bSize, top),
        bracketPaint,
      );

      // Top-Right
      canvas.drawLine(
        Offset(right - bSize, top),
        Offset(right, top),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, top),
        Offset(right, top + bSize),
        bracketPaint,
      );

      // Bottom-Left
      canvas.drawLine(
        Offset(left, bottom - bSize),
        Offset(left, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(left, bottom),
        Offset(left + bSize, bottom),
        bracketPaint,
      );

      // Bottom-Right
      canvas.drawLine(
        Offset(right - bSize, bottom),
        Offset(right, bottom),
        bracketPaint,
      );
      canvas.drawLine(
        Offset(right, bottom),
        Offset(right, bottom - bSize),
        bracketPaint,
      );

      // 3. Draw Name/Status Label (if present)
      if (nameLabel != null && nameLabel.isNotEmpty) {
        final textSpan = TextSpan(
          text: nameLabel,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [Shadow(blurRadius: 2, color: Colors.black)],
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();

        final labelBgPaint = Paint()..color = color.withValues(alpha: 0.8);
        final labelRect = Rect.fromLTWH(
          left,
          top - textPainter.height - 8,
          textPainter.width + 12,
          textPainter.height + 4,
        );

        canvas.drawRRect(
          RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
          labelBgPaint,
        );
        textPainter.paint(
          canvas,
          Offset(left + 6, top - textPainter.height - 6),
        );
      }
    }
  }

  @override
  bool shouldRepaint(FaceDetectorPainter oldDelegate) => true;
}
