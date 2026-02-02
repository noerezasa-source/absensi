import 'package:absensimassal/helpers/language_helper.dart';
import 'package:absensimassal/auth/screens/login.dart';
import 'package:absensimassal/auth/screens/join_organization_screen.dart';
import 'package:absensimassal/Petugas/screens/petugas_dashboard.dart';
import 'package:absensimassal/User/screens/user_dashboard.dart';
import 'package:absensimassal/auth/services/role_service.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:absensimassal/services/attendance_sync_service.dart';
import 'package:google_fonts/google_fonts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://oxkuxwkehinhyxfsauqe.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im94a3V4d2tlaGluaHl4ZnNhdXFlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc5NDYxOTMsImV4cCI6MjA3MzUyMjE5M30.g3BjGtZCSFxnBDwMWkaM2mEcnCkoDL92fvTP_gUgR20',
  );
  await AppLanguage.init();
  
  // Start background sync service globally
  AttendanceSyncService().startAutoSync();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Absensi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _rotateAnimation;
  final RoleService _roleService = RoleService();

  @override
  void initState() {
    super.initState();
    
    // Initialize animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );
    
    // Hapus rotasi animasi yang berlebihan
    
    _animationController.forward();
    _navigateToNextScreen();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // ... (keep _checkAuthAndNavigate and _navigateToNextScreen as is)
  Future<void> _checkAuthAndNavigate() async {
    if (!mounted) return;

    final session = Supabase.instance.client.auth.currentSession;

    // Jika tidak ada session, arahkan ke Login
    if (session == null) {
      debugPrint('❌ No active session - navigating to Login');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
      return;
    }

    try {
      final userId = session.user.id;
      debugPrint('✅ Active session found for user: $userId');
      
      // Check apakah user sudah join organization dan ambil role
      final memberData = await _roleService.getOrganizationMemberWithRole(userId);

      if (!mounted) return;

      if (memberData != null) {
        final organizationMemberId = memberData['id'] as int;
        final roleName = _roleService.getRoleName(memberData);
        final roleCode = _roleService.getRoleCode(memberData);
        
        // Navigate berdasarkan role
        if (_roleService.isPetugas(memberData)) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => PetugasDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
          );
        } else if (_roleService.isUser(memberData)) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => UserDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
          );
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => UserDashboardPage(
                organizationMemberId: organizationMemberId,
                memberData: memberData,
              ),
            ),
          );
        }
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const JoinOrganizationScreen()),
        );
      }
    } catch (e) {
      debugPrint('❌ Error checking organization membership: $e');
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
    }
  }

  Future<void> _navigateToNextScreen() async {
    await Future.delayed(const Duration(milliseconds: 2500)); // Sedikit lebih lama untuk menikmati splash
    if (!mounted) return;
    await _checkAuthAndNavigate();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Background putih bersih lebih professional
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: _scaleAnimation,
                  child: Container(
                    padding: const EdgeInsets.all(20), // Add padding for the image
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white, // White background for the transparent logo
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withOpacity(0.3),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Image.asset(
                        'assets/logo/app_icon_new.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
              ),
              
              const SizedBox(height: 32),
              
              Column(
                children: [
                  Text(
                    'ABSENSI MASSAL',
                    style: GoogleFonts.montserrat(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFF1F2937), // Dark grey text
                      letterSpacing: 4.0, // Wide spacing for luxury feel
                      height: 1.2,
                      shadows: [
                         const BoxShadow(
                          color: Colors.black12,
                          offset: Offset(2, 2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Text(
                      'Smart Attendance System',
                      style: GoogleFonts.montserrat(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF6366F1), // Brand color
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 80), // Space sebelum loading indicator
              
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    const Color(0xFF6366F1).withOpacity(0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}