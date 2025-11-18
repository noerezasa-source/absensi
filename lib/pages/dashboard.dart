import 'package:flutter/material.dart';
import '../services/attendance_service.dart';
import '../services/biometric_service.dart';
import '../models/attendance_record.dart';
import 'face_registration_page.dart';
import 'face_attendance_page.dart';

class DashboardPage extends StatefulWidget {
  final int organizationMemberId;

  const DashboardPage({
    super.key,
    required this.organizationMemberId,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final AttendanceService _attendanceService = AttendanceService();
  final BiometricService _biometricService = BiometricService();

  String selectedPresenceTab = 'This Week';
  String selectedHistoryTab = 'This Month';
  
  AttendanceRecord? _todayAttendance;
  bool _hasRegisteredFace = false;
  bool _isLoadingAttendance = true;
  bool _isCheckingFace = true;
  String? _errorMessage;

  // Data dummy untuk attendance history
  final List<Map<String, dynamic>> attendanceHistory = [
    {
      'studentName': 'Angelica Martha Faozi',
      'status': 'Arrived on time',
      'date': 'Wednesday, 8 January 2021',
      'time': '07:15',
      'icon': Icons.check_circle,
      'iconColor': Colors.green,
      'photoUrl': 'https://i.pravatar.cc/150?img=47',
    },
    {
      'studentName': 'Budi Santoso',
      'status': 'Arrived late',
      'date': 'Wednesday, 8 January 2021',
      'time': '07:45',
      'icon': Icons.schedule,
      'iconColor': Colors.orange,
      'photoUrl': 'https://i.pravatar.cc/150?img=12',
    },
    {
      'studentName': 'Citra Dewi',
      'status': 'Arrived on time',
      'date': 'Tuesday, 7 January 2021',
      'time': '07:10',
      'icon': Icons.check_circle,
      'iconColor': Colors.green,
      'photoUrl': 'https://i.pravatar.cc/150?img=32',
    },
    {
      'studentName': 'Dimas Prakoso',
      'status': 'Sick',
      'date': 'Tuesday, 7 January 2021',
      'time': '-',
      'icon': Icons.healing,
      'iconColor': Colors.orange,
      'photoUrl': 'https://i.pravatar.cc/150?img=15',
    },
    {
      'studentName': 'Eka Putri',
      'status': 'Leave',
      'date': 'Monday, 6 January 2021',
      'time': '-',
      'icon': Icons.event_busy,
      'iconColor': Colors.purple,
      'photoUrl': 'https://i.pravatar.cc/150?img=25',
    },
    {
      'studentName': 'Fajar Ramadhan',
      'status': 'Arrived on time',
      'date': 'Monday, 6 January 2021',
      'time': '07:20',
      'icon': Icons.check_circle,
      'iconColor': Colors.green,
      'photoUrl': 'https://i.pravatar.cc/150?img=8',
    },
  ];

  @override
  void initState() {
    super.initState();
    print('=== DASHBOARD INIT ===');
    print('Organization Member ID: ${widget.organizationMemberId}');
    _loadTodayAttendance();
    _checkFaceRegistration();
  }

  Future<void> _loadTodayAttendance() async {
    setState(() {
      _isLoadingAttendance = true;
      _errorMessage = null;
    });
    
    try {
      print('Loading today attendance...');
      final attendance = await _attendanceService.getTodayAttendance(
        widget.organizationMemberId,
      );
      print('Today attendance loaded: ${attendance != null}');
      if (attendance != null) {
        print('Check In: ${attendance.actualCheckIn}');
        print('Check Out: ${attendance.actualCheckOut}');
      }
      
      if (mounted) {
        setState(() {
          _todayAttendance = attendance;
          _isLoadingAttendance = false;
        });
      }
    } catch (e) {
      print('!!! ERROR loading attendance: $e');
      if (mounted) {
        setState(() {
          _isLoadingAttendance = false;
          _errorMessage = 'Failed to load attendance: $e';
        });
      }
    }
  }

  Future<void> _checkFaceRegistration() async {
    setState(() {
      _isCheckingFace = true;
      _errorMessage = null;
    });
    
    try {
      print('=== CHECKING FACE REGISTRATION ===');
      print('Organization Member ID: ${widget.organizationMemberId}');
      
      final hasRegistered = await _biometricService.hasRegisteredFace(
        widget.organizationMemberId,
      );
      
      print('Face registration check result: $hasRegistered');
      
      if (mounted) {
        setState(() {
          _hasRegisteredFace = hasRegistered;
          _isCheckingFace = false;
        });
      }
    } catch (e) {
      print('!!! ERROR checking face registration: $e');
      if (mounted) {
        setState(() {
          _hasRegisteredFace = false;
          _isCheckingFace = false;
          _errorMessage = 'Failed to check face: $e';
        });
      }
    }
  }

  Future<void> _refreshAll() async {
    print('=== REFRESHING ALL DATA ===');
    await Future.wait([
      _loadTodayAttendance(),
      _checkFaceRegistration(),
    ]);
  }

  Future<void> _handleAttendanceAction(String type) async {
    if (!_hasRegisteredFace) {
      // Show dialog to register face first
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.face, color: Colors.blue),
              SizedBox(width: 12),
              Text('Face Registration Required'),
            ],
          ),
          content: const Text(
            'You need to register your face first before using face recognition attendance.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _navigateToFaceRegistration();
              },
              child: const Text('Register Now'),
            ),
          ],
        ),
      );
      return;
    }

    // Navigate to face attendance page
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FaceAttendancePage(
          organizationMemberId: widget.organizationMemberId,
          attendanceType: type,
        ),
      ),
    );

    // Reload attendance if successful
    if (result == true) {
      _refreshAll();
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

    // Check face registration status after returning
    if (result == true) {
      _refreshAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // ---------- HEADER CARD ----------
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF4A90E2), Color(0xFF5BA3F5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(30),
                    bottomRight: Radius.circular(30),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 50, 20, 30),
                child: Column(
                  children: [
                    // Top bar
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.calendar_today,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        Text(
                          _getCurrentDate(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.notifications,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Profile Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Profile Image
                          Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF4A90E2),
                                width: 2,
                              ),
                              image: const DecorationImage(
                                image: NetworkImage(
                                  'https://i.pravatar.cc/150?img=47',
                                ),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Profile Info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Angelica Martha Faozi',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE3F2FD),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Text(
                                        'Student',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF4A90E2),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE3F2FD),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Text(
                                        'X Echo 1',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF4A90E2),
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Edit Icon
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.edit,
                              size: 18,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),        

              const SizedBox(height: 16),

              // ---------- ATTENDANCE BUTTONS ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _AttendanceButtons(
                  todayAttendance: _todayAttendance,
                  hasRegisteredFace: _hasRegisteredFace,
                  isLoading: _isLoadingAttendance,
                  onCheckIn: () => _handleAttendanceAction('check_in'),
                  onCheckOut: () => _handleAttendanceAction('check_out'),
                  onRegisterFace: _navigateToFaceRegistration,
                ),
              ),

              const SizedBox(height: 24),

              // ---------- STUDENT'S PRESENCE ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Student's Presence",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Tab Selector
                    Row(
                      children: [
                        _TabButton(
                          label: 'This Week',
                          isSelected: selectedPresenceTab == 'This Week',
                          onTap: () {
                            setState(() {
                              selectedPresenceTab = 'This Week';
                            });
                          },
                        ),
                        const SizedBox(width: 12),
                        _TabButton(
                          label: 'This Month',
                          isSelected: selectedPresenceTab == 'This Month',
                          onTap: () {
                            setState(() {
                              selectedPresenceTab = 'This Month';
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Stats Cards
                    Row(
                      children: [
                        _StatCard(
                          value: '3',
                          label: 'Arrive',
                          color: Colors.blue.shade50,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          value: '1',
                          label: 'Sick',
                          color: Colors.orange.shade50,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          value: '1',
                          label: 'Leave',
                          color: Colors.purple.shade50,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          value: '0',
                          label: 'Skip',
                          color: Colors.grey.shade100,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 30),

              // ---------- ATTENDANCE HISTORY ----------
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Attendance History',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Tab Selector
                    Row(
                      children: [
                        _TabButton(
                          label: 'This Week',
                          isSelected: selectedHistoryTab == 'This Week',
                          onTap: () {
                            setState(() {
                              selectedHistoryTab = 'This Week';
                            });
                          },
                        ),
                        const SizedBox(width: 12),
                        _TabButton(
                          label: 'This Month',
                          isSelected: selectedHistoryTab == 'This Month',
                          onTap: () {
                            setState(() {
                              selectedHistoryTab = 'This Month';
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // History Items
                    ...attendanceHistory.map((attendance) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _HistoryItem(
                          studentName: attendance['studentName'],
                          status: attendance['status'],
                          date: attendance['date'],
                          time: attendance['time'],
                          icon: attendance['icon'],
                          iconColor: attendance['iconColor'],
                          photoUrl: attendance['photoUrl'],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),

              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
      // ---------- BOTTOM NAVIGATION ----------
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFF4A90E2),
          unselectedItemColor: Colors.grey,
          currentIndex: 0,
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.assignment),
              label: 'Attendances',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDebugRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: valueColor ?? Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    final weekday = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][now.weekday - 1];
    final month = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][now.month - 1];
    return '$weekday, ${now.day} $month ${now.year}';
  }
}

// ---------- ATTENDANCE BUTTONS WIDGET ----------
class _AttendanceButtons extends StatelessWidget {
  final AttendanceRecord? todayAttendance;
  final bool hasRegisteredFace;
  final bool isLoading;
  final VoidCallback onCheckIn;
  final VoidCallback onCheckOut;
  final VoidCallback onRegisterFace;

  const _AttendanceButtons({
    required this.todayAttendance,
    required this.hasRegisteredFace,
    required this.isLoading,
    required this.onCheckIn,
    required this.onCheckOut,
    required this.onRegisterFace,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Container(
        padding: const EdgeInsets.all(24),
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
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final hasCheckedIn = todayAttendance?.actualCheckIn != null;
    final hasCheckedOut = todayAttendance?.actualCheckOut != null;

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
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.camera_alt, color: Color(0xFF4A90E2)),
              const SizedBox(width: 12),
              const Text(
                'Face Recognition Attendance',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Face Registration Status
          if (!hasRegisteredFace)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange.shade700),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Please register your face first',
                      style: TextStyle(
                        color: Colors.orange.shade900,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Today's Status
          if (hasCheckedIn)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: hasCheckedOut ? Colors.grey.shade100 : Colors.green.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.login,
                        color: hasCheckedOut ? Colors.grey : Colors.green,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Check In',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                          Text(
                            _formatTime(todayAttendance!.actualCheckIn!),
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (hasCheckedOut)
                    Row(
                      children: [
                        const Icon(
                          Icons.logout,
                          color: Colors.grey,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Check Out',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black54,
                              ),
                            ),
                            Text(
                              _formatTime(todayAttendance!.actualCheckOut!),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ),

          // Action Buttons
          Row(
            children: [
              if (!hasRegisteredFace)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onRegisterFace,
                    icon: const Icon(Icons.face),
                    label: const Text('Register Face'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4A90E2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: hasCheckedIn ? null : onCheckIn,
                    icon: const Icon(Icons.login),
                    label: const Text('Check In'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: hasCheckedIn ? Colors.grey : Colors.green,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      disabledForegroundColor: Colors.grey.shade600,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (!hasCheckedIn || hasCheckedOut) ? null : onCheckOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Check Out'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: (!hasCheckedIn || hasCheckedOut) 
                          ? Colors.grey 
                          : Colors.red,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade300,
                      disabledForegroundColor: Colors.grey.shade600,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}

// ---------- TAB BUTTON WIDGET ----------
class _TabButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF4A90E2) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? const Color(0xFF4A90E2) : Colors.grey.shade300,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.black54,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

// ---------- STAT CARD WIDGET ----------
class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- HISTORY ITEM WIDGET ----------
class _HistoryItem extends StatelessWidget {
  final String studentName;
  final String status;
  final String date;
  final String time;
  final IconData icon;
  final Color iconColor;
  final String photoUrl;

  const _HistoryItem({
    required this.studentName,
    required this.status,
    required this.date,
    required this.time,
    required this.icon,
    required this.iconColor,
    required this.photoUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
          // Photo Profile
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: iconColor,
                width: 2,
              ),
              image: DecorationImage(
                image: NetworkImage(photoUrl),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  studentName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  time != '-' ? '$date - $time' : date,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          // Status Icon
          Icon(
            icon,
            color: iconColor,
            size: 24,
          ),
        ],
      ),
    );
  }
}