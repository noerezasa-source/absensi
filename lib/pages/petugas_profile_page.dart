import 'package:absensimassal/pages/petugas_records_page.dart';
import 'package:absensimassal/widgets/petugas_bottom_nav.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../services/biometric_service.dart';
import '../services/role_service.dart';
import '../services/attendance_service.dart';
import '../models/attendance_record.dart';
import '../helpers/rfid_mode_helper.dart';
import 'face_registration_page.dart';
import 'login.dart';
import 'petugas_dashboard.dart';
import 'petugas_members_page.dart';
import 'petugas_records_page.dart';

class PetugasProfilePage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;

  const PetugasProfilePage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
    this.userProfile,
  });

  @override
  State<PetugasProfilePage> createState() => _PetugasProfilePageState();
}

class _PetugasProfilePageState extends State<PetugasProfilePage> {
  final BiometricService _biometricService = BiometricService();
  final RoleService _roleService = RoleService();
  final AttendanceService _attendanceService = AttendanceService();
  final _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  bool _hasRegisteredFace = false;
  bool _isCheckingFace = true;
  bool _isLoadingProfile = false;
  bool _isLoadingAttendance = false;
  bool _isUploadingPhoto = false;
  bool _isEditMode = false;
  bool _isSaving = false;
  bool _rfidMode = false;
  String _attendanceMode = 'face'; // Default to face
  int _currentNavIndex = 3; // Profile is index 3
  Map<String, dynamic>? _userProfile;
  Map<String, dynamic>? _organization;
  AttendanceRecord? _todayAttendance;
  String? _memberCardNumber;

  // Form controllers
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _displayNameController;
  late TextEditingController _phoneController;
  String _selectedGender = 'male';
  DateTime? _selectedDateOfBirth;

  static const Color primaryColor = Color(0xFF9333EA);

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController();
    _phoneController = TextEditingController();
    _userProfile = widget.userProfile;
    _checkFaceRegistration();
    _loadOrganizationInfo();
    _loadTodayAttendance();
    _loadMemberRfidCard();
    _loadRfidMode(); // Load RFID mode from SharedPreferences
    if (_userProfile == null) {
      _loadUserProfile();
    } else {
      _populateControllers();
    }
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

void _handleNavigation(int index) {
  debugPrint('=== PROFILE PAGE NAVIGATION ===');
  debugPrint('Current index: $_currentNavIndex');
  debugPrint('Target index: $index');
  
  if (index == _currentNavIndex) {
    debugPrint('Same index, returning');
    return;
  }

  setState(() {
    _currentNavIndex = index;
  });

  switch (index) {
    case 0:
      // Home - kembali ke dashboard
      debugPrint('Navigating to Dashboard (popUntil)');
      Navigator.popUntil(context, (route) => route.isFirst);
      break;
      
    case 1:
      // Member
      debugPrint('Navigating to Members page');
      Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => PetugasMembersPage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
          ),
        ),
      ).then((_) {
        debugPrint('Returned from Members page');
        if (mounted) {
          setState(() {
            _currentNavIndex = 3; // Kembali ke Profile index
          });
        }
      });
      break;
      
    case 2:
      // Records - Navigate to Records Page
      debugPrint('Navigating to Records page');
      Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => PetugasRecordsPage(
            organizationMemberId: widget.organizationMemberId,
            memberData: widget.memberData,
            userProfile: _userProfile ?? widget.userProfile,
          ),
        ),
      ).then((_) {
        debugPrint('Returned from Records page');
        if (mounted) {
          setState(() {
            _currentNavIndex = 3; // Kembali ke Profile index
          });
        }
      });
      break;
      
    case 3:
      // Profile - stay on current page
      debugPrint('Already on Profile page');
      break;
  }
}

  void _populateControllers() {
    _displayNameController.text = _userProfile?['display_name'] ?? '';
    _phoneController.text = _userProfile?['phone'] ?? '';
    _selectedGender = _userProfile?['gender'] ?? 'male';
    _selectedDateOfBirth = _userProfile?['date_of_birth'] != null 
        ? DateTime.parse(_userProfile!['date_of_birth']) 
        : null;
  }

  Future<void> _loadUserProfile() async {
    setState(() {
      _isLoadingProfile = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('User not logged in');
      }

      final response = await _supabase
          .from('user_profiles')
          .select()
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _userProfile = response;
          _populateControllers();
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR loading user profile: $e');
      if (mounted) {
        setState(() {
          _isLoadingProfile = false;
        });
      }
    }
  }

  Future<void> _loadOrganizationInfo() async {
    try {
      final response = await _supabase
          .from('organizations')
          .select('id, name, logo_url')
          .eq('id', widget.memberData['organization_id'])
          .single();

      if (mounted) {
        setState(() {
          _organization = response;
        });
      }
    } catch (e) {
      debugPrint('Error loading organization info: $e');
    }
  }

  Future<void> _loadRfidMode() async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      final savedMode = await RfidModeHelper.getRfidMode(organizationId);
      if (mounted) {
        setState(() {
          _rfidMode = savedMode;
          // Set attendance mode based on RFID mode
          _attendanceMode = _rfidMode ? 'rfid' : 'face';
        });
        debugPrint('RFID mode loaded: $_rfidMode for org $organizationId');
        debugPrint('Attendance mode set to: $_attendanceMode');
      }
    } catch (e) {
      debugPrint('Error loading RFID mode: $e');
    }
  }

  Future<void> _saveRfidMode(bool enabled) async {
    final organizationId = widget.memberData['organization_id'] as int?;
    if (organizationId == null) return;

    try {
      await RfidModeHelper.saveRfidMode(organizationId, enabled);
      debugPrint('RFID mode saved: $enabled for org $organizationId');
    } catch (e) {
      debugPrint('Error saving RFID mode: $e');
    }
  }

  Future<void> _loadTodayAttendance() async {
    setState(() {
      _isLoadingAttendance = true;
    });

    try {
      final record =
          await _attendanceService.getTodayAttendance(widget.organizationMemberId);
      if (mounted) {
        setState(() {
          _todayAttendance = record;
          _isLoadingAttendance = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading today attendance: $e');
      if (mounted) {
        setState(() {
          _isLoadingAttendance = false;
        });
      }
    }
  }

  Future<void> _loadMemberRfidCard() async {
    try {
      final card = await _supabase
          .from('rfid_cards')
          .select()
          .eq('organization_member_id', widget.organizationMemberId)
          .eq('is_active', true)
          .maybeSingle();

      if (mounted && card != null) {
        setState(() {
          _memberCardNumber = card['card_number'] as String?;
        });
      }
    } catch (e) {
      debugPrint('Error loading RFID card: $e');
    }
  }

  Future<void> _checkFaceRegistration() async {
    setState(() {
      _isCheckingFace = true;
    });
    
    try {
      final hasRegistered = await _biometricService.hasRegisteredFace(
        widget.organizationMemberId,
      );
      
      if (mounted) {
        setState(() {
          _hasRegisteredFace = hasRegistered;
          _isCheckingFace = false;
        });
      }
    } catch (e) {
      debugPrint('!!! ERROR checking face registration: $e');
      if (mounted) {
        setState(() {
          _hasRegisteredFace = false;
          _isCheckingFace = false;
        });
      }
    }
  }

  Future<void> _navigateToFaceRegistration() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FaceRegistrationPage(
          organizationMemberId: widget.organizationMemberId,
        ),
      ),
    );

    if (result == true) {
      _checkFaceRegistration();
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (image == null) return;

      setState(() {
        _isUploadingPhoto = true;
      });

      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '$userId-$timestamp.jpg';
      final filePath = 'mass-profile/$fileName';

      final file = File(image.path);
      await _supabase.storage
          .from('profile-photos')
          .upload(filePath, file);

      await _supabase
          .from('user_profiles')
          .update({'profile_photo_url': fileName})
          .eq('id', userId);

      await _loadUserProfile();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile photo updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('!!! ERROR uploading photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to upload photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
        });
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) throw Exception('User not logged in');

      // Split display name menjadi first_name dan last_name
      final displayName = _displayNameController.text.trim();
      final nameParts = displayName.split(' ').where((n) => n.isNotEmpty).toList();
      
      String firstName;
      String lastName;
      
      if (nameParts.isEmpty) {
        firstName = 'User';
        lastName = '';
      } else if (nameParts.length == 1) {
        firstName = nameParts[0];
        lastName = '';
      } else {
        firstName = nameParts[0];
        lastName = nameParts.sublist(1).join(' ');
      }

      await _supabase
          .from('user_profiles')
          .update({
            'first_name': firstName,
            'last_name': lastName,
            'display_name': displayName,
            'phone': _phoneController.text.trim().isEmpty 
                ? null 
                : _phoneController.text.trim(),
            'gender': _selectedGender,
            'date_of_birth': _selectedDateOfBirth?.toIso8601String().split('T')[0],
          })
          .eq('id', userId);

      await _loadUserProfile();

      if (mounted) {
        setState(() {
          _isEditMode = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('!!! ERROR saving profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update profile: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _toggleEditMode() {
    setState(() {
      _isEditMode = !_isEditMode;
      if (!_isEditMode) {
        _populateControllers();
      }
    });
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDateOfBirth ?? 
          DateTime.now().subtract(const Duration(days: 365 * 25)),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: primaryColor,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );
    
    if (picked != null) {
      setState(() {
        _selectedDateOfBirth = picked;
      });
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _supabase.auth.signOut();
        
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const ModernLoginScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Logout failed: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  String _getFullName() {
    if (_userProfile == null) return 'Loading...';
    final firstName = _userProfile!['first_name'] ?? '';
    final middleName = _userProfile!['middle_name'] ?? '';
    final lastName = _userProfile!['last_name'] ?? '';
    
    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }
    return '$firstName $lastName'.trim();
  }

  String? _getProfilePhotoUrl() {
    if (_userProfile == null || _userProfile!['profile_photo_url'] == null) {
      return null;
    }
    
    final photoPath = _userProfile!['profile_photo_url'] as String;
    
    if (photoPath.trim().isEmpty) {
      return null;
    }
    
    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return photoPath;
    }
    
    return _supabase.storage
        .from('profile-photos')
        .getPublicUrl('mass-profile/$photoPath');
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'Not set';
    try {
      final date = DateTime.parse(dateStr);
      final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${date.day} ${months[date.month - 1]} ${date.year}';
    } catch (e) {
      return 'Invalid date';
    }
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _rfidMode);
        return false;
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: _isLoadingProfile
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                children: [
                  // ---------- HEADER ----------
                  Container(
                    width: double.infinity,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(30),
                        bottomRight: Radius.circular(30),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(0, 60, 0, 30),
                    child: Column(
                      children: [
                        // Profile Photo with Badge
                        Stack(
                          children: [
                            Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 4,
                                ),
                                color: Colors.grey.shade100,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.2),
                                    blurRadius: 15,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: ClipOval(
                                child: _isUploadingPhoto
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 3,
                                        ),
                                      )
                                    : _getProfilePhotoUrl() != null
                                        ? Image.network(
                                            _getProfilePhotoUrl()!,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) {
                                              return Icon(
                                                Icons.person,
                                                size: 60,
                                                color: Colors.grey.shade400,
                                              );
                                            },
                                          )
                                        : Icon(
                                            Icons.person,
                                            size: 60,
                                            color: Colors.grey.shade400,
                                          ),
                              ),
                            ),
                            // Petugas Badge
                            Positioned(
                              top: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: primaryColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.2),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.badge,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                            // Camera Button
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: GestureDetector(
                                onTap: _isUploadingPhoto ? null : _pickAndUploadPhoto,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.2),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt,
                                    color: primaryColor,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _getFullName(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Petugas Badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.4),
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.badge,
                                color: Colors.white,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _roleService.getRoleName(widget.memberData),
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _supabase.auth.currentUser?.email ?? 'No email',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                        if (_organization != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.business,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _organization!['name'] ?? 'Unknown Organization',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ---------- CONTENT ----------
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      children: [
                        _buildSectionCard(
                          title: 'Personal Information',
                          icon: Icons.person_outline,
                          needsForm: true,
                          children: [
                            if (_isEditMode) ...[
                              // Save & Cancel Buttons
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: _isSaving ? null : _toggleEditMode,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.grey[600],
                                          side: BorderSide(color: Colors.grey[300]!),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                        ),
                                        child: const Text('Cancel'),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _isSaving ? null : _saveProfile,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: primaryColor,
                                          foregroundColor: Colors.white,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          elevation: 0,
                                        ),
                                        child: _isSaving
                                            ? const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                                ),
                                              )
                                            : const Text('Save'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Editable Fields
                              _buildEditableField(
                                label: 'Display Name',
                                controller: _displayNameController,
                                validator: (value) {
                                  if (value == null || value.trim().isEmpty) {
                                    return 'Display name is required';
                                  }
                                  return null;
                                },
                              ),
                              _buildEditableField(
                                label: 'Phone Number',
                                controller: _phoneController,
                                keyboardType: TextInputType.phone,
                              ),
                              _buildGenderField(),
                              _buildDateOfBirthField(),
                            ] else ...[
                              // View Mode with Edit Button
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _toggleEditMode,
                                      icon: const Icon(Icons.edit, size: 16),
                                      label: const Text('Edit'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: primaryColor,
                                        side: const BorderSide(color: primaryColor),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _buildInfoRow('Display Name', _userProfile?['display_name'] ?? 'Not set'),
                              _buildInfoRow('Phone Number', _userProfile?['phone'] ?? 'Not set'),
                              _buildInfoRow('Gender', _userProfile?['gender'] != null 
                                  ? '${_userProfile!['gender'].toString()[0].toUpperCase()}${_userProfile!['gender'].toString().substring(1)}'
                                  : 'Not set'),
                              _buildInfoRow('Date of Birth', _formatDate(_userProfile?['date_of_birth'])),
                            ],
                            const Divider(height: 24),
                            _buildInfoRow('Employee Code', _userProfile?['employee_code'] ?? 'Not set'),
                            _buildInfoRow('Position', widget.memberData['position']?['title'] ?? 'Not specified'),
                            _buildInfoRow('Department', widget.memberData['department']?['name'] ?? 'Not specified'),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // Face Registration Card
                        _buildSectionCard(
                          title: 'Face Recognition',
                          icon: Icons.face,
                          children: [
                            if (_isCheckingFace)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(20.0),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else
                              Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: _hasRegisteredFace
                                          ? Colors.green.shade50
                                          : Colors.orange.shade50,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: _hasRegisteredFace
                                            ? Colors.green.shade200
                                            : Colors.orange.shade200,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _hasRegisteredFace
                                              ? Icons.check_circle
                                              : Icons.warning_amber_rounded,
                                          color: _hasRegisteredFace
                                              ? Colors.green.shade700
                                              : Colors.orange.shade700,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            _hasRegisteredFace
                                                ? 'Face registered successfully'
                                                : 'Face not registered yet',
                                            style: TextStyle(
                                              color: _hasRegisteredFace
                                                  ? Colors.green.shade900
                                                  : Colors.orange.shade900,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 50,
                                    child: ElevatedButton.icon(
                                      onPressed: _navigateToFaceRegistration,
                                      icon: Icon(_hasRegisteredFace ? Icons.refresh : Icons.face),
                                      label: Text(
                                        _hasRegisteredFace ? 'Re-register Face' : 'Register Face',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: primaryColor,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),

                        const SizedBox(height: 16),

                        // Attendance Mode Selection
                        _buildSectionCard(
                          title: 'Attendance Mode',
                          icon: Icons.fingerprint,
                          children: [
                            DropdownButtonFormField<String>(
                              value: _attendanceMode,
                              decoration: const InputDecoration(
                                labelText: 'Select Mode',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'face', child: Text('Face Recognition')),
                                DropdownMenuItem(value: 'rfid', child: Text('RFID Card')),
                                DropdownMenuItem(value: 'finger', enabled: false, child: Text('Fingerprint (Soon)')),
                              ],
                              onChanged: (value) {
                                if (value != null && value != 'finger') {
                                  setState(() {
                                    _attendanceMode = value;
                                    _rfidMode = value == 'rfid';
                                  });
                                  _saveRfidMode(_rfidMode);
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                            if (_attendanceMode == 'rfid' && _memberCardNumber != null)
                              Text(
                                'Card: $_memberCardNumber',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.green,
                                ),
                              ),
                            const SizedBox(height: 12),
                            if (_isLoadingAttendance)
                              const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(12.0),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            else if (_todayAttendance != null)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "Today's Attendance",
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _buildInfoRow(
                                    'Check In',
                                    _formatTime(_todayAttendance!.actualCheckIn),
                                  ),
                                  _buildInfoRow(
                                    'Check Out',
                                    _formatTime(_todayAttendance!.actualCheckOut),
                                  ),
                                ],
                              ),
                          ],
                        ),

                        // Account Settings Card
                        _buildSectionCard(
                          title: 'Account Settings',
                          icon: Icons.settings,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.logout,
                                  color: Colors.red.shade700,
                                ),
                              ),
                              title: const Text(
                                'Logout',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                              subtitle: const Text('Sign out from your account'),
                              trailing: Icon(
                                Icons.chevron_right,
                                color: Colors.grey.shade400,
                              ),
                              onTap: _handleLogout,
                            ),
                          ],
                        ),

                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      // ---------- BOTTOM NAVIGATION ----------
      bottomNavigationBar: PetugasBottomNav(
        currentIndex: _currentNavIndex,
        onNavigationTap: _handleNavigation,
        // onAttendanceTap: tidak diberikan, jadi tombol attendance tidak muncul
      ),
    ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
    bool needsForm = false,
  }) {
    final cardContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: primaryColor),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: needsForm 
          ? Form(key: _formKey, child: cardContent)
          : cardContent,
    );
  }

  Widget _buildEditableField({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            keyboardType: keyboardType,
            validator: validator,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenderField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Gender',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('Male'),
                  value: 'male',
                  groupValue: _selectedGender,
                  activeColor: primaryColor,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _selectedGender = v!),
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('Female'),
                  value: 'female',
                  groupValue: _selectedGender,
                  activeColor: primaryColor,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _selectedGender = v!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDateOfBirthField() {
    final dateDisplay = _selectedDateOfBirth != null
        ? '${_selectedDateOfBirth!.day.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.month.toString().padLeft(2, '0')}/${_selectedDateOfBirth!.year}'
        : 'Select date';
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Date of Birth',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _selectDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey.shade50,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dateDisplay,
                    style: TextStyle(
                      fontSize: 16,
                      color: _selectedDateOfBirth != null 
                          ? Colors.black87 
                          : Colors.grey.shade600,
                    ),
                  ),
                  Icon(
                    Icons.calendar_today,
                    size: 20,
                    color: Colors.grey.shade600,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}