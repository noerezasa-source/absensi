import 'package:absensimassal/pages/petugas_dashboard.dart';
import 'package:absensimassal/pages/user_dashboard.dart';
import 'package:absensimassal/services/role_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
import 'package:absensimassal/helpers/language_helper.dart';


class JoinOrganizationScreen extends StatefulWidget {
  const JoinOrganizationScreen({super.key});

  @override
  State<JoinOrganizationScreen> createState() => _JoinOrganizationScreenState();
}

class _JoinOrganizationScreenState extends State<JoinOrganizationScreen> {
  // Color Scheme - Matching Signup Screen
  static const Color primaryColor = Color(0xFF1A1A1A);
  static const Color backgroundColor = Color(0xFFE8F4F8);
  static const Color textPrimary = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF666666);
  static const Color inputFillColor = Color(0xFFF5F5F5);
  static const Color accentColor = Color(0xFF00A3E0);

  final TextEditingController _invCodeController = TextEditingController();
  final RoleService _roleService = RoleService();

  bool _isJoining = false;
  bool _isInitializing = true;
  
  String? _displayName;
  String? _profilePhotoUrl;
  String _currentLanguage = LanguageHelper.indonesian;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
    _initializeScreen();
  }

  @override
  void dispose() {
    _invCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadLanguage() async {
    final lang = await LanguageHelper.getSavedLanguage();
    if (mounted) {
      setState(() => _currentLanguage = lang);
    }
  }

  String _tr(String key) {
    return LanguageHelper.translate(key, _currentLanguage);
  }

  Future<void> _initializeScreen() async {
    if (!mounted) return;

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        if (mounted) {
          setState(() => _isInitializing = false);
        }
        return;
      }

      // Load user profile
      debugPrint('Loading user profile for: ${user.id}');
      final profile = await Supabase.instance.client
          .from('user_profiles')
          .select('first_name, last_name, display_name, profile_photo_url, email')
          .eq('id', user.id)
          .maybeSingle();

      if (!mounted) return;

      if (profile != null) {
        setState(() {
          _displayName = profile['display_name'] ?? 
                        profile['first_name'] ?? 
                        user.email?.split('@')[0] ?? 
                        'User';
          _profilePhotoUrl = profile['profile_photo_url'];
        });
      } else {
        setState(() {
          _displayName = user.email?.split('@')[0] ?? 'User';
        });
      }

      // Check if user already has organization
      debugPrint('Checking existing organization membership...');
      final memberData = await _roleService.getOrganizationMemberWithRole(user.id);

      if (memberData != null && mounted) {
        final organizationMemberId = memberData['id'] as int;
        
        debugPrint('✓ User already has organization');
        
        _showSnackBar('You are already a member of an organization', true);

        await Future.delayed(const Duration(milliseconds: 800));

        if (!mounted) return;

        // Navigate berdasarkan role
        _navigateToDashboard(organizationMemberId, memberData);
      } else {
        if (mounted) {
          setState(() => _isInitializing = false);
        }
      }
    } catch (e) {
      debugPrint('Error initializing screen: $e');
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  Future<void> _joinOrganizationWithCode() async {
    final invCode = _invCodeController.text.trim().toUpperCase();

    if (invCode.isEmpty) {
      _showSnackBar(_tr('join_org_enter_code'), false);
      return;
    }

    setState(() => _isJoining = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('User tidak terautentikasi');
      }

      // STEP 1: Check if already member
      debugPrint('Step 1: Checking existing organization membership...');
      final existingMemberData = await _roleService.getOrganizationMemberWithRole(user.id);

      if (existingMemberData != null) {
        debugPrint('✓ User already has organization - redirecting');

        final organizationMemberId = existingMemberData['id'] as int;

        if (mounted) {
          _showSnackBar('You are already a member of an organization', true);

          await Future.delayed(const Duration(milliseconds: 500));

          if (!mounted) return;

          // Navigate berdasarkan role
          _navigateToDashboard(organizationMemberId, existingMemberData);
        }
        return;
      }

      // STEP 2: Validate invitation code
      debugPrint('Step 2: Validating invitation code: $invCode');
      final orgResponse = await Supabase.instance.client
          .from('organizations')
          .select('id, name, inv_code')
          .eq('inv_code', invCode)
          .eq('is_active', true)
          .maybeSingle();

      if (orgResponse == null) {
        throw Exception('Kode undangan tidak valid');
      }

      final orgId = orgResponse['id'];
      final orgName = orgResponse['name'];

      debugPrint('✓ Found organization: $orgName (ID: $orgId)');

      // STEP 3: Check if already member of THIS specific organization
      debugPrint('Step 3: Checking membership in this organization...');
      final existingMemberInOrg = await Supabase.instance.client
          .from('organization_members')
          .select('id, is_active')
          .eq('organization_id', orgId)
          .eq('user_id', user.id)
          .maybeSingle();

      int organizationMemberId;

      if (existingMemberInOrg != null) {
        if (existingMemberInOrg['is_active'] == true) {
          debugPrint('⚠️ User is already an active member of this organization');
          throw Exception('Anda sudah tergabung di organisasi ini');
        } else {
          debugPrint('Step 3b: Reactivating existing membership...');
          await Supabase.instance.client
              .from('organization_members')
              .update({
                'is_active': true,
                'work_location': 'field',
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('id', existingMemberInOrg['id']);

          organizationMemberId = existingMemberInOrg['id'] as int;
          debugPrint('✓ Re-activated existing membership, ID: $organizationMemberId');
        }
      } else {
        // STEP 4: Insert new member (default role: User - role_id: 2)
        debugPrint('Step 4: Creating new organization membership...');
        final newMember = await Supabase.instance.client
            .from('organization_members')
            .insert({
              'organization_id': orgId,
              'user_id': user.id,
              'role_id': 2, // Default role: User (US001)
              'hire_date': DateTime.now().toIso8601String().split('T')[0],
              'employment_status': 'active',
              'work_location': 'field',
              'is_active': true,
            })
            .select('id')
            .single();

        organizationMemberId = newMember['id'] as int;
        debugPrint('✓ Created new organization membership, ID: $organizationMemberId');
      }

      // STEP 5: Get member data with role
      final memberData = await _roleService.getOrganizationMemberWithRole(user.id);

      if (memberData == null) {
        throw Exception('Failed to fetch member data');
      }

      // STEP 6: Success - Show dialog and auto redirect after 2 seconds
      if (mounted) {
        _showSuccessDialog(orgName, organizationMemberId, memberData);
      }
    } catch (e) {
      debugPrint('Error joining organization: $e');
      if (mounted) {
        String errorMessage = _tr('join_org_error');

        if (e.toString().contains('tidak valid') || 
            e.toString().contains('not valid')) {
          errorMessage = _tr('join_org_invalid_code');
        } else if (e.toString().contains('sudah tergabung') ||
                   e.toString().contains('already')) {
          errorMessage = _tr('join_org_already_joined');
        } else if (e.toString().contains('terautentikasi') ||
                   e.toString().contains('authenticated')) {
          errorMessage = _tr('join_org_not_authenticated');
        }

        _showSnackBar(errorMessage, false);
      }
    } finally {
      if (mounted) {
        setState(() => _isJoining = false);
      }
    }
  }

  // Update method _navigateToDashboard di join_organization_screen.dart
// Ganti method ini dengan yang baru:

void _navigateToDashboard(int organizationMemberId, Map<String, dynamic> memberData) {
  debugPrint('=== NAVIGATING TO DASHBOARD ===');
  debugPrint('Organization Member ID: $organizationMemberId');
  debugPrint('Role: ${_roleService.getRoleName(memberData)}');

  if (_roleService.isPetugas(memberData)) {
    debugPrint('✓ Navigating to Petugas Dashboard');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => PetugasDashboardPage(
          organizationMemberId: organizationMemberId,
          memberData: memberData,
        ),
      ),
    );
  } else {
    debugPrint('✓ Navigating to User Dashboard');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => UserDashboardPage(
          organizationMemberId: organizationMemberId,
          memberData: memberData,
        ),
      ),
    );
  }
}

// JANGAN LUPA TAMBAHKAN IMPORT di bagian atas file:
// import 'petugas_dashboard.dart';

  void _showSuccessDialog(String orgName, int organizationMemberId, Map<String, dynamic> memberData) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        // Auto close after 2 seconds
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop(); // Close dialog
            _navigateToDashboard(organizationMemberId, memberData);
          }
        });

        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981).withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_circle,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _tr('join_org_success_title'),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  _tr('join_org_success_message').replaceAll('{org}', orgName),
                  style: const TextStyle(
                    fontSize: 15,
                    color: textSecondary,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: Colors.red.shade600,
                  size: 30,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _tr('join_org_logout_title'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _tr('join_org_logout_message'),
                style: const TextStyle(
                  fontSize: 14,
                  color: textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                      child: Text(
                        _tr('join_org_cancel'),
                        style: const TextStyle(
                          color: textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _tr('join_org_logout'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await Supabase.instance.client.auth.signOut();

        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        debugPrint('Error logging out: $e');
        if (mounted) {
          _showSnackBar(_tr('join_org_logout_failed'), false);
        }
      }
    }
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _displayName ?? 'User';
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    
    // Responsive sizing dengan breakpoint yang lebih detail
    final isVerySmallScreen = screenHeight < 600;
    final isSmallScreen = screenHeight < 700 && screenHeight >= 600;
    final isMediumScreen = screenHeight >= 700 && screenHeight < 900;
    final isTablet = screenWidth > 600;
    final isLargeTablet = screenWidth > 800;
    
    // Dynamic padding dan sizing
    final horizontalPadding = isLargeTablet ? 48.0 : (isTablet ? 40.0 : 24.0);
    final verticalPadding = isVerySmallScreen ? 8.0 : (isSmallScreen ? 12.0 : 16.0);
    final maxCardWidth = isLargeTablet ? 550.0 : (isTablet ? 500.0 : double.infinity);
    
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.white,
              Color.fromARGB(255, 120, 210, 240),
            ],
            stops: [0.20, 1.0],
          ),
        ),
        child: SafeArea(
          child: _isInitializing
              ? const Center(
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    strokeWidth: 3,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: IntrinsicHeight(
                          child: Center(
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: maxCardWidth,
                              ),
                              padding: EdgeInsets.symmetric(
                                horizontal: horizontalPadding,
                                vertical: verticalPadding,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // Top section: Logout button
                                  Align(
                                    alignment: Alignment.topRight,
                                    child: _buildLogoutButton(isVerySmallScreen, isSmallScreen),
                                  ),
                                  
                                  // Middle section: Header + Card
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        _buildHeader(
                                          displayName, 
                                          isVerySmallScreen, 
                                          isSmallScreen, 
                                          isTablet,
                                          isLargeTablet,
                                        ),
                                        SizedBox(
                                          height: isVerySmallScreen ? 12 : (isSmallScreen ? 16 : 24),
                                        ),
                                        _buildJoinCard(
                                          isVerySmallScreen, 
                                          isSmallScreen, 
                                          isTablet,
                                          isLargeTablet,
                                        ),
                                      ],
                                    ),
                                  ),
                                  
                                  // Bottom spacing
                                  SizedBox(height: isVerySmallScreen ? 4 : 8),
                                ],
                              ),
                            ),
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

  Widget _buildLogoutButton(bool isVerySmallScreen, bool isSmallScreen) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isJoining ? null : _handleLogout,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isVerySmallScreen ? 12 : 16,
              vertical: isVerySmallScreen ? 8 : 10,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.logout_rounded,
                  color: _isJoining ? Colors.grey : Colors.red,
                  size: isVerySmallScreen ? 16 : 18,
                ),
                SizedBox(width: isVerySmallScreen ? 4 : 6),
                Text(
                  _tr('join_org_logout'),
                  style: TextStyle(
                    color: _isJoining ? Colors.grey : Colors.red,
                    fontSize: isVerySmallScreen ? 13 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(
    String displayName, 
    bool isVerySmallScreen, 
    bool isSmallScreen, 
    bool isTablet,
    bool isLargeTablet,
  ) {
    final welcomeFontSize = isVerySmallScreen 
        ? 20.0 
        : (isSmallScreen ? 24.0 : (isLargeTablet ? 40.0 : (isTablet ? 36.0 : 28.0)));
    
    final avatarSize = isVerySmallScreen 
        ? 55.0 
        : (isSmallScreen ? 60.0 : (isTablet ? 80.0 : 70.0));
    
    final iconSize = isVerySmallScreen 
        ? 28.0 
        : (isSmallScreen ? 30.0 : (isTablet ? 40.0 : 35.0));
    
    final spacingAfterAvatar = isVerySmallScreen ? 10.0 : (isSmallScreen ? 12.0 : 16.0);

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _profilePhotoUrl != null
                ? ClipOval(
                    child: Image.network(
                      _profilePhotoUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Icon(
                          Icons.person,
                          size: iconSize,
                          color: textSecondary,
                        );
                      },
                    ),
                  )
                : Icon(
                    Icons.person,
                    size: iconSize,
                    color: textSecondary,
                  ),
          ),
          
          SizedBox(height: spacingAfterAvatar),

          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '${_tr('join_org_welcome')},\n',
                  style: TextStyle(
                    fontSize: welcomeFontSize,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                    height: 1.2,
                  ),
                ),
                TextSpan(
                  text: displayName,
                  style: TextStyle(
                    fontSize: welcomeFontSize,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinCard(
    bool isVerySmallScreen, 
    bool isSmallScreen, 
    bool isTablet,
    bool isLargeTablet,
  ) {
    final cardPadding = isVerySmallScreen 
        ? 16.0 
        : (isSmallScreen ? 20.0 : (isLargeTablet ? 36.0 : (isTablet ? 32.0 : 24.0)));
    
    final iconSize = isVerySmallScreen ? 44.0 : (isSmallScreen ? 48.0 : 56.0);
    final iconInnerSize = isVerySmallScreen ? 22.0 : (isSmallScreen ? 24.0 : 28.0);
    
    final titleFontSize = isVerySmallScreen 
        ? 16.0 
        : (isSmallScreen ? 18.0 : (isLargeTablet ? 24.0 : (isTablet ? 22.0 : 20.0)));
    
    final subtitleFontSize = isVerySmallScreen 
        ? 11.0 
        : (isSmallScreen ? 12.0 : 13.0);
    
    final inputFontSize = isVerySmallScreen 
        ? 14.0 
        : (isSmallScreen ? 16.0 : 18.0);
    
    final buttonHeight = isVerySmallScreen ? 44.0 : (isSmallScreen ? 48.0 : 52.0);

    return Container(
      padding: EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.business,
                  color: accentColor,
                  size: iconInnerSize,
                ),
              ),
              SizedBox(width: isVerySmallScreen ? 8 : 10),
              Text(
                _tr('join_org_title'),
                style: TextStyle(
                  fontSize: titleFontSize,
                  fontWeight: FontWeight.bold,
                  color: textPrimary,
                ),
              ),
            ],
          ),
          
          SizedBox(height: isVerySmallScreen ? 4 : 6),
          
          Text(
            _tr('join_org_subtitle'),
            style: TextStyle(
              fontSize: subtitleFontSize,
              color: textSecondary,
              height: 1.5,
            ),
          ),
          
          SizedBox(height: isVerySmallScreen ? 14 : (isSmallScreen ? 16 : 20)),

          TextField(
            controller: _invCodeController,
            enabled: !_isJoining,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: inputFontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: 3,
              color: textPrimary,
            ),
            decoration: InputDecoration(
              hintText: _tr('join_org_input_hint'),
              hintStyle: TextStyle(
                color: Colors.grey.shade400,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
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
                borderSide: const BorderSide(color: accentColor, width: 2),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 16,
                vertical: isVerySmallScreen ? 12 : (isSmallScreen ? 14 : 16),
              ),
            ),
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              UpperCaseTextFormatter(),
            ],
            onSubmitted: _isJoining ? null : (value) => _joinOrganizationWithCode(),
          ),

          SizedBox(height: isVerySmallScreen ? 10 : (isSmallScreen ? 12 : 14)),

          Container(
            padding: EdgeInsets.all(isVerySmallScreen ? 8 : (isSmallScreen ? 10 : 12)),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: accentColor.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: accentColor,
                  size: isVerySmallScreen ? 16 : (isSmallScreen ? 18 : 20),
                ),
                SizedBox(width: isVerySmallScreen ? 6 : (isSmallScreen ? 8 : 10)),
                Expanded(
                  child: Text(
                    _tr('join_org_info'),
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: isVerySmallScreen ? 10 : (isSmallScreen ? 11 : 12),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: isVerySmallScreen ? 14 : (isSmallScreen ? 16 : 20)),

          SizedBox(
            width: double.infinity,
            height: buttonHeight,
            child: ElevatedButton(
              onPressed: _isJoining ? null : _joinOrganizationWithCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade400,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(isVerySmallScreen ? 22 : (isSmallScreen ? 24 : 26)),
                ),
                elevation: 0,
              ),
              child: _isJoining
                  ? SizedBox(
                      width: isVerySmallScreen ? 20 : 24,
                      height: isVerySmallScreen ? 20 : 24,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.login, 
                          size: isVerySmallScreen ? 16 : (isSmallScreen ? 18 : 20),
                        ),
                        SizedBox(width: isVerySmallScreen ? 6 : (isSmallScreen ? 8 : 10)),
                        Flexible(
                          child: Text(
                            isVerySmallScreen ? _tr('join_org_button_short') : _tr('join_org_button'),
                            style: TextStyle(
                              fontSize: isVerySmallScreen ? 13 : (isSmallScreen ? 14 : 16),
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// Custom TextInputFormatter untuk memastikan semua input UPPERCASE
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}