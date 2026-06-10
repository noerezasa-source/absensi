import json

files = {
    'id': 'assets/Lang/id/json/attendance/face.json',
    'en': 'assets/Lang/en/json/attendance/face.json',
    'ar': 'assets/Lang/ar/json/attendance/face.json'
}

new_keys = {
    'id': {
        "init_failed": "Gagal inisialisasi sistem: ",
        "refreshing_faces": "Menyegarkan data wajah...",
        "refresh_success": "Data wajah berhasil diperbarui!",
        "refresh_failed": "Gagal memperbarui data wajah"
    },
    'en': {
        "init_failed": "System initialization failed: ",
        "refreshing_faces": "Refreshing face data...",
        "refresh_success": "Face data updated successfully!",
        "refresh_failed": "Failed to update face data"
    },
    'ar': {
        "init_failed": "فشل تهيئة النظام: ",
        "refreshing_faces": "جاري تحديث بيانات الوجه...",
        "refresh_success": "تم تحديث بيانات الوجه بنجاح!",
        "refresh_failed": "فشل تحديث بيانات الوجه"
    }
}

for lang, filepath in files.items():
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    
    data.update(new_keys[lang])
    
    with open(filepath, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)

