// lib/helpers/rfid_mode_helper.dart

import 'package:shared_preferences/shared_preferences.dart';

class RfidModeHelper {
  static const String _rfidModeKey = 'rfid_attendance_mode';
  static const String _rfidModeOrgKey = 'rfid_attendance_mode_org_id';

  // Get saved RFID mode for a specific organization
  static Future<bool> getRfidMode(int organizationId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedOrgId = prefs.getInt(_rfidModeOrgKey);
      
      // Only return true if the saved org ID matches current org ID
      if (savedOrgId == organizationId) {
        return prefs.getBool(_rfidModeKey) ?? false;
      }
      
      // If org ID doesn't match, return false (mode is org-specific)
      return false;
    } catch (e) {
      return false;
    }
  }

  // Save RFID mode for a specific organization
  static Future<void> saveRfidMode(int organizationId, bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_rfidModeKey, enabled);
      await prefs.setInt(_rfidModeOrgKey, organizationId);
    } catch (e) {
      // Silently fail if save fails
    }
  }

  // Clear RFID mode (when logging out or switching org)
  static Future<void> clearRfidMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_rfidModeKey);
      await prefs.remove(_rfidModeOrgKey);
    } catch (e) {
      // Silently fail if clear fails
    }
  }
}

