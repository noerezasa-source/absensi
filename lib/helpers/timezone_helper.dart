import 'package:intl/intl.dart';

class TimezoneHelper {
  /// Parse ISO string and convert to organization timezone
  /// Returns DateTime in organization timezone
  static DateTime? parseAndConvert(
    String? isoString,
    String organizationTimezone,
  ) {
    if (isoString == null || isoString.isEmpty) {
      return null;
    }

    try {
      // Parse as UTC first
      final utcDateTime = DateTime.parse(isoString);
      
      // Get timezone offset for the organization timezone
      // For Asia/Jakarta (WIB), offset is +7 hours from UTC
      final offset = _getTimezoneOffset(organizationTimezone);
      
      // Convert UTC to organization timezone
      return utcDateTime.add(Duration(hours: offset));
    } catch (e) {
      return null;
    }
  }

  /// Get timezone offset in hours from UTC
  /// Common timezones:
  /// - Asia/Jakarta (WIB): +7
  /// - Asia/Makassar (WITA): +8
  /// - Asia/Jayapura (WIT): +9
  /// - UTC: 0
  static int _getTimezoneOffset(String timezone) {
    final tzLower = timezone.toLowerCase().trim();
    
    // Indonesia timezones
    if (tzLower.contains('jakarta') || tzLower == 'wib' || tzLower == 'asia/jakarta') {
      return 7; // WIB (Western Indonesian Time)
    } else if (tzLower.contains('makassar') || tzLower == 'wita' || tzLower == 'asia/makassar') {
      return 8; // WITA (Central Indonesian Time)
    } else if (tzLower.contains('jayapura') || tzLower == 'wit' || tzLower == 'asia/jayapura') {
      return 9; // WIT (Eastern Indonesian Time)
    } else if (tzLower == 'utc' || tzLower == 'gmt' || tzLower == 'utc+0') {
      return 0;
    }
    
    // Try to parse offset from format like "UTC+7" or "+07:00"
    if (tzLower.startsWith('utc+') || tzLower.startsWith('utc-')) {
      try {
        final offsetStr = tzLower.replaceAll('utc', '').replaceAll('+', '').replaceAll('-', '');
        final offset = int.parse(offsetStr);
        return tzLower.contains('-') ? -offset : offset;
      } catch (e) {
        // Ignore parse error
      }
    }
    
    // Default to WIB (Indonesia most common)
    return 7;
  }

  /// Format DateTime with timezone consideration
  static String formatDateTime(
    DateTime dateTime,
    String format,
  ) {
    try {
      return DateFormat(format).format(dateTime);
    } catch (e) {
      return dateTime.toString();
    }
  }
}

