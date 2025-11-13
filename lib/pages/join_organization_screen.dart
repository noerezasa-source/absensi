import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'login.dart';
// import 'main_dashboard.dart'; // TODO: Uncomment setelah buat file dashboard

class JoinOrganizationScreen extends StatefulWidget {
  const JoinOrganizationScreen({super.key});

  @override
  State<JoinOrganizationScreen> createState() => _JoinOrganizationScreenState();
}

class _JoinOrganizationScreenState extends State<JoinOrganizationScreen> {
  static const Color primaryColor = Color(0xFF6366F1);
  static const Color secondaryColor = Color(0xFF8B5CF6);

  final TextEditingController _invCodeController = TextEditingController();

  bool _isJoining = false;
  bool _isInitializing = true;
  
  String? _displayName;
  String? _profilePhotoUrl;

  @override
  void initState() {
    super.initState();
    _initializeScreen();
  }

  @override
  void dispose() {
    _invCodeController.dispose();
    super.dispose();
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
      final existingOrgMember = await Supabase.instance.client
          .from('organization_members')
          .select('id, organization_id, organizations(name)')
          .eq('user_id', user.id)
          .eq('is_active', true)
          .maybeSingle();

      if (existingOrgMember != null && mounted) {
        // User already has organization - redirect
        final orgName = existingOrgMember['organizations']?['name'] ?? 'an organization';
        
        debugPrint('✓ User already has organization: $orgName');
        
        _showSnackBar('Anda sudah tergabung di $orgName', true);

        await Future.delayed(const Duration(milliseconds: 800));

        if (!mounted) return;

        // TODO: Uncomment setelah buat MainDashboard
        // Navigator.of(context).pushReplacement(
        //   MaterialPageRoute(builder: (context) => const MainDashboard()),
        // );
        
        debugPrint('Should navigate to MainDashboard');
      } else {
        // User doesn't have organization - show join form
        if (mounted) {
          setState(() => _isInitializing = false);
        }
      }
    } catch (e) {
      debugPrint('❌ Error initializing screen: $e');
      // Show form even on error
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  Future<void> _joinOrganizationWithCode() async {
    final invCode = _invCodeController.text.trim();

    if (invCode.isEmpty) {
      _showSnackBar('Silakan masukkan kode undangan', false);
      return;
    }

    setState(() => _isJoining = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        throw Exception('User tidak terautentikasi');
      }

      // STEP 1: Check if already member (double-check)
      debugPrint('Step 1: Checking existing organization membership...');
      final existingOrgMember = await Supabase.instance.client
          .from('organization_members')
          .select('id, organization_id, organizations(name)')
          .eq('user_id', user.id)
          .eq('is_active', true)
          .maybeSingle();

      if (existingOrgMember != null) {
        // User already has organization - redirect
        debugPrint('✓ User already has organization - redirecting');

        final orgName = existingOrgMember['organizations']?['name'] ?? 'an organization';

        if (mounted) {
          _showSnackBar('Anda sudah tergabung di $orgName', true);

          await Future.delayed(const Duration(milliseconds: 500));

          if (!mounted) return;

          // TODO: Uncomment setelah buat MainDashboard
          // Navigator.of(context).pushAndRemoveUntil(
          //   MaterialPageRoute(builder: (context) => const MainDashboard()),
          //   (route) => false,
          // );
          
          debugPrint('Should navigate to MainDashboard');
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

      if (existingMemberInOrg != null) {
        if (existingMemberInOrg['is_active'] == true) {
          // Already active member
          debugPrint('⚠️ User is already an active member of this organization');
          throw Exception('Anda sudah tergabung di organisasi ini');
        } else {
          // Re-activate if exists but is_active = false
          debugPrint('Step 3b: Reactivating existing membership...');
          await Supabase.instance.client
              .from('organization_members')
              .update({
                'is_active': true,
                'work_location': 'field',
                'updated_at': DateTime.now().toIso8601String(),
              })
              .eq('id', existingMemberInOrg['id']);

          debugPrint('✓ Re-activated existing membership with work_location: field');
        }
      } else {
        // STEP 4: Insert new member
        debugPrint('Step 4: Creating new organization membership...');
        await Supabase.instance.client.from('organization_members').insert({
          'organization_id': orgId,
          'user_id': user.id,
          'hire_date': DateTime.now().toIso8601String().split('T')[0],
          'employment_status': 'active',
          'work_location': 'field',
          'is_active': true,
        });

        debugPrint('✓ Created new organization membership with work_location: field');
      }

      // STEP 5: Success - navigate to dashboard
      if (mounted) {
        _showSnackBar('Berhasil bergabung dengan $orgName!', true);

        await Future.delayed(const Duration(milliseconds: 800));

        if (!mounted) return;

        debugPrint('Navigating to MainDashboard...');
        
        // TODO: Uncomment setelah buat MainDashboard
        // Navigator.of(context).pushAndRemoveUntil(
        //   MaterialPageRoute(builder: (context) => const MainDashboard()),
        //   (route) => false,
        // );
        
        _showSnackBar('Success! (MainDashboard belum dibuat)', true);
      }
    } catch (e) {
      debugPrint('❌ Error joining organization: $e');
      if (mounted) {
        String errorMessage = 'Gagal bergabung dengan organisasi';

        if (e.toString().contains('tidak valid') || 
            e.toString().contains('not valid')) {
          errorMessage = 'Kode undangan tidak valid';
        } else if (e.toString().contains('sudah tergabung') ||
                   e.toString().contains('already')) {
          errorMessage = 'Anda sudah tergabung di organisasi ini';
        } else if (e.toString().contains('terautentikasi') ||
                   e.toString().contains('authenticated')) {
          errorMessage = 'User tidak terautentikasi';
        }

        _showSnackBar(errorMessage, false);
      }
    } finally {
      if (mounted) {
        setState(() => _isJoining = false);
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Konfirmasi Logout'),
        content: const Text('Apakah Anda yakin ingin keluar?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Batal',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Logout',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
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
          _showSnackBar('Gagal logout', false);
        }
      }
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _displayName ?? 'User';
    final screenWidth = MediaQuery.of(context).size.width;

    // Responsive sizing
    final bool isSmallPhone = screenWidth < 360;
    final bool isMobile = screenWidth < 600;
    final bool isTablet = screenWidth >= 600 && screenWidth < 1024;

    final double horizontalPadding = isSmallPhone ? 16 : (isMobile ? 20 : (isTablet ? 40 : 60));
    final double verticalPadding = isSmallPhone ? 12 : 20;
    final double logoSize = isSmallPhone ? 50 : (isMobile ? 60 : 70);
    final double avatarRadius = isSmallPhone ? 32 : (isMobile ? 40 : 48);
    final double titleFontSize = isSmallPhone ? 18 : (isMobile ? 22 : 26);
    final double subtitleFontSize = isSmallPhone ? 12 : (isMobile ? 14 : 15);
    final double cardPadding = isSmallPhone ? 20 : (isMobile ? 24 : 32);
    final double maxCardWidth = isTablet ? 600 : 500;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: _isInitializing
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                      strokeWidth: 3,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Memuat...',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            : Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      primaryColor.withOpacity(0.08),
                      secondaryColor.withOpacity(0.04),
                    ],
                  ),
                ),
                child: Center(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalPadding,
                        vertical: verticalPadding,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Logout button
                          Align(
                            alignment: Alignment.topRight,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: _isJoining
                                      ? [Colors.grey.shade300, Colors.grey.shade400]
                                      : [Colors.red.shade400, Colors.red.shade600],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: _isJoining
                                        ? Colors.grey.withOpacity(0.2)
                                        : Colors.red.withOpacity(0.3),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
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
                                      horizontal: isSmallPhone ? 12 : 16,
                                      vertical: isSmallPhone ? 8 : 10,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.logout_rounded,
                                          color: Colors.white,
                                          size: isSmallPhone ? 18 : 20,
                                        ),
                                        SizedBox(width: isSmallPhone ? 6 : 8),
                                        Text(
                                          'Logout',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: isSmallPhone ? 13 : 14,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.3,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Logo
                          Container(
                            width: logoSize,
                            height: logoSize,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [primaryColor, secondaryColor],
                              ),
                              borderRadius: BorderRadius.circular(logoSize * 0.3),
                              boxShadow: [
                                BoxShadow(
                                  color: primaryColor.withOpacity(0.3),
                                  blurRadius: 15,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.business,
                              color: Colors.white,
                              size: logoSize * 0.53,
                            ),
                          ),

                          SizedBox(height: isSmallPhone ? 16 : 24),

                          // Main Card
                          Container(
                            constraints: BoxConstraints(maxWidth: maxCardWidth),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(isSmallPhone ? 20 : 24),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.08),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            padding: EdgeInsets.all(cardPadding),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Avatar
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        primaryColor.withOpacity(0.2),
                                        secondaryColor.withOpacity(0.1),
                                      ],
                                    ),
                                  ),
                                  child: CircleAvatar(
                                    radius: avatarRadius,
                                    backgroundColor: Colors.transparent,
                                    backgroundImage: _profilePhotoUrl != null
                                        ? NetworkImage(_profilePhotoUrl!)
                                        : null,
                                    child: _profilePhotoUrl == null
                                        ? Icon(
                                            Icons.person,
                                            color: primaryColor,
                                            size: avatarRadius * 1,
                                          )
                                        : null,
                                  ),
                                ),

                                SizedBox(height: isSmallPhone ? 12 : 16),

                                // Welcome text
                                Text(
                                  'Selamat Datang Kembali, $displayName!',
                                  style: TextStyle(
                                    fontSize: titleFontSize,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.black87,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),

                                const SizedBox(height: 8),

                                Text(
                                  'Bergabung dengan organisasi untuk melanjutkan',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: subtitleFontSize,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),

                                SizedBox(height: isSmallPhone ? 20 : 24),

                                // Invitation code field
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Kode Undangan',
                                      style: TextStyle(
                                        fontSize: isSmallPhone ? 13 : 14,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black87,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    TextField(
                                      controller: _invCodeController,
                                      enabled: !_isJoining,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: isSmallPhone ? 18 : 20,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: isSmallPhone ? 2 : 4,
                                        color: Colors.black87,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: 'ENTER-CODE',
                                        hintStyle: TextStyle(
                                          color: Colors.grey.shade400,
                                          letterSpacing: isSmallPhone ? 2 : 4,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        filled: true,
                                        fillColor: Colors.grey.shade50,
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: BorderSide.none,
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: BorderSide(
                                            color: Colors.grey.shade200,
                                            width: 2,
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: const BorderSide(
                                            color: primaryColor,
                                            width: 2.5,
                                          ),
                                        ),
                                        disabledBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: BorderSide(
                                            color: Colors.grey.shade200,
                                            width: 2,
                                          ),
                                        ),
                                        contentPadding: EdgeInsets.symmetric(
                                          vertical: isSmallPhone ? 14 : 16,
                                          horizontal: isSmallPhone ? 16 : 20,
                                        ),
                                      ),
                                      textCapitalization: TextCapitalization.characters,
                                      onSubmitted: _isJoining
                                          ? null
                                          : (value) => _joinOrganizationWithCode(),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 16),

                                // Info box
                                Container(
                                  padding: EdgeInsets.all(isSmallPhone ? 10 : 12),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Colors.blue.shade200,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.info_rounded,
                                        color: Colors.blue.shade700,
                                        size: isSmallPhone ? 18 : 20,
                                      ),
                                      SizedBox(width: isSmallPhone ? 8 : 10),
                                      Expanded(
                                        child: Text(
                                          'Tanyakan kode undangan ke HR atau admin organisasi Anda',
                                          style: TextStyle(
                                            color: Colors.blue.shade900,
                                            fontSize: isSmallPhone ? 11 : 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                SizedBox(height: isSmallPhone ? 20 : 24),

                                // Join button
                                SizedBox(
                                  width: double.infinity,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [primaryColor, secondaryColor],
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      boxShadow: [
                                        BoxShadow(
                                          color: primaryColor.withOpacity(0.4),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: ElevatedButton(
                                      onPressed: _isJoining
                                          ? null
                                          : _joinOrganizationWithCode,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        disabledBackgroundColor: Colors.grey.shade300,
                                        disabledForegroundColor: Colors.grey.shade600,
                                        padding: EdgeInsets.symmetric(
                                          vertical: isSmallPhone ? 14 : 16,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14),
                                        ),
                                        elevation: 0,
                                        shadowColor: Colors.transparent,
                                      ),
                                      child: _isJoining
                                          ? SizedBox(
                                              width: isSmallPhone ? 20 : 24,
                                              height: isSmallPhone ? 20 : 24,
                                              child: const CircularProgressIndicator(
                                                strokeWidth: 3,
                                                valueColor: AlwaysStoppedAnimation<Color>(
                                                  Colors.white,
                                                ),
                                              ),
                                            )
                                          : Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  Icons.business_center,
                                                  size: isSmallPhone ? 18 : 20,
                                                  color: Colors.white,
                                                ),
                                                SizedBox(width: isSmallPhone ? 8 : 10),
                                                Text(
                                                  'Bergabung dengan Organisasi',
                                                  style: TextStyle(
                                                    fontSize: isSmallPhone ? 14 : 16,
                                                    fontWeight: FontWeight.w700,
                                                    letterSpacing: 0.5,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ],
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}