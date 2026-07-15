// lib/models/karyawan_wajah.dart
//
// Entity ObjectBox untuk menyimpan face embedding karyawan secara offline.
// Digunakan bersama FaceEmbeddingService untuk Real-Time Face Recognition.
//
// Cara generate kode ObjectBox setelah menambahkan entity ini:
//   dart run build_runner build --delete-conflicting-outputs
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:typed_data'; // Float32List untuk @HnswIndex
import 'package:objectbox/objectbox.dart';

/// Entity ObjectBox yang menyimpan embedding wajah karyawan.
///
/// Setiap karyawan yang terdaftar biometrik wajah akan memiliki satu
/// record di sini dengan 128 angka float hasil MobileFaceNet.
@Entity()
class KaryawanWajah {
  /// ID lokal ObjectBox (wajib, auto-increment).
  @Id()
  int id = 0;

  /// ID anggota di Supabase (organization_member_id).
  /// Di-index untuk query cepat berdasarkan member.
  @Index()
  int organizationMemberId;

  /// ID organisasi — untuk isolasi data antar-tenant (multi-org).
  @Index()
  int organizationId;

  /// Nama tampilan karyawan (untuk UI konfirmasi setelah match).
  String namaLengkap;

  /// URL foto profil dari Supabase Storage.
  /// Opsional — digunakan untuk menampilkan foto karyawan saat teridentifikasi.
  String? profilePhotoUrl;

  /// 🧠 CORE: Vector 128-dimensi dari model MobileFaceNet.
  ///
  /// @HnswIndex mengaktifkan Hierarchical Navigable Small World (HNSW) index,
  /// algoritma Approximate Nearest Neighbor (ANN) yang sangat cepat.
  ///
  /// PENTING: ObjectBox @HnswIndex HANYA mendukung Float32List,
  /// bukan List<double>. Konversi dilakukan di factory fromSupabase.
  ///
  /// Konfigurasi:
  /// - dimensions: 512  → sesuai output layer terakhir MobileFaceNet (W600K)
  /// - distanceType: cosine → cocok untuk face embedding yang sudah L2-normalized
  ///   (cosine distance 0.0 = identik, 2.0 = berlawanan total)
  ///
  /// Threshold yang disarankan: distance < 0.40 → wajah sama (match ✅)
  @HnswIndex(dimensions: 512, distanceType: VectorDistanceType.cosine)
  Float32List? faceEmbedding;

  /// Timestamp sinkronisasi terakhir dari Supabase.
  /// Digunakan untuk menentukan apakah data perlu di-refresh.
  DateTime? lastSyncedAt;

  /// Flag apakah record ini aktif/valid.
  /// Set ke false jika karyawan menonaktifkan biometrik.
  bool isActive;

  KaryawanWajah({
    this.id = 0,
    required this.organizationMemberId,
    required this.organizationId,
    required this.namaLengkap,
    this.profilePhotoUrl,
    this.faceEmbedding, // Float32List?
    this.lastSyncedAt,
    this.isActive = true,
  });

  /// Factory constructor dari response Supabase.
  ///
  /// Mengexpect format JSON dari tabel `biometric_data` dengan join ke
  /// `organization_members` dan `user_profiles`.
  ///
  /// Format [template_data]: JSON string array, misal: "[0.12, -0.34, 0.56, ...]"
  factory KaryawanWajah.fromSupabase(Map<String, dynamic> json) {
    // Parse template_data dari JSON string ke Float32List
    // ObjectBox @HnswIndex WAJIB Float32List, bukan List<double>!
    Float32List? embedding;
    final templateData = json['template_data'];
    if (templateData != null) {
      try {
        Map<String, dynamic>? parsed;
        if (templateData is String) {
          try {
            final decoded = jsonDecode(templateData);
            if (decoded is Map<String, dynamic>) {
              parsed = decoded;
            }
          } catch (_) {
            // fallback
          }
        } else if (templateData is Map<String, dynamic>) {
          parsed = templateData;
        }

        List<double>? doubleList;
        if (parsed != null && parsed['embedding'] != null) {
          doubleList = (parsed['embedding'] as List)
              .map((e) => (e as num).toDouble())
              .toList();
        } else if (parsed != null && parsed['templates'] != null && (parsed['templates'] as List).isNotEmpty) {
          final firstTemplate = (parsed['templates'] as List).first;
          if (firstTemplate is Map && firstTemplate['embedding'] != null) {
            doubleList = (firstTemplate['embedding'] as List)
                .map((e) => (e as num).toDouble())
                .toList();
          }
        }

        if (doubleList != null) {
          embedding = Float32List.fromList(doubleList);
        } else if (templateData is String) {
          final cleaned = templateData
              .replaceAll('[', '')
              .replaceAll(']', '')
              .trim();
          if (cleaned.isNotEmpty) {
            final parsedList = cleaned
                .split(',')
                .map((e) => double.parse(e.trim()))
                .toList();
            embedding = Float32List.fromList(parsedList);
          }
        }
      } catch (e) {
        // Jika parse gagal, biarkan embedding null
      }
    }

    // Navigasi ke data member dan profile
    final member = json['organization_members'] as Map<String, dynamic>?;
    final profile = member?['user_profiles'] as Map<String, dynamic>?;

    // Susun nama lengkap dengan fallback
    final displayName = profile?['display_name'] as String?;
    final firstName = profile?['first_name'] as String? ?? '';
    final lastName = profile?['last_name'] as String? ?? '';
    final namaLengkap = displayName?.isNotEmpty == true
        ? displayName!
        : '$firstName $lastName'.trim();

    return KaryawanWajah(
      organizationMemberId: json['organization_member_id'] as int,
      organizationId:
          (member?['organization_id'] as int?) ??
          (json['organization_id'] as int? ?? 0),
      namaLengkap: namaLengkap.isNotEmpty ? namaLengkap : 'Unknown',
      profilePhotoUrl: profile?['profile_photo_url'] as String?,
      faceEmbedding: embedding,
      lastSyncedAt: DateTime.now(),
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  /// Konversi ke Map untuk debugging/logging.
  Map<String, dynamic> toDebugMap() {
    return {
      'id': id,
      'organizationMemberId': organizationMemberId,
      'organizationId': organizationId,
      'namaLengkap': namaLengkap,
      'hasEmbedding': faceEmbedding != null,
      'embeddingDimensions': faceEmbedding?.length ?? 0,
      'isActive': isActive,
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    };
  }

  @override
  String toString() => 'KaryawanWajah(id=$id, nama=$namaLengkap, '
      'memberId=$organizationMemberId, hasEmbedding=${faceEmbedding != null})';
}
