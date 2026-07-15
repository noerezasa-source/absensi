import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../objectbox.g.dart';
import '../models/karyawan_wajah.dart';

class ObjectBoxService {
  static final ObjectBoxService _instance = ObjectBoxService._internal();
  factory ObjectBoxService() => _instance;
  ObjectBoxService._internal();

  Store? _store;
  Box<KaryawanWajah>? _box;

  Store get store {
    if (_store == null) {
      throw StateError('ObjectBox Store has not been initialized. Call init() first.');
    }
    return _store!;
  }

  Box<KaryawanWajah> get box => _box ??= store.box<KaryawanWajah>();

  bool get isInitialized => _store != null;

  /// Inisialisasi ObjectBox Store secara asinkron.
  Future<void> init() async {
    if (_store != null) return;

    try {
      debugPrint('📦 ObjectBox: Memulai inisialisasi database...');
      final docsDir = await getApplicationDocumentsDirectory();
      final storeDir = Directory(p.join(docsDir.path, 'objectbox'));
      
      if (!await storeDir.exists()) {
        await storeDir.create(recursive: true);
      }

      _store = await openStore(directory: storeDir.path);
      _box = _store!.box<KaryawanWajah>();
      
      final count = _box!.count();
      debugPrint('✅ ObjectBox: Berhasil diinisialisasi. Jumlah data wajah terdaftar: $count');
    } catch (e, stack) {
      debugPrint('❌ ObjectBox: Gagal melakukan inisialisasi store: $e\n$stack');
      rethrow;
    }
  }

  /// Simpan atau update satu face embedding karyawan ke ObjectBox.
  void putKaryawanWajah(KaryawanWajah karyawan) {
    // Pastikan jika data dengan memberId yang sama sudah ada, kita replace/update
    final existing = findByMemberId(karyawan.organizationMemberId);
    if (existing != null) {
      karyawan.id = existing.id;
    }
    box.put(karyawan);
  }

  /// Simpan banyak data sekaligus dalam satu transaksi ObjectBox.
  void putAllKaryawanWajah(List<KaryawanWajah> list) {
    store.runInTransaction(TxMode.write, () {
      for (final kw in list) {
        putKaryawanWajah(kw);
      }
    });
  }

  /// Cari data wajah berdasarkan organizationMemberId.
  KaryawanWajah? findByMemberId(int memberId) {
    final query = box.query(KaryawanWajah_.organizationMemberId.equals(memberId)).build();
    final result = query.findFirst();
    query.close();
    return result;
  }

  /// Cari semua data wajah aktif dalam satu organisasi.
  List<KaryawanWajah> getActiveFacesForOrganization(int orgId) {
    final query = box
        .query(KaryawanWajah_.organizationId.equals(orgId)
            .and(KaryawanWajah_.isActive.equals(true)))
        .build();
    final results = query.find();
    query.close();
    return results;
  }

  /// Sinkronisasi penuh dari Supabase/SQLite: Hapus data organisasi lama di ObjectBox, masukkan yang baru.
  void syncOrganizationFaces(int orgId, List<KaryawanWajah> newList) {
    store.runInTransaction(TxMode.write, () {
      // Hapus data lama organisasi ini
      final oldQuery = box.query(KaryawanWajah_.organizationId.equals(orgId)).build();
      oldQuery.remove();
      oldQuery.close();

      // Masukkan yang baru
      box.putMany(newList);
      debugPrint('🔄 ObjectBox: Sinkronisasi wajah untuk Org $orgId selesai. Total: ${newList.length} wajah.');
    });
  }

  /// Hapus data wajah berdasarkan organizationMemberId.
  bool deleteByMemberId(int memberId) {
    return store.runInTransaction(TxMode.write, () {
      final query = box.query(KaryawanWajah_.organizationMemberId.equals(memberId)).build();
      final removedCount = query.remove();
      query.close();
      debugPrint('🗑️ ObjectBox: Menghapus data biometrik untuk Member ID $memberId. Terhapus: $removedCount');
      return removedCount > 0;
    });
  }

  /// Hapus seluruh data wajah di ObjectBox (misalnya saat logout total / clear cache).
  void clearAllData() {
    box.removeAll();
    debugPrint('🗑️ ObjectBox: Seluruh data wajah dihapus dari penyimpanan lokal.');
  }

  /// ✅ DIAGNOSTIC: Dump all registered faces with their member IDs and names.
  /// Useful for debugging identity swap issues.
  void dumpAllRegisteredFaces() {
    final all = box.getAll();
    debugPrint('📋 ═══ ObjectBox Face Registry Dump ═══');
    debugPrint('📋 Total registered faces: ${all.length}');
    for (final kw in all) {
      debugPrint('  👤 OBX_ID: ${kw.id} | '
          'MemberID: ${kw.organizationMemberId} | '
          'OrgID: ${kw.organizationId} | '
          'Name: ${kw.namaLengkap} | '
          'HasEmbedding: ${kw.faceEmbedding != null} | '
          'Active: ${kw.isActive}');
    }
    debugPrint('═══════════════════════════════════════');
  }

  /// ✅ PURGE: Remove all faces for a specific organization, then re-sync.
  /// Use this after fixing identity swap issues to force a clean re-registration.
  int purgeForOrganization(int orgId) {
    final query = box.query(KaryawanWajah_.organizationId.equals(orgId)).build();
    final removed = query.remove();
    query.close();
    debugPrint('🗑️ ObjectBox: Purged $removed faces for org $orgId');
    return removed;
  }

  /// Melakukan Approximate Nearest Neighbor (ANN) search menggunakan HNSW Vector Index ObjectBox.
  /// Sangat cepat (<1ms) dan hemat memori.
  List<ObjectWithScore<KaryawanWajah>> searchNearestNeighbors(
    List<double> queryVector, {
    int maxResultCount = 3,
    int? organizationId,
  }) {
    if (queryVector.length != 512) {
      debugPrint('⚠️ ObjectBox Search: Dimensi query vector tidak cocok (${queryVector.length} vs 512)');
      return [];
    }

    // 1. Definisikan kondisi Vector Search menggunakan HNSW index
    final vectorCond = KaryawanWajah_.faceEmbedding.nearestNeighborsF32(
      queryVector,
      maxResultCount,
    );

    // 2. Terapkan filter organisasi & status aktif jika ada (Hybrid Search)
    Condition<KaryawanWajah> queryCond;
    if (organizationId != null) {
      queryCond = vectorCond.and(
        KaryawanWajah_.organizationId.equals(organizationId).and(
          KaryawanWajah_.isActive.equals(true),
        ),
      );
    } else {
      queryCond = vectorCond.and(
        KaryawanWajah_.isActive.equals(true),
      );
    }

    // 3. Bangun query dan execute findWithScores
    final query = box.query(queryCond).build();
    final results = query.findWithScores();
    query.close();
    
    return results;
  }

  /// Bersihkan / tutup store.
  void dispose() {
    _store?.close();
    _store = null;
    _box = null;
    debugPrint('🔴 ObjectBox Service Disposed.');
  }
}
