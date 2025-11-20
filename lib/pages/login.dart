import 'dart:io';
import 'package:absensimassal/pages/petugas_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'signup.dart';
import 'join_organization_screen.dart';
import '../services/role_service.dart';
import 'petugas_dashboard.dart';
import 'user_dashboard.dart';
import '../helpers/language_helper.dart';

class ModernLoginScreen extends StatefulWidget {
  const ModernLoginScreen({super.key});

  @override
  State<ModernLoginScreen> createState() => _ModernLoginScreenState();
}

class _ModernLoginScreenState extends State<ModernLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;

  final supabase = Supabase.instance.client;
  final RoleService _roleService = RoleService();

  // Color Scheme
  static const Color primaryColor = Color(0xFF1A1A1A);
  static const Color backgroundColor = Color(0xFFE8F4F8);
  static const Color textPrimary = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF666666);
  static const Color inputFillColor = Color(0xFFF5F5F5);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // Cek koneksi internet
  Future<bool> _checkInternetConnection() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      
      if (connectivityResult == ConnectivityResult.none) {
        return false;
      }
      
      // Double check dengan ping ke Google DNS
      final result = await InternetAddress.lookup('google.com');
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Connection check error: $e');
      return false;
    }
  }

  String _extractNameFromEmail(String email) {
    try {
      String namePart = email.split('@')[0];
      namePart = namePart.replaceAll(RegExp(r'[_.\-0-9]'), ' ').trim();

      List<String> words = namePart
          .split(' ')
          .where((w) => w.isNotEmpty)
          .toList();
      String capitalizedName = words
          .map(
            (word) => word[0].toUpperCase() + word.substring(1).toLowerCase(),
          )
          .join(' ')
          .trim();

      return capitalizedName.isEmpty ? email.split('@')[0] : capitalizedName;
    } catch (e) {
      debugPrint('Error extracting name from email: $e');
      return email.split('@')[0];
    }
  }

  Map<String, String> _splitName(String fullName) {
    List<String> nameParts = fullName
        .trim()
        .split(' ')
        .where((n) => n.isNotEmpty)
        .toList();

    if (nameParts.isEmpty) {
      return {'first_name': 'User', 'last_name': ''};
    } else if (nameParts.length == 1) {
      return {'first_name': nameParts[0], 'last_name': ''};
    } else {
      String firstName = nameParts[0];
      String lastName = nameParts.sublist(1).join(' ');
      return {'first_name': firstName, 'last_name': lastName};
    }
  }

  Future<bool> _ensureUserProfile(
    String userId,
    String email, {
    String? googleName,
  }) async {
    try {
      debugPrint('Ensuring user profile for: $userId');

      final existingProfile = await supabase
          .from('user_profiles')
          .select('id, first_name, last_name, display_name, email')
          .eq('id', userId)
          .maybeSingle();

      String fullName = googleName?.isNotEmpty == true
          ? googleName!
          : _extractNameFromEmail(email);

      final nameParts = _splitName(fullName);
      final firstName = nameParts['first_name']!;
      final lastName = nameParts['last_name']!;

      if (existingProfile == null) {
        debugPrint('Creating new user profile...');

        await supabase.from('user_profiles').insert({
          'id': userId,
          'first_name': firstName,
          'last_name': lastName,
          'display_name': fullName,
          'email': email,
          'is_active': true,
        });

        debugPrint('✓ User profile created successfully');
        return true;
      } else {
        debugPrint('User profile already exists');

        final hasValidName =
            existingProfile['first_name'] != null &&
            existingProfile['first_name'].toString().isNotEmpty &&
            existingProfile['first_name'] != 'User';

        if (!hasValidName) {
          await supabase
              .from('user_profiles')
              .update({
                'first_name': firstName,
                'last_name': lastName,
                'display_name': fullName,
                'email': email,
              })
              .eq('id', userId);

          debugPrint('✓ User profile updated with name');
        }
        return true;
      }
    } catch (e) {
      debugPrint('❌ Error ensuring user profile: $e');
      return false;
    }
  }

  Future<bool> _userHasOrganization(String userId) async {
    try {
      final response = await supabase
          .from('organization_members')
          .select('id')
          .eq('user_id', userId)
          .eq('is_active', true)
          .maybeSingle();

      return response != null;
    } catch (e) {
      debugPrint('Error checking user organization: $e');
      return false;
    }
  }

  Future<void> _navigateAfterLogin(String userId) async {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
        ),
      ),
    );

    try {
      final hasOrganization = await _userHasOrganization(userId);

      if (!mounted) return;
      Navigator.of(context).pop(); // Close loading dialog

      if (!mounted) return;

      if (hasOrganization) {
        debugPrint('✓ User has organization - checking role');
        _showSnackBar(AppLanguage.tr('login_success'), true);

        final memberData = await _roleService.getOrganizationMemberWithRole(userId);

        if (memberData == null) {
          throw Exception('Failed to fetch member data');
        }

        final organizationMemberId = memberData['id'] as int;

        if (!mounted) return;

        if (_roleService.isPetugas(memberData)) {
          debugPrint('✓ User is Admin - navigating to Petugas Dashboard');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => PetugasDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
            (route) => false,
          );
        } else if (_roleService.isUser(memberData)) {
          debugPrint('✓ User is Regular User - navigating to User Dashboard');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => UserDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
            (route) => false,
          );
        } else {
          debugPrint('⚠️ Unknown role - navigating to User Dashboard');
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (context) => UserDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
            (route) => false,
          );
        }
      } else {
        debugPrint('⚠️ User has no organization - navigating to Join Organization');
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const JoinOrganizationScreen(),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      debugPrint('Error checking organization: $e');

      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      _showSnackBar(
        '${AppLanguage.tr('check_organization_failed')}: ${e.toString()}',
        false,
      );
    }
  }

  Future<void> _signInWithEmail() async {
    if (_isLoading) return;

    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // CEK KONEKSI INTERNET DULU
      final hasConnection = await _checkInternetConnection();
      if (!hasConnection) {
        throw SocketException('Tidak ada koneksi internet');
      }

      debugPrint('Attempting email login...');

      final res = await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      final user = res.user;
      if (user != null) {
        debugPrint('✓ Email login successful, user ID: ${user.id}');

        final profileCreated = await _ensureUserProfile(user.id, user.email!);

        if (!profileCreated) {
          debugPrint(
            '⚠️ Warning: Profile creation/update failed, but continuing...',
          );
        }

        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_email', user.email!);

        if (!mounted) return;
        await _navigateAfterLogin(user.id);
      }
    } on SocketException catch (e) {
      debugPrint('❌ No internet connection: $e');
      if (!mounted) return;
      _showSnackBar(
        'Tidak ada koneksi internet. Mohon periksa koneksi Anda dan coba lagi.',
        false,
      );
    } catch (e) {
      debugPrint('❌ Login error: $e');
      if (!mounted) return;

      String errorMessage = AppLanguage.tr('login_error');

      // Check for network errors
      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup') ||
          e.toString().toLowerCase().contains('network')) {
        errorMessage = 'Tidak ada koneksi internet. Mohon periksa koneksi Anda.';
      } else if (e is AuthException) {
        if (e.message.toLowerCase().contains('invalid login credentials') ||
            e.message.toLowerCase().contains('invalid_credentials')) {
          errorMessage = AppLanguage.tr('invalid_credentials');
        } else if (e.message.toLowerCase().contains('email not confirmed')) {
          errorMessage = AppLanguage.tr('email_not_confirmed');
        } else {
          errorMessage = e.message;
        }
      }

      _showSnackBar(errorMessage, false);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      // CEK KONEKSI INTERNET DULU
      final hasConnection = await _checkInternetConnection();
      if (!hasConnection) {
        throw SocketException('Tidak ada koneksi internet');
      }

      debugPrint('🔵 Starting Google Sign In...');

      const webClientId =
          '210380129521-9kb8of23fk2jrf6p09do71v4df4asehf.apps.googleusercontent.com';
      const androidClientIds = [
        '210380129521-tt2solatsiu1ieo6547kmgu6pfl19t7a.apps.googleusercontent.com',
        '210380129521-lr442btemji6k32tnh4a29llllapc8q9.apps.googleusercontent.com',
      ];

      String activeAndroidClientId = androidClientIds.first;

      GoogleSignIn? googleSignIn;
      GoogleSignInAccount? googleUser;
      GoogleSignInAuthentication? googleAuth;

      bool success = false;

      for (final clientId in androidClientIds) {
        try {
          debugPrint('🧩 Trying Google Sign In with clientId: $clientId');

          googleSignIn = GoogleSignIn(
            serverClientId: webClientId,
            clientId: clientId,
            scopes: ['email', 'profile', 'openid'],
          );

          await googleSignIn.signOut();
          googleUser = await googleSignIn.signIn();

          if (googleUser == null) {
            debugPrint('⚠️ User cancelled sign in');
            setState(() => _isLoading = false);
            return;
          }

          googleAuth = await googleUser.authentication;
          if (googleAuth.idToken != null) {
            activeAndroidClientId = clientId;
            success = true;
            debugPrint('✅ Sign-in successful with clientId: $clientId');
            break;
          }
        } catch (e) {
          debugPrint('❌ Failed with clientId $clientId: $e');
          continue;
        }
      }

      if (!success || googleAuth?.idToken == null) {
        throw Exception('Semua Client ID gagal. Cek konfigurasi Google Cloud.');
      }

      debugPrint('🔵 Authenticating with Supabase...');
      final response = await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: googleAuth!.idToken!,
        accessToken: googleAuth.accessToken,
      );

      final user = response.user;
      if (user == null) {
        throw Exception('Supabase authentication gagal: user null');
      }

      debugPrint('✅ Supabase auth success for ${user.email}');
      debugPrint('   Using Android Client: $activeAndroidClientId');

      await _ensureUserProfile(
        user.id,
        user.email!,
        googleName: googleUser?.displayName ?? user.userMetadata?['full_name'],
      );

      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_email', user.email!);
      await prefs.setBool('logged_in_with_google', true);

      if (!mounted) return;
      await _navigateAfterLogin(user.id);
    } on SocketException catch (e) {
      debugPrint('❌ No internet connection: $e');
      if (!mounted) return;
      _showSnackBar(
        'Tidak ada koneksi internet. Mohon periksa koneksi Anda dan coba lagi.',
        false,
      );
    } catch (e) {
      debugPrint('❌ Error during Google Sign In: $e');
      if (!mounted) return;
      
      String errorMessage = '${AppLanguage.tr('google_signin_failed')}: ${e.toString()}';
      
      if (e.toString().toLowerCase().contains('socketexception') ||
          e.toString().toLowerCase().contains('failed host lookup')) {
        errorMessage = 'Tidak ada koneksi internet. Mohon periksa koneksi Anda.';
      }
      
      _showSnackBar(errorMessage, false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: Duration(seconds: isSuccess ? 3 : 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      body: Container(
        height: screenHeight,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.white, Color.fromARGB(255, 120, 210, 240)],
            stops: [0.20, 1.2],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        SizedBox(height: screenHeight * 0.08),
                        _buildHeader(),
                        SizedBox(height: screenHeight * 0.05),
                        _buildLoginForm(),
                        const Spacer(),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${AppLanguage.tr('welcome')}\n',
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                    height: 1.2,
                  ),
                ),
                TextSpan(
                  text: AppLanguage.tr('to_facegate'),
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildLoginForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLanguage.tr('email_address'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _emailController,
            enabled: !_isLoading,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              hintText: AppLanguage.tr('email_hint'),
              hintStyle: const TextStyle(
                color: Color.fromARGB(255, 222, 221, 221),
              ),
              suffixIcon: Icon(
                Icons.email_outlined,
                color: Colors.grey.shade400,
              ),
              filled: true,
              fillColor: inputFillColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: primaryColor, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 18,
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return AppLanguage.tr('email_required');
              }
              if (!RegExp(
                r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$',
              ).hasMatch(value)) {
                return AppLanguage.tr('email_invalid');
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          Text(
            AppLanguage.tr('password'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: _passwordController,
            enabled: !_isLoading,
            obscureText: _obscurePassword,
            decoration: InputDecoration(
              hintText: AppLanguage.tr('password_hint'),
              hintStyle: const TextStyle(
                color: Color.fromARGB(255, 222, 221, 221),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: Colors.grey.shade400,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
              filled: true,
              fillColor: inputFillColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: primaryColor, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 18,
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return AppLanguage.tr('password_required');
              }
              return null;
            },
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _signInWithEmail,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade400,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(27),
                ),
                elevation: 0,
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      AppLanguage.tr('login'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Divider(color: Colors.grey.shade300, thickness: 1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  AppLanguage.tr('or'),
                  style: const TextStyle(color: textSecondary, fontSize: 14),
                ),
              ),
              Expanded(
                child: Divider(color: Colors.grey.shade300, thickness: 1),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: _isLoading ? null : _signInWithGoogle,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.grey.shade300),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                backgroundColor: Colors.white,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/logo/logo_google.png',
                    width: 24,
                    height: 24,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    AppLanguage.tr('sign_in_with_google'),
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  AppLanguage.tr('dont_have_account'),
                  style: const TextStyle(
                    color: textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                TextButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const ModernSignupScreen(),
                            ),
                          );
                        },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    AppLanguage.tr('sign_up'),
                    style: const TextStyle(
                      color: Color(0xFF00A3E0),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}