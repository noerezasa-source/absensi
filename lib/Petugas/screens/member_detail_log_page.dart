import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MemberDetailLogPage extends StatelessWidget {
  final int memberId;
  final String memberName;
  final bool isDarkMode;

  const MemberDetailLogPage({
    super.key,
    required this.memberId,
    required this.memberName,
    this.isDarkMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: isDarkMode ? const Color(0xFF1F0B38) : Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: const Color(0xFF4A1E79),
        title: Text(memberName),
        elevation: 0,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.assignment_outlined,
              size: 80,
              color: const Color(0xFF8B5CF6).withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'Detail Log Absensi',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDarkMode ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Member ID: $memberId',
              style: TextStyle(
                fontSize: 16,
                color: isDarkMode ? Colors.white70 : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              memberName,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: isDarkMode ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 32),
            Text(
              'Fitur ini akan menampilkan riwayat absensi lengkap untuk anggota ini.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDarkMode ? Colors.white60 : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
