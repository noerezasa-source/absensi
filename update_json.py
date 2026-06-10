import json

files = {
    'id': 'assets/Lang/id/json/attendance/face_registration.json',
    'en': 'assets/Lang/en/json/attendance/face_registration.json',
    'ar': 'assets/Lang/ar/json/attendance/face_registration.json'
}

new_keys = {
    'id': {
        "loading_model": "Memuat model...",
        "model_ready": "Model siap",
        "model_failed": "Inisialisasi model gagal",
        "starting_camera": "Memulai kamera...",
        "step1_title": "Tahap 1: Wajah Depan",
        "step2_title": "Tahap 2: Samping Kiri",
        "step3_title": "Tahap 3: Samping Kanan",
        "look_straight_ui": "Lihat Lurus ke Kamera",
        "processing": "Memproses...",
        "turn_left_ui": "← Toleh ke KIRI",
        "turn_right_ui": "Toleh ke KANAN →",
        "wrong_direction_right": "Salah Arah! Toleh KANAN →",
        "wrong_direction_left": "Salah Arah! Toleh KIRI ←",
        "tilt_head_ui": "Terlalu miring! Kembali sedikit",
        "perfect_hold": "Sempurna, Tahan!",
        "success_angle": "Sudut berhasil!",
        "quality_low_ui": "Kualitas rendah. Silakan ulangi dengan cahaya lebih baik.",
        "saving_db": "Menyimpan ke Database...",
        "reg_complete": "Registrasi Selesai!",
        "reg_desc": "Akurasi pengenalan wajah kini lebih tinggi dengan multi-angle.",
        "save_failed": "Gagal menyimpan",
        "face_not_found_ui": "Arahkan wajah ke kamera",
        "hold_position_ui": "Tahan posisi...",
        "capturing_ui": "Mengambil foto...",
        "saving_data": "Menyimpan Data...",
        "done_saving": "Selesai! Menyimpan..."
    },
    'en': {
        "loading_model": "Loading model...",
        "model_ready": "Model ready",
        "model_failed": "Model initialization failed",
        "starting_camera": "Starting camera...",
        "step1_title": "Step 1: Front Face",
        "step2_title": "Step 2: Left Side",
        "step3_title": "Step 3: Right Side",
        "look_straight_ui": "Look Straight at Camera",
        "processing": "Processing...",
        "turn_left_ui": "← Turn LEFT",
        "turn_right_ui": "Turn RIGHT →",
        "wrong_direction_right": "Wrong Direction! Turn RIGHT →",
        "wrong_direction_left": "Wrong Direction! Turn LEFT ←",
        "tilt_head_ui": "Too tilted! Adjust your head",
        "perfect_hold": "Perfect, Hold!",
        "success_angle": "Angle successful!",
        "quality_low_ui": "Low quality. Please retry with better lighting.",
        "saving_db": "Saving to Database...",
        "reg_complete": "Registration Complete!",
        "reg_desc": "Face recognition accuracy is now higher with multi-angle.",
        "save_failed": "Failed to save",
        "face_not_found_ui": "Point your face to the camera",
        "hold_position_ui": "Hold position...",
        "capturing_ui": "Taking photo...",
        "saving_data": "Saving Data...",
        "done_saving": "Done! Saving..."
    },
    'ar': {
        "loading_model": "جاري تحميل النموذج...",
        "model_ready": "النموذج جاهز",
        "model_failed": "فشل تهيئة النموذج",
        "starting_camera": "جاري تشغيل الكاميرا...",
        "step1_title": "الخطوة 1: الوجه الأمامي",
        "step2_title": "الخطوة 2: الجانب الأيسر",
        "step3_title": "الخطوة 3: الجانب الأيمن",
        "look_straight_ui": "انظر مباشرة إلى الكاميرا",
        "processing": "جاري المعالجة...",
        "turn_left_ui": "← أدر رأسك لليسار",
        "turn_right_ui": "أدر رأسك لليمين →",
        "wrong_direction_right": "اتجاه خاطئ! أدر رأسك لليمين →",
        "wrong_direction_left": "اتجاه خاطئ! أدر رأسك لليسار ←",
        "tilt_head_ui": "مائل جداً! ارفع رأسك قليلاً",
        "perfect_hold": "ممتاز، اثبت!",
        "success_angle": "نجحت الزاوية!",
        "quality_low_ui": "جودة منخفضة. يرجى إعادة المحاولة بإضاءة أفضل.",
        "saving_db": "جاري الحفظ في قاعدة البيانات...",
        "reg_complete": "اكتمل التسجيل!",
        "reg_desc": "دقة التعرف على الوجه أصبحت أعلى الآن بفضل الزوايا المتعددة.",
        "save_failed": "فشل الحفظ",
        "face_not_found_ui": "وجه وجهك نحو الكاميرا",
        "hold_position_ui": "ثبّت وضعك...",
        "capturing_ui": "جاري التقاط الصورة...",
        "saving_data": "جاري حفظ البيانات...",
        "done_saving": "اكتمل! جاري الحفظ..."
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

