import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

class ManualCheckPage extends StatefulWidget {
  final int organizationMemberId;
  final Map<String, dynamic> memberData;

  const ManualCheckPage({
    super.key,
    required this.organizationMemberId,
    required this.memberData,
  });

  @override
  State<ManualCheckPage> createState() => _ManualCheckPageState();
}

class _ManualCheckPageState extends State<ManualCheckPage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  // Form fields
  int? _selectedEmployeeId;
  String? _selectedEmployeeName;
  DateTime _selectedDate = DateTime.now();
  TimeOfDay _selectedTime = TimeOfDay.now();
  String _eventType = 'check_in'; // check_in or check_out
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();

  // Data
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _filteredEmployees = [];
  bool _isLoadingEmployees = true;
  bool _isSubmitting = false;
  int? _organizationId;
  final TextEditingController _searchController = TextEditingController();
  bool _showEmployeeDialog = false;

  @override
  void initState() {
    super.initState();
    _organizationId = widget.memberData['organization_id'] as int?;
    _loadEmployees();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _locationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEmployees() async {
    if (_organizationId == null) {
      setState(() {
        _isLoadingEmployees = false;
      });
      return;
    }

    try {
      setState(() {
        _isLoadingEmployees = true;
      });

      // Fetch all active members from the organization
      final response = await _supabase
          .from('organization_members')
          .select('''
            id,
            employee_id,
            user_id,
            user_profiles!inner(
              id,
              first_name,
              middle_name,
              last_name,
              display_name,
              profile_photo_url
            )
          ''')
          .eq('organization_id', _organizationId!)
          .eq('is_active', true)
          .order('user_profiles(display_name)', ascending: true);

      if (mounted) {
        setState(() {
          _employees = List<Map<String, dynamic>>.from(response);
          _filteredEmployees = _employees;
          _isLoadingEmployees = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading employees: $e');
      if (mounted) {
        setState(() {
          _isLoadingEmployees = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading employees: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF9333EA),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _selectTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF9333EA),
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedTime) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  String _getEmployeeName(Map<String, dynamic> employee) {
    final profile = employee['user_profiles'] as Map<String, dynamic>?;
    if (profile == null) return 'Unknown Employee';

    final displayName = profile['display_name'] as String?;
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }

    final firstName = profile['first_name'] as String? ?? '';
    final middleName = profile['middle_name'] as String? ?? '';
    final lastName = profile['last_name'] as String? ?? '';

    if (middleName.isNotEmpty) {
      return '$firstName $middleName $lastName'.trim();
    }

    return '$firstName $lastName'.trim();
  }

  String? _resolveProfilePhotoUrl(String? storedPath) {
    if (storedPath == null || storedPath.trim().isEmpty) return null;
    
    if (storedPath.startsWith('http://') || storedPath.startsWith('https://')) {
      return storedPath;
    }

    final normalizedPath = storedPath.startsWith('mass-profile/')
        ? storedPath
        : 'mass-profile/$storedPath';

    try {
      return _supabase.storage
          .from('profile-photos')
          .getPublicUrl(normalizedPath);
    } catch (_) {
      return null;
    }
  }

  void _filterEmployees(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredEmployees = _employees;
      } else {
        _filteredEmployees = _employees.where((employee) {
          final name = _getEmployeeName(employee).toLowerCase();
          final employeeId = (employee['employee_id'] as String? ?? '').toLowerCase();
          final searchLower = query.toLowerCase();
          
          return name.contains(searchLower) || employeeId.contains(searchLower);
        }).toList();
      }
    });
  }

  Future<void> _showEmployeeSelectionDialog() async {
    _searchController.clear();
    _filteredEmployees = _employees;
    
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Container(
                width: MediaQuery.of(context).size.width * 0.85,
                height: MediaQuery.of(context).size.height * 0.7,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Select Employee',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Search Bar
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          hintText: 'Search by name or employee ID...',
                          prefixIcon: const Icon(Icons.search, color: Color(0xFF9333EA)),
                          suffixIcon: _searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 20),
                                  onPressed: () {
                                    setDialogState(() {
                                      _searchController.clear();
                                      _filterEmployees('');
                                    });
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (value) {
                          setDialogState(() {
                            _filterEmployees(value);
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Employee Count
                    Text(
                      '${_filteredEmployees.length} employee(s) found',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    
                    // Employee List
                    Expanded(
                      child: _filteredEmployees.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.person_off,
                                    size: 64,
                                    color: Colors.grey.shade300,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No employees found',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: _filteredEmployees.length > 10 
                                  ? 10 
                                  : _filteredEmployees.length,
                              itemBuilder: (context, index) {
                                final employee = _filteredEmployees[index];
                                final name = _getEmployeeName(employee);
                                final employeeId = employee['employee_id'] as String?;
                                final profile = employee['user_profiles'] as Map<String, dynamic>?;
                                final photoUrl = _resolveProfilePhotoUrl(
                                  profile?['profile_photo_url'] as String?,
                                );
                                final isSelected = _selectedEmployeeId == employee['id'];
                                
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: isSelected 
                                        ? const Color(0xFF9333EA).withOpacity(0.1)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isSelected
                                          ? const Color(0xFF9333EA)
                                          : Colors.grey.shade200,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    leading: CircleAvatar(
                                      radius: 24,
                                      backgroundColor: Colors.grey.shade200,
                                      backgroundImage: photoUrl != null 
                                          ? NetworkImage(photoUrl) 
                                          : null,
                                      child: photoUrl == null
                                          ? const Icon(
                                              Icons.person,
                                              size: 24,
                                              color: Colors.grey,
                                            )
                                          : null,
                                    ),
                                    title: Text(
                                      name,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: isSelected
                                            ? const Color(0xFF9333EA)
                                            : Colors.black87,
                                      ),
                                    ),
                                    subtitle: employeeId != null
                                        ? Text(
                                            'ID: $employeeId',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Colors.grey.shade600,
                                            ),
                                          )
                                        : null,
                                    trailing: isSelected
                                        ? const Icon(
                                            Icons.check_circle,
                                            color: Color(0xFF9333EA),
                                            size: 24,
                                          )
                                        : null,
                                    onTap: () {
                                      setState(() {
                                        _selectedEmployeeId = employee['id'] as int;
                                        _selectedEmployeeName = name;
                                      });
                                      Navigator.pop(context);
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                    
                    // Show more indicator
                    if (_filteredEmployees.length > 10)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Center(
                          child: Text(
                            'Showing 10 of ${_filteredEmployees.length} employees. Use search to find more.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                              fontStyle: FontStyle.italic,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _submitAttendance() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedEmployeeId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an employee'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Combine date and time
      final eventDateTime = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );

      // Check if attendance record exists for this date
      final attendanceDate = DateFormat('yyyy-MM-dd').format(_selectedDate);
      
      final existingRecord = await _supabase
          .from('attendance_records')
          .select('id, actual_check_in, actual_check_out')
          .eq('organization_member_id', _selectedEmployeeId!)
          .eq('attendance_date', attendanceDate)
          .maybeSingle();

      // Validasi: Cek apakah sudah ada check in/out untuk event type yang dipilih
      if (existingRecord != null) {
        if (_eventType == 'check_in' && existingRecord['actual_check_in'] != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Employee already checked in on ${DateFormat('dd MMM yyyy').format(_selectedDate)}',
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
          setState(() {
            _isSubmitting = false;
          });
          return;
        }
        
        if (_eventType == 'check_out') {
          if (existingRecord['actual_check_in'] == null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Employee must check in first before checking out'),
                  backgroundColor: Colors.orange,
                ),
              );
            }
            setState(() {
              _isSubmitting = false;
            });
            return;
          }
          
          if (existingRecord['actual_check_out'] != null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Employee already checked out on ${DateFormat('dd MMM yyyy').format(_selectedDate)}',
                  ),
                  backgroundColor: Colors.orange,
                ),
              );
            }
            setState(() {
              _isSubmitting = false;
            });
            return;
          }
        }
      } else if (_eventType == 'check_out') {
        // Jika tidak ada record dan ingin check out
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No check-in record found. Please check in first.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        setState(() {
          _isSubmitting = false;
        });
        return;
      }

      Map<String, dynamic> attendanceData;
      int recordId;
      
      if (_eventType == 'check_in') {
        attendanceData = {
          'actual_check_in': eventDateTime.toUtc().toIso8601String(),
          'check_in_method': 'manual',
          'check_in_location': _locationController.text.isNotEmpty
              ? {'address': _locationController.text, 'type': 'manual'}
              : null,
        };
      } else {
        attendanceData = {
          'actual_check_out': eventDateTime.toUtc().toIso8601String(),
          'check_out_method': 'manual',
          'check_out_location': _locationController.text.isNotEmpty
              ? {'address': _locationController.text, 'type': 'manual'}
              : null,
        };
        
        // Calculate work duration
        if (existingRecord != null && existingRecord['actual_check_in'] != null) {
          final checkInTime = DateTime.parse(existingRecord['actual_check_in']);
          final workDuration = eventDateTime.toUtc().difference(checkInTime).inMinutes;
          attendanceData['work_duration_minutes'] = workDuration;
        }
      }

      if (existingRecord != null) {
        // Update existing record
        await _supabase
            .from('attendance_records')
            .update(attendanceData)
            .eq('id', existingRecord['id']);
        
        recordId = existingRecord['id'] as int;
      } else {
        // Create new record
        attendanceData.addAll({
          'organization_member_id': _selectedEmployeeId,
          'attendance_date': attendanceDate,
          'status': 'present',
          'validation_status': 'approved',
        });

        final result = await _supabase
            .from('attendance_records')
            .insert(attendanceData)
            .select('id')
            .single();
        
        recordId = result['id'] as int;
      }

      // Create attendance log with attendance_record_id
      await _supabase.from('attendance_logs').insert({
        'organization_member_id': _selectedEmployeeId,
        'attendance_record_id': recordId, // ← PENTING: Tambahkan ini
        'event_type': _eventType,
        'event_time': eventDateTime.toUtc().toIso8601String(),
        'method': 'manual',
        'location': _locationController.text.isNotEmpty
            ? {'address': _locationController.text, 'type': 'manual'}
            : null,
        'is_verified': true,
        'verification_method': 'manual_entry',
        'raw_data': {
          'notes': _notesController.text,
          'entered_by': widget.organizationMemberId,
        },
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Attendance recorded successfully for $_selectedEmployeeName',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );

        // Navigate back to dashboard after successful submission
        Navigator.of(context).pop(true); // Return true to indicate success
      }
    } catch (e) {
      debugPrint('Error submitting attendance: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text(
          'Manual Check',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF9333EA),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoadingEmployees
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF6B46C1), Color(0xFF9333EA)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.edit_note,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                          const SizedBox(width: 16),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Manual Attendance',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Record attendance manually',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Employee Selection
                    const Text(
                      'Select Employee',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: _showEmployeeSelectionDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _selectedEmployeeId != null
                                ? const Color(0xFF9333EA)
                                : Colors.grey.shade300,
                            width: _selectedEmployeeId != null ? 2 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.05),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.person,
                              color: _selectedEmployeeId != null
                                  ? const Color(0xFF9333EA)
                                  : Colors.grey.shade600,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _selectedEmployeeId != null
                                  ? Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _selectedEmployeeName ?? 'Selected Employee',
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.black87,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Tap to change',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                    )
                                  : Text(
                                      'Choose an employee',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                            ),
                            Icon(
                              Icons.arrow_drop_down,
                              color: Colors.grey.shade600,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Event Type Selection
                    const Text(
                      'Attendance Type',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildEventTypeCard(
                            'Check In',
                            'check_in',
                            Icons.login,
                            Colors.green,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildEventTypeCard(
                            'Check Out',
                            'check_out',
                            Icons.logout,
                            Colors.red,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Date and Time
                    const Text(
                      'Date & Time',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _buildDateTimeCard(
                            DateFormat('dd MMM yyyy').format(_selectedDate),
                            Icons.calendar_today,
                            _selectDate,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildDateTimeCard(
                            _selectedTime.format(context),
                            Icons.access_time,
                            _selectTime,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Location (Optional)
                    const Text(
                      'Location (Optional)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextFormField(
                        controller: _locationController,
                        decoration: const InputDecoration(
                          hintText: 'Enter location',
                          prefixIcon: Icon(Icons.location_on, color: Color(0xFF9333EA)),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Notes (Optional)
                    const Text(
                      'Notes (Optional)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TextFormField(
                        controller: _notesController,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          hintText: 'Add any notes or remarks',
                          prefixIcon: Icon(Icons.note, color: Color(0xFF9333EA)),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Submit Button
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _submitAttendance,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF9333EA),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                height: 24,
                                width: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Submit Attendance',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildEventTypeCard(
    String label,
    String type,
    IconData icon,
    Color color,
  ) {
    final isSelected = _eventType == type;
    return GestureDetector(
      onTap: () {
        setState(() {
          _eventType = type;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? color : Colors.grey.shade300,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? color : Colors.grey,
              size: 32,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isSelected ? color : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateTimeCard(String text, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF9333EA)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}