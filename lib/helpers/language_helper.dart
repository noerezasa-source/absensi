// lib/helpers/language_helper.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageHelper {
  static const String _languageKey = 'selected_language';
  
  // Supported languages
  static const String indonesian = 'id';
  static const String english = 'en';
  
  // Default language
  static const String defaultLanguage = indonesian; // English sebagai default
  
  static String _currentLanguage = defaultLanguage;
  
  // ValueNotifier untuk notify perubahan bahasa ke semua halaman
  static final ValueNotifier<String> languageNotifier = ValueNotifier<String>(defaultLanguage);
  
  static String get currentLanguage => _currentLanguage;
  
  // Get saved language
  static Future<String> getSavedLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString(_languageKey);
    
    if (savedLang != null) {
      _currentLanguage = savedLang;
      languageNotifier.value = savedLang;
      return savedLang;
    }
    
    // If no saved language, use default
    _currentLanguage = defaultLanguage;
    languageNotifier.value = defaultLanguage;
    return defaultLanguage;
  }
  
  // Save language
  static Future<void> saveLanguage(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, languageCode);
    _currentLanguage = languageCode;
    languageNotifier.value = languageCode;
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
    
    // Join Organization Screen
    'join_org_welcome': {
      'id': 'Selamat Datang',
      'en': 'Welcome',
    },
    'join_org_title': {
      'id': 'Kode Organisasi',
      'en': 'Organization Code',
    },
    'join_org_subtitle': {
      'id': 'Masukkan kode undangan yang diberikan oleh HR atau admin Anda',
      'en': 'Enter the invitation code provided by your HR or admin',
    },
    'join_org_input_hint': {
      'id': 'MASUKKAN-KODE',
      'en': 'ENTER-CODE',
    },
    'join_org_info': {
      'id': 'Tanyakan HR atau admin organisasi untuk kode undangan',
      'en': 'Ask your HR or organization admin for the invitation code',
    },
    'join_org_button': {
      'id': 'Gabung Organisasi',
      'en': 'Join Organization',
    },
    'join_org_button_short': {
      'id': 'Bergabung',
      'en': 'Join',
    },
    'join_org_logout': {
      'id': 'Keluar',
      'en': 'Logout',
    },
    'join_org_logout_title': {
      'id': 'Konfirmasi Keluar',
      'en': 'Confirm Logout',
    },
    'join_org_logout_message': {
      'id': 'Apakah Anda yakin ingin keluar?',
      'en': 'Are you sure you want to logout?',
    },
    'join_org_cancel': {
      'id': 'Batal',
      'en': 'Cancel',
    },
    'join_org_continue': {
      'id': 'Lanjutkan',
      'en': 'Continue',
    },
    
    // Join Organization Success & Error Messages
    'join_org_success_title': {
      'id': 'Berhasil Bergabung',
      'en': 'Successfully Joined',
    },
    'join_org_success_message': {
      'id': 'Anda telah bergabung dengan\n{org}',
      'en': 'You have joined\n{org}',
    },
    'join_org_already_member': {
      'id': 'Anda sudah tergabung di {org}',
      'en': 'You are already a member of {org}',
    },
    'join_org_enter_code': {
      'id': 'Silakan masukkan kode undangan',
      'en': 'Please enter invitation code',
    },
    'join_org_error': {
      'id': 'Gagal bergabung dengan organisasi',
      'en': 'Failed to join organization',
    },
    'join_org_invalid_code': {
      'id': 'Kode undangan tidak valid',
      'en': 'Invalid invitation code',
    },
    'join_org_already_joined': {
      'id': 'Anda sudah tergabung di organisasi ini',
      'en': 'You are already a member of this organization',
    },
    'join_org_not_authenticated': {
      'id': 'Pengguna tidak terautentikasi',
      'en': 'User not authenticated',
    },
    'join_org_logout_failed': {
      'id': 'Gagal keluar',
      'en': 'Failed to logout',
    },
    'join_org_dashboard_todo': {
      'id': 'MainDashboard belum dibuat',
      'en': 'MainDashboard not yet created',
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
      'id': 'Pendaftaran Berhasil',
      'en': 'Registration Successful',
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
  static String _currentLang = LanguageHelper.defaultLanguage;
  
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