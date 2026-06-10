import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';

class JoinDepartmentScreen extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;

  const JoinDepartmentScreen({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
  });

  @override
  State<JoinDepartmentScreen> createState() => _JoinDepartmentScreenState();
}

class _JoinDepartmentScreenState extends State<JoinDepartmentScreen> {
  static const Color backgroundColor = Color(0xFF050011);
  static const Color cardColor = Colors.white;
  static const Color primaryPurple = Color(0xFF9747FF);
  static const Color textBlack = Color(0xFF1A1A1A);
  static const Color textGrey = Color(0xFF888888);
  static const Color inputFill = Color(0xFFF5F5F5);

  final TextEditingController _deptCodeController = TextEditingController();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isJoining = false;
  String _currentLanguage = LanguageHelper.indonesian;

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  @override
  void dispose() {
    _deptCodeController.dispose();
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

  Future<void> _joinDepartment() async {
    final code = _deptCodeController.text.trim().toUpperCase();

    if (code.isEmpty) {
      _showSnackBar('Silakan masukkan kode departemen', false);
      return;
    }

    setState(() => _isJoining = true);

    try {
      final orgId = widget.memberData['organization_id'] as int?;
      if (orgId == null) throw Exception('Data organisasi tidak ditemukan');

      // Cari departemen berdasarkan kode
      final dept = await _supabase
          .from('departments')
          .select('id, name, code')
          .eq('organization_id', orgId)
          .ilike('code', code)
          .eq('is_active', true)
          .maybeSingle();

      if (dept == null) {
        throw Exception('Kode departemen tidak valid untuk organisasi ini.');
      }

      // Update departemen anggota
      await _supabase
          .from('organization_members')
          .update({
            'department_id': dept['id'],
            'department': dept['name'],
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', widget.organizationMemberId);

      // Perbarui map secara lokal agar langsung terefleksikan di UI
      widget.memberData['department_id'] = dept['id'];
      widget.memberData['department'] = dept['name'];

      if (mounted) {
        _showSuccessDialog(dept['name']);
      }
    } catch (e) {
      debugPrint('Error joining department: $e');
      if (mounted) {
        String errorMessage = 'Gagal bergabung: $e';
        if (e.toString().contains('tidak valid')) {
          errorMessage = 'Kode departemen tidak ditemukan atau tidak valid.';
        }
        _showSnackBar(errorMessage, false);
      }
    } finally {
      if (mounted) setState(() => _isJoining = false);
    }
  }

  void _showSuccessDialog(String deptName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop(); // Tutup dialog
            Navigator.of(context).pop(true); // Kembali ke dashboard, bawa result true
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
                const Icon(
                  Icons.check_circle,
                  size: 60,
                  color: Color(0xFF10B981),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Berhasil!',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Anda berhasil bergabung dengan departemen $deptName.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? const Color(0xFF10B981) : Colors.red,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Color(0xFFF3E5F5)],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.black87,
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Gabung Departemen',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 40),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        vertical: 40,
                        horizontal: 24,
                      ),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(32),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 20,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: primaryPurple.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.domain_add_rounded,
                              size: 48,
                              color: primaryPurple,
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'Masukkan Kode Departemen',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textBlack,
                              letterSpacing: -0.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Dapatkan kode departemen dari admin atau ketua tim Anda.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: textGrey,
                                height: 1.5,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                bottom: 8,
                              ),
                              child: Text(
                                'KODE DEPARTEMEN',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: textBlack.withOpacity(0.7),
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: inputFill,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: TextField(
                              controller: _deptCodeController,
                              textAlign: TextAlign.center,
                              textCapitalization: TextCapitalization.characters,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: textBlack,
                                letterSpacing: 2.0,
                              ),
                              decoration: InputDecoration(
                                hintText: 'KODE-DEPT',
                                hintStyle: TextStyle(
                                  color: Colors.grey.shade400,
                                  letterSpacing: 2.0,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF9747FF),
                                    Color(0xFF6200EE),
                                  ],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF6200EE,
                                    ).withOpacity(0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: _isJoining ? null : _joinDepartment,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: _isJoining
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            'Gabung Sekarang',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                          SizedBox(width: 8),
                                          Icon(
                                            Icons.arrow_forward_rounded,
                                            color: Colors.white,
                                            size: 20,
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
