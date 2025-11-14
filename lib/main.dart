import 'package:absensimassal/helpers/language_helper.dart';
import 'package:absensimassal/pages/login.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Import halaman yang diperlukan
// import 'pages/join_organization_screen.dart';
// import 'pages/main_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://oxkuxwkehinhyxfsauqe.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im94a3V4d2tlaGluaHl4ZnNhdXFlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc5NDYxOTMsImV4cCI6MjA3MzUyMjE5M30.g3BjGtZCSFxnBDwMWkaM2mEcnCkoDL92fvTP_gUgR20',
  );
  await AppLanguage.init();
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

  @override
  void initState() {
    super.initState();
    
    // Initialize animations
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    _scaleAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutBack,
      ),
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeIn,
      ),
    );
    
    _rotateAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeInOut,
      ),
    );
    
    _animationController.forward();
    _navigateToNextScreen();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _checkMembershipAndNavigate() async {
    if (!mounted) return;

    final session = Supabase.instance.client.auth.currentSession;

    // Jika tidak ada session, arahkan ke Login
    if (session == null) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
      return;
    }

    try {
      final userId = session.user.id;
      
      // Check apakah user sudah join organization
      final memberResponse = await Supabase.instance.client
          .from('organization_members')
          .select('id')
          .eq('user_id', userId)
          .eq('is_active', true)
          .maybeSingle();

      if (!mounted) return;

      if (memberResponse != null) {
        // User sudah punya organization, ke Dashboard
        // TODO: Uncomment dan sesuaikan dengan nama class Dashboard Anda
        // Navigator.of(context).pushReplacement(
        //   MaterialPageRoute(builder: (context) => const MainDashboard()),
        // );
        
        // Sementara ke Login (ganti nanti)
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
        );
        
        debugPrint('✅ User has organization - should navigate to Dashboard');
      } else {
        // User belum punya organization, ke Join Organization
        // TODO: Uncomment dan sesuaikan dengan nama class Join Organization Anda
        // Navigator.of(context).pushReplacement(
        //   MaterialPageRoute(builder: (context) => const JoinOrganizationScreen()),
        // );
        
        // Sementara ke Login (ganti nanti)
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
        );
        
        debugPrint('⚠️ User has no organization - should navigate to Join Organization');
      }
    } catch (e) {
      debugPrint('❌ Error checking organization membership: $e');
      
      if (!mounted) return;
      
      // Jika error, arahkan ke Join Organization untuk aman
      // Navigator.of(context).pushReplacement(
      //   MaterialPageRoute(builder: (context) => const JoinOrganizationScreen()),
      // );
      
      // Sementara ke Login
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
      );
    }
  }

  Future<void> _navigateToNextScreen() async {
    // Tampilkan splash selama 2.5 detik
    await Future.delayed(const Duration(milliseconds: 2500));
    
    if (!mounted) return;
    
    // Check membership dan navigate
    await _checkMembershipAndNavigate();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF6366F1),
              Color(0xFF8B5CF6),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Animated Logo
                ScaleTransition(
                  scale: _scaleAnimation,
                  child: RotationTransition(
                    turns: _rotateAnimation,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 30,
                            offset: const Offset(0, 15),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.fingerprint,
                        size: 70,
                        color: Color(0xFF6366F1),
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 40),
                
                // App Name
                const Text(
                  'ABSENSI',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 8,
                  ),
                ),
                
                const SizedBox(height: 12),
                
                // Tagline
                Text(
                  'Sistem Absensi Modern',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withOpacity(0.9),
                    letterSpacing: 2,
                  ),
                ),
                
                const SizedBox(height: 60),
                
                // Loading Indicator
                SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.white.withOpacity(0.8),
                    ),
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Loading Text
                Text(
                  'Memuat...',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withOpacity(0.8),
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}