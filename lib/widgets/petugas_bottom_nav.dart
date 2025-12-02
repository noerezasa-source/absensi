import 'package:flutter/material.dart';

class PetugasBottomNav extends StatelessWidget {
  final int currentIndex;
  final Function(int) onNavigationTap;
  final VoidCallback? onAttendanceTap; // Opsional - null jika tidak ada tombol attendance

  const PetugasBottomNav({
    super.key,
    required this.currentIndex,
    required this.onNavigationTap,
    this.onAttendanceTap, // Opsional
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 75 + bottomPadding,
      padding: EdgeInsets.only(bottom: 8 + bottomPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Bottom Navigation Items
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                  context,
                  Icons.home_rounded,
                  'Home',
                  0,
                ),
                _buildNavItem(
                  context,
                  Icons.people_rounded,
                  'Member',
                  1,
                ),
                // Spacer untuk tombol attendance di tengah (hanya jika ada)
                if (hasAttendanceButton) const SizedBox(width: 70),
                _buildNavItem(
                  context,
                  Icons.list_alt_rounded,
                  'Records',
                  2,
                ),
                _buildNavItem(
                  context,
                  Icons.person_rounded,
                  'Profile',
                  3,
                ),
              ],
            ),
          ),
          // Attendance Button di tengah yang timbul (hanya jika onAttendanceTap != null)
          if (hasAttendanceButton)
            Positioned(
              left: MediaQuery.of(context).size.width / 2 - 35,
              top: -30,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(35),
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF9333EA), Color(0xFF6B46C1)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF9333EA).withValues(alpha: 0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.how_to_reg_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context,
    IconData icon,
    String label,
    int index,
  ) {
    final isSelected = currentIndex == index;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onNavigationTap(index),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF9333EA).withValues(alpha: 0.1)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: isSelected
                        ? const Color(0xFF9333EA)
                        : Colors.grey.shade600,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: isSelected
                        ? const Color(0xFF9333EA)
                        : Colors.grey.shade600,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
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