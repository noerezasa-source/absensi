import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'signup.dart';
import 'join_organization_screen.dart';

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

  // Modern Color Scheme
  static const Color primaryColor = Color(0xFF6366F1);
  static const Color secondaryColor = Color(0xFF8B5CF6);
  static const Color backgroundColor = Color(0xFFF8FAFC);
  static const Color cardColor = Colors.white;
  static const Color textPrimary = Color(0xFF1E293B);
  static const Color textSecondary = Color(0xFF64748B);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _extractNameFromEmail(String email) {
    try {
      String namePart = email.split('@')[0];
      namePart = namePart.replaceAll(RegExp(r'[_.\-0-9]'), ' ').trim();
      
      List<String> words = namePart.split(' ').where((w) => w.isNotEmpty).toList();
      String capitalizedName = words
          .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
          .join(' ')
          .trim();
      
      return capitalizedName.isEmpty ? email.split('@')[0] : capitalizedName;
    } catch (e) {
      debugPrint('Error extracting name from email: $e');
      return email.split('@')[0];
    }
  }

  Map<String, String> _splitName(String fullName) {
    List<String> nameParts = fullName.trim().split(' ').where((n) => n.isNotEmpty).toList();
    
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

  Future<bool> _ensureUserProfile(String userId, String email, {String? googleName}) async {
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
        
        await supabase
            .from('user_profiles')
            .insert({
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
        
        final hasValidName = existingProfile['first_name'] != null && 
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
      Navigator.of(context).pop();
      
      if (!mounted) return;

      if (hasOrganization) {
        _showSnackBar('Login berhasil! User sudah punya organisasi.', true);
        debugPrint('✓ User has organization - should navigate to MainDashboard');
      } else {
        Navigator.pushAndRemoveUntil(
          context,
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
      
      _showSnackBar('Gagal memeriksa organisasi: ${e.toString()}', false);
    }
  }

  Future<void> _signInWithEmail() async {
    if (_isLoading) return;
    
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
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
          debugPrint('⚠️ Warning: Profile creation/update failed, but continuing...');
        }

        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_email', user.email!);

        if (!mounted) return;
        await _navigateAfterLogin(user.id);
      }
    } catch (e) {
      debugPrint('❌ Login error: $e');
      if (!mounted) return;
      
      String errorMessage = 'Terjadi kesalahan saat login';
      
      if (e is AuthException) {
        if (e.message.toLowerCase().contains('invalid login credentials') ||
            e.message.toLowerCase().contains('invalid_credentials')) {
          errorMessage = 'Email atau password salah';
        } else if (e.message.toLowerCase().contains('email not confirmed')) {
          errorMessage = 'Email belum dikonfirmasi';
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

    // ✅ Google Sign In - Supabase + Google Cloud Console Only
  Future<void> _signInWithGoogle() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      debugPrint('🔵 Starting Google Sign In...');

      // ✅ Semua Client ID yang kamu punya (baru & lama)
      const webClientId = '210380129521-9kb8of23fk2jrf6p09do71v4df4asehf.apps.googleusercontent.com';
      const androidClientIds = [
        '210380129521-9qcqse1mqa96aqo6liereotg82bquv8d.apps.googleusercontent.com',
        '210380129521-lto171n9tpf699ihsga5skrjm908j0si.apps.googleusercontent.com',
        '210380129521-tt2solatsiu1ieo6547kmgu6pfl19t7a.apps.googleusercontent.com',
      ];

      // ✅ Ambil yang pertama dulu
      String activeAndroidClientId = androidClientIds.first;

      GoogleSignIn? googleSignIn;
      GoogleSignInAccount? googleUser;
      GoogleSignInAuthentication? googleAuth;

      bool success = false;

      // 🔄 Coba login pakai masing-masing client ID sampai berhasil
      for (final clientId in androidClientIds) {
        try {
          debugPrint('🧩 Trying Google Sign In with clientId: $clientId');

          googleSignIn = GoogleSignIn(
            serverClientId: webClientId, // Supabase pakai Web Client ID
            clientId: clientId,          // Android/iOS pakai ID ini
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

      // ✅ Auth ke Supabase
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

      // ✅ Buat atau update profil user
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

    } catch (e) {
      debugPrint('❌ Error during Google Sign In: $e');
      if (!mounted) return;
      _showSnackBar('Gagal login dengan Google: ${e.toString()}', false);
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
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildHeader(),
                  const SizedBox(height: 48),
                  _buildLoginCard(),
                  const SizedBox(height: 24),
                  _buildSignUpLink(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [primaryColor, secondaryColor],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: primaryColor.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(
            Icons.fingerprint,
            size: 40,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Absensi',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sistem Absensi Modern',
          style: TextStyle(
            fontSize: 16,
            color: textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildLoginCard() {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Selamat Datang 👋',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Silakan login untuk melanjutkan',
                style: TextStyle(
                  fontSize: 14,
                  color: textSecondary,
                ),
              ),
              const SizedBox(height: 32),
              _buildGoogleButton(),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: Divider(color: Colors.grey.shade300)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'atau',
                      style: TextStyle(
                        color: textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: Colors.grey.shade300)),
                ],
              ),
              const SizedBox(height: 24),
              _buildEmailField(),
              const SizedBox(height: 16),
              _buildPasswordField(),
              const SizedBox(height: 24),
              _buildLoginButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: OutlinedButton(
        onPressed: _isLoading ? null : _signInWithGoogle,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey.shade300, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/logo/logo_google.png',
                    height: 24,
                    width: 24,
                    errorBuilder: (context, error, stackTrace) {
                      return Icon(
                        Icons.g_mobiledata,
                        size: 28,
                        color: Colors.grey.shade700,
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Lanjutkan dengan Google',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildEmailField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Email',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _emailController,
          enabled: !_isLoading,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            hintText: 'nama@email.com',
            prefixIcon: const Icon(Icons.email_outlined),
            filled: true,
            fillColor: Colors.grey.shade50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: primaryColor, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Email harus diisi';
            }
            if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
              return 'Format email tidak valid';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Password',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _passwordController,
          enabled: !_isLoading,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            hintText: 'Masukkan password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: () {
                setState(() {
                  _obscurePassword = !_obscurePassword;
                });
              },
            ),
            filled: true,
            fillColor: Colors.grey.shade50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: primaryColor, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Password harus diisi';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _signInWithEmail,
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
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
            : const Text(
                'Masuk',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  Widget _buildSignUpLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Belum punya akun? ',
          style: TextStyle(
            color: textSecondary,
            fontSize: 14,
          ),
        ),
        TextButton(
          onPressed: _isLoading
              ? null
              : () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const ModernSignupScreen()),
                  );
                },
          child: const Text(
            'Daftar',
            style: TextStyle(
              color: primaryColor,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}