import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../helpers/language_helper.dart';

class DepartmentManagementPage extends StatefulWidget {
  final int organizationId;
  final Map<String, dynamic> memberData;
  final Map<String, dynamic>? userProfile;
  final bool isDarkMode;

  const DepartmentManagementPage({
    super.key,
    required this.organizationId,
    required this.memberData,
    this.userProfile,
    this.isDarkMode = false,
  });

  @override
  State<DepartmentManagementPage> createState() =>
      _DepartmentManagementPageState();
}

class _DepartmentManagementPageState extends State<DepartmentManagementPage>
    with TickerProviderStateMixin {
  static const Color primaryColor = Color(0xFF4A1E79);
  static const Color primaryDark = Color(0xFF3B1860);
  static const Color successColor = Color(0xFF10B981);
  static const Color warningColor = Color(0xFFF59E0B);
  static const Color errorColor = Color(0xFFEF4444);
  static const Color backgroundColor = Color(0xFFF8F9FA);
  static const Color cardColor = Color(0xFFFFFFFF);

  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _departmentNameController =
      TextEditingController();
  final TextEditingController _departmentCodeController =
      TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _filteredDepartments = [];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  final Map<int, AnimationController> _cardAnimationControllers = {};

  @override
  void initState() {
    super.initState();
    _loadDepartments();
    _searchController.addListener(_filterDepartments);

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );

    _animationController.forward();
  }

  @override
  void dispose() {
    _departmentNameController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _animationController.dispose();

    for (var controller in _cardAnimationControllers.values) {
      controller.dispose();
    }
    _cardAnimationControllers.clear();

    super.dispose();
  }

  void _filterDepartments() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredDepartments = _departments.where((dept) {
        final name = dept['name'] as String? ?? '';
        return name.toLowerCase().contains(query);
      }).toList();
    });
  }

  Future<void> _loadDepartments() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _supabase
          .from('departments')
          .select('id, name, code, organization_id, created_at')
          .eq('organization_id', widget.organizationId)
          .order('name', ascending: true);

      if (mounted) {
        setState(() {
          _departments = List<Map<String, dynamic>>.from(response);
          _filteredDepartments = List.from(_departments);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading departments: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _addDepartment() async {
    final name = _departmentNameController.text.trim();
    final code = _departmentCodeController.text.trim();
    if (name.isEmpty) {
      _showSnackBar(
        AppLanguage.tr('Petugas.members.department.enter_name'),
        false,
      );
      return;
    }
    if (code.isEmpty) {
      _showSnackBar('Please enter department code', false);
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _supabase.from('departments').insert({
        'name': name,
        'code': code,
        'organization_id': widget.organizationId,
      });

      _departmentNameController.clear();
      _departmentCodeController.clear();
      if (mounted) Navigator.pop(context);
      await _loadDepartments();
      if (mounted) {
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.added_success'),
          true,
        );
      }
    } catch (e) {
      debugPrint('Error adding department: $e');
      _showSnackBar(
        AppLanguage.tr('Petugas.members.department.added_failed'),
        false,
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _editDepartment(Map<String, dynamic> department) async {
    _departmentNameController.text = department['name'] as String;
    _departmentCodeController.text = department['code'] as String? ?? '';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          AppLanguage.tr('Petugas.members.department.edit'),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: primaryColor,
            fontSize: 22,
            letterSpacing: -0.5,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _departmentCodeController,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
              decoration: InputDecoration(
                labelText: 'Department Code',
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.code,
                  color: primaryColor,
                  size: 22,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: primaryColor, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _departmentNameController,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
              decoration: InputDecoration(
                labelText: AppLanguage.tr('Petugas.members.department.name'),
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.business,
                  color: primaryColor,
                  size: 22,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: primaryColor, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              AppLanguage.tr('Petugas.members.department.cancel'),
              style: TextStyle(
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
                fontSize: 15,
                letterSpacing: 0.2,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 2,
            ),
            child: Text(
              AppLanguage.tr('Petugas.members.department.save'),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      final name = _departmentNameController.text.trim();
      final code = _departmentCodeController.text.trim();
      if (name.isEmpty) {
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.enter_name'),
          false,
        );
        return;
      }
      if (code.isEmpty) {
        _showSnackBar('Please enter department code', false);
        return;
      }

      setState(() => _isSaving = true);

      try {
        await _supabase
            .from('departments')
            .update({'name': name, 'code': code})
            .eq('id', department['id']);

        _departmentNameController.clear();
        _departmentCodeController.clear();
        await _loadDepartments();
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.updated_success'),
          true,
        );
      } catch (e) {
        debugPrint('Error updating department: $e');
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.updated_failed'),
          false,
        );
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
    }

    _departmentNameController.clear();
  }

  Future<void> _deleteDepartment(Map<String, dynamic> department) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: errorColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.warning, color: errorColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLanguage.tr('Petugas.members.department.delete_confirm'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: errorColor,
                  fontSize: 18,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          AppLanguage.tr('Petugas.members.department.delete_warning'),
          style: TextStyle(
            color: Colors.grey.shade700,
            fontSize: 15,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              AppLanguage.tr('Petugas.members.department.cancel'),
              style: TextStyle(
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
                fontSize: 15,
                letterSpacing: 0.2,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: errorColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 2,
            ),
            child: Text(
              AppLanguage.tr('Petugas.members.department.delete'),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        await _supabase.from('departments').delete().eq('id', department['id']);

        await _loadDepartments();
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.deleted_success'),
          true,
        );
      } catch (e) {
        debugPrint('Error deleting department: $e');
        _showSnackBar(
          AppLanguage.tr('Petugas.members.department.deleted_failed'),
          false,
        );
      }
    }
  }

  void _showAddDialog() {
    _departmentNameController.clear();
    _departmentCodeController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          AppLanguage.tr('Petugas.members.department.add'),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: primaryColor,
            fontSize: 22,
            letterSpacing: -0.5,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _departmentCodeController,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
              decoration: InputDecoration(
                labelText: 'Department Code',
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.code,
                  color: primaryColor,
                  size: 22,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: primaryColor, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _departmentNameController,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
              decoration: InputDecoration(
                labelText: AppLanguage.tr('Petugas.members.department.name'),
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                prefixIcon: const Icon(
                  Icons.business,
                  color: primaryColor,
                  size: 22,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: primaryColor, width: 2),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              AppLanguage.tr('Petugas.members.department.cancel'),
              style: TextStyle(
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
                fontSize: 15,
                letterSpacing: 0.2,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: _isSaving ? null : _addDepartment,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 2,
            ),
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    AppLanguage.tr('Petugas.members.department.save'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      letterSpacing: 0.3,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, bool isSuccess) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle : Icons.error,
              color: Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: isSuccess ? successColor : errorColor,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
        animation: CurvedAnimation(
          parent: const AlwaysStoppedAnimation(1.0),
          curve: Curves.easeInOut,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.isDarkMode
          ? const Color(0xFF1F0B38)
          : backgroundColor,
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                expandedHeight: 180,
                floating: false,
                pinned: true,
                backgroundColor: primaryColor,
                elevation: 0,
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(
                    AppLanguage.tr('Petugas.members.department.title'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      fontSize: 26,
                      letterSpacing: -0.5,
                      height: 1.2,
                    ),
                  ),
                  titlePadding: const EdgeInsets.only(left: 20, bottom: 20),
                  background: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: widget.isDarkMode
                            ? [primaryDark, const Color(0xFF1F0B38)]
                            : [
                                const Color(0xFF9D4EDD),
                                primaryColor,
                                primaryDark,
                              ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          right: -60,
                          top: -60,
                          child: Container(
                            width: 250,
                            height: 250,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 30,
                          bottom: 30,
                          child: Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                          ),
                        ),
                        Positioned(
                          left: -40,
                          bottom: -20,
                          child: Container(
                            width: 150,
                            height: 150,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.06),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Stats Card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: widget.isDarkMode
                                ? [primaryDark, const Color(0xFF1F0B38)]
                                : [
                                    const Color(0xFF9D4EDD),
                                    primaryColor,
                                    primaryDark,
                                  ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: primaryColor.withValues(alpha: 0.4),
                              blurRadius: 24,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(18),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.business_rounded,
                                color: Colors.white,
                                size: 36,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_departments.length}',
                                    style: const TextStyle(
                                      fontSize: 42,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      letterSpacing: -1.5,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _departments.length == 1
                                        ? 'Departemen'
                                        : 'Departemen',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white.withValues(
                                        alpha: 0.95,
                                      ),
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Search Bar
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 24,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                          decoration: InputDecoration(
                            hintText: AppLanguage.tr(
                              'Petugas.members.department.search',
                            ),
                            hintStyle: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.2,
                            ),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: primaryColor,
                              size: 24,
                            ),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: Icon(
                                      Icons.clear_rounded,
                                      size: 20,
                                      color: Colors.grey.shade600,
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                      _filterDepartments();
                                    },
                                  )
                                : null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(20),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: Colors.grey.shade50,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 18,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Add Button
                      SizedBox(
                        width: double.infinity,
                        height: 60,
                        child: ElevatedButton.icon(
                          onPressed: _showAddDialog,
                          icon: const Icon(Icons.add_rounded, size: 28),
                          label: Text(
                            AppLanguage.tr('Petugas.members.department.add'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.3,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            elevation: 6,
                            shadowColor: primaryColor.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              if (_isLoading)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 60,
                          height: 60,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              primaryColor,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Loading...',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_errorMessage != null)
                SliverFillRemaining(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: errorColor.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.error_outline,
                              size: 48,
                              color: errorColor,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: errorColor,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _loadDepartments,
                            icon: const Icon(Icons.refresh),
                            label: Text(
                              AppLanguage.tr(
                                'Petugas.members.department.retry',
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else if (_filteredDepartments.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: warningColor.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.business_outlined,
                              size: 64,
                              color: warningColor,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            AppLanguage.tr(
                              'Petugas.members.department.no_departments',
                            ),
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap the button above to add your first department',
                            style: TextStyle(
                              color: Colors.grey.shade400,
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final department = _filteredDepartments[index];
                      return _buildDepartmentCard(department);
                    }, childCount: _filteredDepartments.length),
                  ),
                ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDepartmentCard(Map<String, dynamic> department) {
    final id = department['id'] as int;

    if (!_cardAnimationControllers.containsKey(id)) {
      _cardAnimationControllers[id] = AnimationController(
        duration: const Duration(milliseconds: 400),
        vsync: this,
      );
      _cardAnimationControllers[id]!.forward();
    }

    final animationController = _cardAnimationControllers[id]!;

    return Dismissible(
      key: Key('department_$id'),
      direction: DismissDirection.endToStart,
      onDismissed: (direction) {
        HapticFeedback.mediumImpact();
        _deleteDepartment(department);
      },
      confirmDismiss: (direction) async {
        final result = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: errorColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.warning, color: errorColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppLanguage.tr('Petugas.members.department.delete_confirm'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: errorColor,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              AppLanguage.tr('Petugas.members.department.delete_warning'),
              style: TextStyle(color: Colors.grey.shade700),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(
                  AppLanguage.tr('Petugas.members.department.cancel'),
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: errorColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 2,
                ),
                child: Text(
                  AppLanguage.tr('Petugas.members.department.delete'),
                ),
              ),
            ],
          ),
        );
        return result ?? false;
      },
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: errorColor,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Icon(Icons.delete, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Text(
              'Delete',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
      child: FadeTransition(
        opacity: animationController,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0.3, 0), end: Offset.zero)
              .animate(
                CurvedAnimation(
                  parent: animationController,
                  curve: Curves.easeOutCubic,
                ),
              ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: primaryColor.withValues(alpha: 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _editDepartment(department);
                },
                borderRadius: BorderRadius.circular(24),
                splashColor: primaryColor.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF8938DF),
                              primaryColor,
                              primaryDark,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: primaryColor.withValues(alpha: 0.4),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.business_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              department['name'] as String? ?? '',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 21,
                                color: Color(0xFF1F0B38),
                                letterSpacing: -0.5,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        primaryColor.withValues(alpha: 0.15),
                                        primaryDark.withValues(alpha: 0.1),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: primaryColor.withValues(
                                        alpha: 0.2,
                                      ),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.code,
                                        size: 12,
                                        color: primaryColor,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        department['code'] as String? ?? 'N/A',
                                        style: const TextStyle(
                                          color: primaryColor,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '#${department['id']}',
                                    style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.edit_rounded,
                            color: primaryColor,
                            size: 22,
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            _editDepartment(department);
                          },
                          padding: const EdgeInsets.all(12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
