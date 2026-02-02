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
    this.isDarkMode = false,
  });

  final bool isDarkMode;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasAttendanceButton = onAttendanceTap != null;

    return Container(
      height: 70 + bottomPadding,
      decoration: BoxDecoration(
        color: isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkMode ? 0.3 : 0.1),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Bottom Navigation Items
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: 8 + bottomPadding,
            ),
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
                if (hasAttendanceButton) const SizedBox(width: 80),
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
              top: -32,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAttendanceTap,
                  borderRadius: BorderRadius.circular(35),
                  child: Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: isDarkMode ? const Color(0xFF9E77F1) : const Color(0xFF4A1E79),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isDarkMode ? const Color(0xFF1F0B38) : Colors.white,
                        width: 5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (isDarkMode ? const Color(0xFF9E77F1) : const Color(0xFF4A1E79))
                              .withValues(alpha: isDarkMode ? 0.3 : 0.4),
                          blurRadius: 15,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.face_retouching_natural_rounded,
                      color: Colors.white,
                      size: 30,
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
    final accentColor = isDarkMode ? const Color(0xFFD0BCFF) : const Color(0xFF4A1E79);

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onNavigationTap(index),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Top Indicator Line
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 3,
                width: isSelected ? 24 : 0,
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: isDarkMode && isSelected
                      ? [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.3),
                            blurRadius: 3,
                          )
                        ]
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Stack(
                alignment: Alignment.center,
                children: [
                  if (isDarkMode && isSelected)
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.15),
                            blurRadius: 15,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                    ),
                  Icon(
                    icon,
                    color: isSelected
                        ? accentColor
                        : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                    size: 24,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: isSelected
                      ? accentColor
                      : (isDarkMode ? Colors.white54 : Colors.grey.shade600),
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}