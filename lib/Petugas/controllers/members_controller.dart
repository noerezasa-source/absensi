import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/member_performance_service.dart';

class MembersController extends GetxController {
  final SupabaseClient _supabase = Supabase.instance.client;
  
  // Reactive variables
  final RxList<Map<String, dynamic>> organizationMembers = <Map<String, dynamic>>[].obs;
  final RxString selectedClassFilter = 'all'.obs;
  final RxString searchQuery = ''.obs;
  final RxBool isLoading = false.obs;
  final RxBool isLoadingPerformance = false.obs;
  final RxMap<String, dynamic> memberPerformanceStats = <String, dynamic>{}.obs;
  final RxList<Map<String, dynamic>> membersPerformance = <Map<String, dynamic>>[].obs;
  
  // Class options
  final List<String> classOptions = [
    'all',
    'X RPL 1',
    'XI RPL 1',
    'XII RPL 1',
  ];
  
  // Organization info
  RxInt organizationId = 0.obs;
  RxString organizationTimezone = 'Asia/Jakarta'.obs;
  
  @override
  void onInit() {
    super.onInit();
    // Initialize with default filter
    selectedClassFilter.value = 'all';
  }
  
  void setOrganizationId(int id) {
    organizationId.value = id;
  }
  
  void setOrganizationTimezone(String timezone) {
    organizationTimezone.value = timezone;
  }
  
  void setSelectedClassFilter(String className) {
    selectedClassFilter.value = className;
  }
  
  void setSearchQuery(String query) {
    searchQuery.value = query;
  }
  
  String _getMemberName(Map<String, dynamic> member) {
    final profile = member['user_profiles'] as Map<String, dynamic>?;
    if (profile != null) {
      final displayName = (profile['display_name'] as String?)?.trim();
      if (displayName != null && displayName.isNotEmpty) return displayName;
      final firstName = (profile['first_name'] as String?)?.trim() ?? '';
      final lastName = (profile['last_name'] as String?)?.trim() ?? '';
      final fullName = '$firstName $lastName'.trim();
      if (fullName.isNotEmpty) return fullName;
    }
    final empId = (member['employee_id'] as String?)?.trim();
    if (empId != null && empId.isNotEmpty) return empId;
    return 'Member ${member['id']}';
  }

  // Get filtered members based on class filter and search query (Sorted A-Z)
  List<Map<String, dynamic>> get filteredMembers {
    var members = organizationMembers.toList();
    
    // Filter by class
    if (selectedClassFilter.value != 'all') {
      members = members.where((member) {
        final className = member['class_name'] as String? ?? '';
        return className == selectedClassFilter.value;
      }).toList();
    }
    
    // Filter by search query
    if (searchQuery.value.isNotEmpty) {
      final query = searchQuery.value.toLowerCase();
      members = members.where((member) {
        final profile = member['user_profiles'] as Map<String, dynamic>? ?? {};
        final displayName = (profile['display_name'] as String? ?? '').toLowerCase();
        final firstName = (profile['first_name'] as String? ?? '').toLowerCase();
        final lastName = (profile['last_name'] as String? ?? '').toLowerCase();
        final employeeId = (member['employee_id'] as String? ?? '').toLowerCase();
        
        return displayName.contains(query) ||
               firstName.contains(query) ||
               lastName.contains(query) ||
               employeeId.contains(query);
      }).toList();
    }
    
    // Sort A - Z by member name
    members.sort((a, b) => _getMemberName(a).toLowerCase().compareTo(_getMemberName(b).toLowerCase()));

    return members;
  }
  
  Future<bool> prehydrateFromCache(int orgId) async {
    final cacheKey = 'org_members_all_$orgId';
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStr = prefs.getString(cacheKey);
      if (cachedStr != null) {
        final cachedList = List<Map<String, dynamic>>.from(jsonDecode(cachedStr));
        if (cachedList.isNotEmpty) {
          cachedList.sort((a, b) => _getMemberName(a).toLowerCase().compareTo(_getMemberName(b).toLowerCase()));
          organizationMembers.value = cachedList;
          isLoading.value = false;
          return true;
        }
      }
    } catch (e) {
      debugPrint('Cache read error: $e');
    }
    return false;
  }

  Future<void> loadOrganizationMembers(int orgId) async {
    // OFFLINE-FIRST: Try to load from cache immediately
    final hasCache = await prehydrateFromCache(orgId);
    if (!hasCache && organizationMembers.isEmpty) {
      isLoading.value = true;
    }

    // BACKGROUND SYNC: Fetch fresh data from Supabase
    try {
      final response = await _supabase
          .from('organization_members')
          .select('''
            id,
            employee_id,
            department,
            position,
            class_name,
            user_profiles!left (
              display_name,
              first_name,
              last_name,
              profile_photo_url
            ),
            departments!left (
              id,
              name
            ),
            biometric_data!left (
              id,
              is_active,
              biometric_type
            ),
            rfid_cards!left (
              id,
              card_number,
              is_active
            )
          ''')
          .eq('organization_id', orgId)
          .eq('is_active', true)
          .order('id');
      
      final list = List<Map<String, dynamic>>.from(response);
      final perfService = MemberPerformanceService();

      for (final member in list) {
        if (member.containsKey('departments!organization_members_department_id_fkey')) {
          member['departments'] = member['departments!organization_members_department_id_fkey'];
        }
        final rfidCards = member['rfid_cards'];
        if (rfidCards is List && rfidCards.isNotEmpty) {
          final activeCard = rfidCards.firstWhere(
            (c) => c['is_active'] == true,
            orElse: () => null,
          );
          if (activeCard != null) {
            member['rfid_card_id'] = activeCard['id'];
          }
        }

        // Auto-resolve missing profile photo from Storage face-templates bucket if missing
        final profile = member['user_profiles'] as Map<String, dynamic>?;
        final photo = profile?['profile_photo_url'] as String? ?? member['profile_photo_url'] as String?;
        if (photo == null || photo.trim().isEmpty) {
          await perfService.autoResolveFacePhoto(member);
        }
      }
      
      // Sort A - Z by member name
      list.sort((a, b) => _getMemberName(a).toLowerCase().compareTo(_getMemberName(b).toLowerCase()));

      // Update reactive variable with fresh data
      organizationMembers.value = list;
      
      // Save to cache
      final cacheKey = 'org_members_all_$orgId';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(cacheKey, jsonEncode(list));
      } catch (e) {
        debugPrint('Cache write error: $e');
      }
      
    } catch (e) {
      if (organizationMembers.isEmpty) {
        Get.snackbar('Error', 'Gagal memuat anggota: $e');
      }
    } finally {
      isLoading.value = false;
    }
  }
  
  Future<void> loadMemberPerformance(int orgId, String timePeriod) async {
    isLoadingPerformance.value = true;
    try {
      // This would call your performance service
      // For now, placeholder implementation
      memberPerformanceStats.value = {};
      membersPerformance.value = [];
    } catch (e) {
      Get.snackbar('Error', 'Failed to load performance: $e');
    } finally {
      isLoadingPerformance.value = false;
    }
  }
}
