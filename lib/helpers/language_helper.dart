// lib/helpers/language_helper.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageHelper {
  static const String _languageKey = 'selected_language';
  
  // Supported languages
  static const String indonesian = 'id';
  static const String english = 'en';
  
  // Get saved language
  static Future<String> getSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_languageKey) ?? indonesian; // Default to Indonesian
  }
  
  // Save language
  static Future<void> saveLanguage(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, languageCode);
  }
  
  // Get all translations
  static Map<String, Map<String, String>> get translations => {
    // Login Screen
    'welcome': {
      'id': 'Selamat Datang',
      'en': 'Welcome',
    },
    'to_facegate': {
      'id': 'Di WeFace',
      'en': 'To WeFace',
    },
    'email_address': {
      'id': 'Alamat Email',
      'en': 'Email Address',
    },
    'email_hint': {
      'id': 'Masukkan email anda',
      'en': 'Enter your email',
    },
    'password': {
      'id': 'Kata Sandi',
      'en': 'Password',
    },
    'password_hint': {
      'id': 'Masukkan password anda',
      'en': 'Enter your password',
    },
    'login': {
      'id': 'Masuk',
      'en': 'Login',
    },
    'or': {
      'id': 'Atau',
      'en': 'Or',
    },
    'sign_in_with_google': {
      'id': 'Masuk dengan Google',
      'en': 'Sign in with Google',
    },
    'dont_have_account': {
      'id': 'Belum punya Akun? ',
      'en': 'Don\'t have an Account? ',
    },
    'sign_up': {
      'id': 'Daftar',
      'en': 'Sign Up',
    },
    
    // Signup Screen
    'create_your': {
      'id': 'Buat Akun',
      'en': 'Create Your',
    },
    'facegate_account': {
      'id': 'WeFace Anda',
      'en': 'WeFace Account',
    },
    'full_name': {
      'id': 'Nama Lengkap',
      'en': 'Full Name',
    },
    'full_name_hint': {
      'id': 'Masukkan nama lengkap',
      'en': 'Enter your full name',
    },
    'email_hint_signup': {
      'id': 'Masukkan email Anda',
      'en': 'Enter your email',
    },
    'password_hint_signup': {
      'id': 'Buat kata sandi',
      'en': 'Create password',
    },
    'agree_terms': {
      'id': 'Saya setuju dengan Syarat dan Ketentuan',
      'en': 'I agree to the Terms and Conditions',
    },
    'already_have_account': {
      'id': 'Sudah punya Akun? ',
      'en': 'Already have an Account? ',
    },
    
    // Validation Messages
    'email_required': {
      'id': 'Email harus diisi',
      'en': 'Email is required',
    },
    'email_invalid': {
      'id': 'Format email tidak valid',
      'en': 'Invalid email format',
    },
    'password_required': {
      'id': 'Kata sandi harus diisi',
      'en': 'Password is required',
    },
    'password_min_length': {
      'id': 'Kata sandi minimal 6 karakter',
      'en': 'Password must be at least 6 characters',
    },
    'name_required': {
      'id': 'Nama lengkap harus diisi',
      'en': 'Full name is required',
    },
    'name_min_length': {
      'id': 'Nama minimal 3 karakter',
      'en': 'Name must be at least 3 characters',
    },
    'terms_required': {
      'id': 'Anda harus menyetujui syarat dan ketentuan',
      'en': 'You must agree to the terms and conditions',
    },
    
    // Error Messages
    'login_error': {
      'id': 'Terjadi kesalahan saat masuk',
      'en': 'An error occurred during login',
    },
    'invalid_credentials': {
      'id': 'Email atau kata sandi salah',
      'en': 'Invalid email or password',
    },
    'email_not_confirmed': {
      'id': 'Email belum dikonfirmasi',
      'en': 'Email not confirmed',
    },
    'signup_error': {
      'id': 'Terjadi kesalahan saat mendaftar',
      'en': 'An error occurred during signup',
    },
    'email_already_registered': {
      'id': 'Email sudah terdaftar',
      'en': 'Email already registered',
    },
    'weak_password': {
      'id': 'Kata sandi terlalu lemah',
      'en': 'Password is too weak',
    },
    'network_error': {
      'id': 'Kesalahan koneksi jaringan',
      'en': 'Network connection error',
    },
    'google_signin_failed': {
      'id': 'Gagal masuk dengan Google',
      'en': 'Failed to sign in with Google',
    },
    'failed_create_account': {
      'id': 'Gagal membuat akun',
      'en': 'Failed to create account',
    },
    'check_organization_failed': {
      'id': 'Gagal memeriksa organisasi',
      'en': 'Failed to check organization',
    },
    
    // Success Messages
    'login_success': {
      'id': 'Login berhasil! User sudah punya organisasi.',
      'en': 'Login successful! User already has an organization.',
    },
    'signup_success_title': {
      'id': 'Pendaftaran Berhasil! 🎉',
      'en': 'Registration Successful! 🎉',
    },
    'signup_success_message': {
      'id': 'Akun Anda telah berhasil dibuat.\nSilakan masuk untuk melanjutkan.',
      'en': 'Your account has been successfully created.\nPlease login to continue.',
    },
    'continue_to_login': {
      'id': 'Lanjut Masuk',
      'en': 'Continue to Login',
    },
    
    // Language Selector
    'language': {
      'id': 'Bahasa',
      'en': 'Language',
    },
    'indonesian': {
      'id': 'Bahasa Indonesia',
      'en': 'Indonesian',
    },
    'english': {
      'id': 'Bahasa Inggris',
      'en': 'English',
    },
  };
  
  // Get translation by key
  static String translate(String key, String languageCode) {
    return translations[key]?[languageCode] ?? key;
  }
}

// Simple helper method to get translation with current language
class AppLanguage {
  static String _currentLang = LanguageHelper.indonesian;
  
  static Future<void> init() async {
    _currentLang = await LanguageHelper.getSavedLanguage();
  }
  
  static String get currentLanguage => _currentLang;
  
  static Future<void> setLanguage(String languageCode) async {
    _currentLang = languageCode;
    await LanguageHelper.saveLanguage(languageCode);
  }
  
  static String tr(String key) {
    return LanguageHelper.translate(key, _currentLang);
  }
}