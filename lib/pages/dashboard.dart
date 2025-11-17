import 'package:flutter/material.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  String selectedPresenceTab = 'This Week';
  String selectedHistoryTab = 'This Month';

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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SingleChildScrollView(
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
                      const Text(
                        'Friday, 10 February 2021',
                        style: TextStyle(
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

            // ---------- YOUR CHILD'S PRESENCE ----------
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
                  // History Items - menggunakan data dummy
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