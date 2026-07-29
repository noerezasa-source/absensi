import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

/// Helper class for picking and cropping images, specifically optimized for profile photos.
class ImageCropHelper {
  /// Prompts user to select image source (Camera or Gallery), then opens a cropper
  /// with a circular mask and 1:1 aspect ratio. Returns the cropped [File] or `null`.
  static Future<File?> pickAndCropProfileImage({
    required BuildContext context,
    String title = 'Potong Foto Profil',
    Color primaryColor = const Color(0xFF4A1E79),
  }) async {
    final ImageSource? source = await showSourcePickerDialog(context);
    if (source == null) return null;

    final ImagePicker picker = ImagePicker();
    final XFile? pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 90,
    );

    if (pickedFile == null) return null;
    if (!context.mounted) return null;

    return await cropImage(
      filePath: pickedFile.path,
      context: context,
      title: title,
      primaryColor: primaryColor,
    );
  }

  /// Crop an existing image file to square (1:1) aspect ratio with circular guide.
  static Future<File?> cropImage({
    required String filePath,
    BuildContext? context,
    String title = 'Potong Foto Profil',
    Color primaryColor = const Color(0xFF4A1E79),
  }) async {
    try {
      final List<PlatformUiSettings> uiSettings = [
        AndroidUiSettings(
          toolbarTitle: title,
          toolbarColor: primaryColor,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          aspectRatioPresets: [
            CropAspectRatioPreset.square,
          ],
          cropStyle: CropStyle.circle,
        ),
        IOSUiSettings(
          title: title,
          aspectRatioPresets: [
            CropAspectRatioPreset.square,
          ],
          aspectRatioLockEnabled: true,
          cropStyle: CropStyle.circle,
        ),
      ];

      if (context != null) {
        uiSettings.add(
          WebUiSettings(
            context: context,
            presentStyle: WebPresentStyle.dialog,
          ),
        );
      }

      final CroppedFile? croppedFile = await ImageCropper().cropImage(
        sourcePath: filePath,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        compressQuality: 85,
        maxWidth: 1024,
        maxHeight: 1024,
        compressFormat: ImageCompressFormat.jpg,
        uiSettings: uiSettings,
      );

      if (croppedFile != null) {
        return File(croppedFile.path);
      }
    } catch (e) {
      debugPrint('Error cropping image: $e');
    }
    return null;
  }

  /// Shows a modal bottom sheet allowing user to choose between Camera and Gallery.
  static Future<ImageSource?> showSourcePickerDialog(BuildContext context) async {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: isDarkMode ? const Color(0xFF1F1D2B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Pilih Sumber Foto',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A1E79).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.camera_alt, color: Color(0xFF4A1E79)),
                ),
                title: Text(
                  'Kamera',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                subtitle: Text(
                  'Ambil foto baru menggunakan kamera',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8938DF).withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.photo_library, color: Color(0xFF8938DF)),
                ),
                title: Text(
                  'Galeri',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDarkMode ? Colors.white : Colors.black87,
                  ),
                ),
                subtitle: Text(
                  'Pilih foto dari galeri perangkat',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
}
