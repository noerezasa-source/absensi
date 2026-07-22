import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/attendance_model.dart';
import '../helpers/cache_helper.dart';

class DeviceService {
  final SupabaseClient _supabase = Supabase.instance.client;
  final CacheHelper _cache = CacheHelper();
  AttendanceDevice? _selectedDevice;

  static const String _selectedDeviceKey = 'selected_device_id';
  static const Duration _devicesCacheTTL = Duration(minutes: 10);

  AttendanceDevice? get selectedDevice => _selectedDevice;

  /// Load all devices for the given organization
  Future<List<AttendanceDevice>> loadDevices(
    String organizationId, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'devices_list_$organizationId';

    if (!forceRefresh) {
      final cached = _cache.get<List<AttendanceDevice>>(cacheKey);
      if (cached != null && cached.isNotEmpty) {
        debugPrint('DeviceService: Devices loaded from cache (${cached.length} items)');
        return cached;
      }
    }

    final devices = <AttendanceDevice>[];

    try {
      final orgIdInt = int.tryParse(organizationId);

      // 1. Query attendance_devices table
      dynamic response;
      if (orgIdInt != null) {
        try {
          response = await _supabase
              .from('attendance_devices')
              .select('*')
              .eq('organization_id', orgIdInt);
        } catch (e) {
          debugPrint('DeviceService: Org ID query error: $e');
        }
      } else if (organizationId.isNotEmpty) {
        try {
          response = await _supabase
              .from('attendance_devices')
              .select('*')
              .eq('organization_id', organizationId);
        } catch (e) {
          debugPrint('DeviceService: String Org ID query error: $e');
        }
      }

      if (response == null || (response is List && response.isEmpty)) {
        try {
          response = await _supabase
              .from('attendance_devices')
              .select('*');
        } catch (e) {
          debugPrint('DeviceService: All rows query error: $e');
        }
      }

      if (response is List) {
        for (var item in response) {
          if (item is Map<String, dynamic>) {
            try {
              devices.add(AttendanceDevice.fromJson(item));
            } catch (err) {
              debugPrint('DeviceService: Error parsing device row: $err');
            }
          }
        }
      }

      // 2. Query organizations table to include Organization locations
      try {
        dynamic orgResponse;
        if (orgIdInt != null) {
          orgResponse = await _supabase
              .from('organizations')
              .select('*')
              .eq('id', orgIdInt);
        }

        if (orgResponse == null || (orgResponse is List && orgResponse.isEmpty)) {
          orgResponse = await _supabase
              .from('organizations')
              .select('*')
              .eq('is_active', true);
        }

        if (orgResponse is List) {
          for (var org in orgResponse) {
            if (org is Map<String, dynamic>) {
              final orgIdStr = org['id']?.toString() ?? '';
              final orgName = (org['name'] as String?)?.trim() ?? 'Organisasi';
              final orgAddress = (org['address'] as String?)?.trim();

              final exists = devices.any(
                (d) =>
                    d.id == 'org_$orgIdStr' ||
                    d.deviceName.toLowerCase() == orgName.toLowerCase(),
              );

              if (!exists) {
                devices.add(
                  AttendanceDevice(
                    id: 'org_$orgIdStr',
                    organizationId: orgIdStr,
                    deviceTypeId: '1',
                    deviceCode: org['inv_code']?.toString() ?? 'ORG_$orgIdStr',
                    deviceName: orgName,
                    location: (orgAddress != null && orgAddress.isNotEmpty)
                        ? orgAddress
                        : 'Lokasi Utama ($orgName)',
                    latitude: org['latitude'] != null
                        ? double.tryParse(org['latitude'].toString())
                        : null,
                    longitude: org['longitude'] != null
                        ? double.tryParse(org['longitude'].toString())
                        : null,
                    radiusMeters: 500,
                    isActive: org['is_active'] ?? true,
                  ),
                );
              }
            }
          }
        }
      } catch (e) {
        debugPrint('DeviceService: Error loading organization locations: $e');
      }

      debugPrint('DeviceService: Total loaded ${devices.length} devices/locations');

      if (devices.isNotEmpty) {
        _cache.set(cacheKey, devices, ttl: _devicesCacheTTL);
      }

      return devices;
    } catch (e) {
      debugPrint('DeviceService: Error loading devices: $e');
      return devices;
    }
  }

  /// Load a specific device by ID
  Future<AttendanceDevice?> loadDeviceById(
    String deviceId, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = 'device_$deviceId';

    // Check cache first
    if (!forceRefresh) {
      final cached = _cache.get<AttendanceDevice>(cacheKey);
      if (cached != null) {
        debugPrint('DeviceService: Device loaded from cache');
        return cached;
      }
    }

    try {
      debugPrint('DeviceService: Loading device by ID: $deviceId');

      // 1. Handle Organization fallback IDs (e.g. "org_1")
      if (deviceId.startsWith('org_')) {
        final orgIdStr = deviceId.substring(4);
        final orgIdInt = int.tryParse(orgIdStr);
        if (orgIdInt != null) {
          try {
            final org = await _supabase
                .from('organizations')
                .select('*')
                .eq('id', orgIdInt)
                .maybeSingle();

            if (org != null) {
              final orgName = (org['name'] as String?)?.trim() ?? 'Organisasi';
              final orgAddress = (org['address'] as String?)?.trim();
              final device = AttendanceDevice(
                id: deviceId,
                organizationId: orgIdStr,
                deviceTypeId: '1',
                deviceCode: org['inv_code']?.toString() ?? 'ORG_$orgIdStr',
                deviceName: orgName,
                location: (orgAddress != null && orgAddress.isNotEmpty)
                    ? orgAddress
                    : 'Lokasi Utama ($orgName)',
                latitude: org['latitude'] != null
                    ? double.tryParse(org['latitude'].toString())
                    : null,
                longitude: org['longitude'] != null
                    ? double.tryParse(org['longitude'].toString())
                    : null,
                radiusMeters: 500,
                isActive: org['is_active'] ?? true,
              );
              _cache.set(cacheKey, device, ttl: _devicesCacheTTL);
              return device;
            }
          } catch (e) {
            debugPrint('DeviceService: Error loading org device by ID: $e');
          }
        }
      }

      // 2. Standard device ID from attendance_devices table (only query if deviceId is valid int)
      final idInt = int.tryParse(deviceId);
      if (idInt != null) {
        final response = await _supabase
            .from('attendance_devices')
            .select('*')
            .eq('id', idInt)
            .maybeSingle();

        if (response != null) {
          final device = AttendanceDevice.fromJson(response);
          debugPrint(
            'DeviceService: Device found: ${device.deviceName} (ID: ${device.id}, OrgID: ${device.organizationId})',
          );
          _cache.set(cacheKey, device, ttl: _devicesCacheTTL);
          return device;
        }
      }

      debugPrint('DeviceService: Device not found for ID: $deviceId');
      return null;
    } catch (e) {
      debugPrint('DeviceService: Error loading device: $e');
      return null;
    }
  }

  /// Set the selected device and save to preferences
  Future<void> setSelectedDevice(AttendanceDevice device) async {
    try {
      _selectedDevice = device;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedDeviceKey, device.id);

      debugPrint(
        'DeviceService: Device saved to preferences: ${device.deviceName} (ID: ${device.id})',
      );
    } catch (e) {
      debugPrint('DeviceService: Error setting selected device: $e');
    }
  }

  /// Load the previously selected device from preferences
  Future<AttendanceDevice?> loadSelectedDevice(String organizationId) async {
    try {
      debugPrint(
        'DeviceService: Loading selected device for org: $organizationId',
      );

      final prefs = await SharedPreferences.getInstance();
      final savedDeviceId = prefs.getString(_selectedDeviceKey);

      if (savedDeviceId != null) {
        final device = await loadDeviceById(savedDeviceId);
        if (device != null) {
          _selectedDevice = device;
          return device;
        }
      }

      return null;
    } catch (e) {
      debugPrint('DeviceService: Error loading selected device: $e');
      return null;
    }
  }

  /// Clear the selected device
  Future<void> clearSelectedDevice() async {
    try {
      debugPrint('DeviceService: Clearing selected device');
      _selectedDevice = null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_selectedDeviceKey);

      debugPrint(
        'DeviceService: Selected device cleared from cache and preferences',
      );
    } catch (e) {
      debugPrint('DeviceService: Error clearing selected device: $e');
      throw Exception('Error clearing selected device: $e');
    }
  }

  /// Check if a device selection is required for the organization
  Future<bool> isSelectionRequired(
    String organizationId, {
    bool forceRefresh = false,
  }) async {
    try {
      debugPrint(
        'DeviceService: Checking if selection required for org: $organizationId',
      );
      // ✅ OPTIMIZATION: Use cached devices if available
      final devices = await loadDevices(
        organizationId,
        forceRefresh: forceRefresh,
      );

      debugPrint('DeviceService: Found ${devices.length} devices');

      // If there are multiple devices, selection is required
      if (devices.length > 1) {
        debugPrint(
          'DeviceService: Multiple devices found - selection required',
        );
        return true;
      }

      // If there's exactly one device, auto-select it
      if (devices.length == 1) {
        debugPrint(
          'DeviceService: Single device found - auto-selecting: ${devices.first.deviceName}',
        );
        await setSelectedDevice(devices.first);
        return false;
      }

      // No devices available - selection not required
      debugPrint('DeviceService: No devices found');
      return false;
    } catch (e) {
      debugPrint('DeviceService: Error checking selection requirement: $e');
      throw Exception('Error checking selection requirement: $e');
    }
  }
}
