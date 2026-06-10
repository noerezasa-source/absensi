// lib/services/tts_service.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../helpers/language_helper.dart';

/// Singleton TTS Service yang otomatis menyesuaikan bahasa
/// dengan bahasa yang aktif di aplikasi (ID, EN, AR).
class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  String _lastSpokenText = '';

  /// Mapping language code → BCP-47 locale untuk TTS engine
  static const Map<String, String> _langToLocale = {
    'id': 'id-ID',
    'en': 'en-US',
    'ar': 'ar-SA',
  };

  /// Inisialisasi TTS engine, hanya dijalankan sekali
  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setSpeechRate(0.5); // sedikit lebih lambat agar jelas
      await _flutterTts.setPitch(1.0);

      _flutterTts.setStartHandler(() {
        _isSpeaking = true;
      });
      _flutterTts.setCompletionHandler(() {
        _isSpeaking = false;
      });
      _flutterTts.setErrorHandler((msg) {
        _isSpeaking = false;
        debugPrint('TTS Error: $msg');
      });

      _isInitialized = true;
      debugPrint('✅ TTS Service initialized');
    } catch (e) {
      debugPrint('!!! TTS init failed: $e');
    }
  }

  DateTime? _lastSpeakTime;

  /// Ucapkan teks. Jika teks sama dengan yang baru saja diucapkan
  /// dalam 3 detik terakhir, skip untuk menghindari spam.
  Future<void> speak(String text, {bool force = false}) async {
    if (!_isInitialized) await initialize();
    if (text.isEmpty) return;

    final now = DateTime.now();
    if (!force &&
        _lastSpeakTime != null &&
        now.difference(_lastSpeakTime!) < const Duration(seconds: 3) &&
        _lastSpokenText == text) {
      return;
    }

    try {
      _lastSpeakTime = now;
      // Set bahasa sesuai bahasa aktif aplikasi
      final lang = AppLanguage.currentLanguage;
      final locale = _langToLocale[lang] ?? 'id-ID';
      await _flutterTts.setLanguage(locale);

      // Hentikan ucapan sebelumnya jika ada
      if (_isSpeaking) {
        await _flutterTts.stop();
      }

      _lastSpokenText = text;
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('TTS speak error: $e');
    }
  }

  /// Ucapkan teks berdasarkan key terjemahan dari file JSON tertentu
  /// prefix: 'attendance.face_registration' atau 'attendance.fingerprint'
  Future<void> speakKey(String key, {String prefix = 'attendance.face_registration'}) async {
    final text = AppLanguage.tr('$prefix.$key');
    // Jika key tidak ditemukan (dikembalikan sebagai key itu sendiri), skip
    if (text == '$prefix.$key') {
      debugPrint('TTS: Key not found: $key (prefix: $prefix), skipping');
      return;
    }
    await speak(text);
  }

  /// Hentikan ucapan yang sedang berjalan
  Future<void> stop() async {
    if (!_isInitialized) return;
    try {
      await _flutterTts.stop();
      _isSpeaking = false;
    } catch (e) {
      debugPrint('TTS stop error: $e');
    }
  }

  /// Dispose TTS engine (panggil saat widget dispose)
  Future<void> dispose() async {
    try {
      await _flutterTts.stop();
    } catch (_) {}
  }
}
