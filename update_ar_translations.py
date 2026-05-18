import json
import os

ARABIC_TRANSLATIONS = {
    # auth.json & common.json
    "agree_terms": "أوافق على الشروط والأحكام",
    "create_account_title": "إنشاء حساب",
    "email_address": "عنوان البريد الإلكتروني",
    "email_hint_signup": "أدخل البريد الإلكتروني الخاص بك",
    "full_name": "الاسم الكامل",
    "join_org_already_joined": "لقد انضممت بالفعل إلى هذه المنظمة",
    "join_org_already_member": "أنت بالفعل عضو في {org}",
    "join_org_button": "الانضمام للمنظمة",
    "join_org_button_short": "انضمام",
    "join_org_cancel": "إلغاء",
    "join_org_continue": "متابعة",
    "join_org_dashboard_todo": "لم يتم إنشاء لوحة القيادة الرئيسية",
    "join_org_enter_code": "يرجى إدخال رمز الدعوة",
    "join_org_error": "فشل في الانضمام إلى المنظمة",
    "join_org_info": "اسأل قسم الموارد البشرية أو مسؤول المنظمة عن رمز الدعوة",
    "join_org_input_hint": "أدخل الرمز",
    "join_org_invalid_code": "رمز الدعوة غير صالح",
    "join_org_logout": "تسجيل الخروج",
    "join_org_logout_failed": "فشل تسجيل الخروج",
    "join_org_logout_message": "هل أنت متأكد أنك تريد تسجيل الخروج؟",
    "join_org_logout_title": "تأكيد تسجيل الخروج",
    "join_org_not_authenticated": "المستخدم غير مصادق",
    "join_org_success_message": "لقد انضممت بنجاح إلى\n{org}",
    "join_org_success_title": "تم الانضمام بنجاح",
    "join_org_welcome": "مرحباً",
    "login": "تسجيل الدخول",
    "password": "كلمة المرور",
    "password_hint_signup": "إنشاء كلمة مرور",
    "sign_in_with_google": "تسجيل الدخول باستخدام جوجل",
    "sign_up": "إنشاء حساب",
    "welcome": "مرحباً",
    "welcome_back": "مرحباً بعودتك",
    
    # device_selection.json
    "accuracy": "الدقة",
    "away": "بعيد",
    "confirm_use_location": "تأكيد واستخدام الموقع",
    "current_location_header": "الموقع الحالي",
    "distance_from_target": "المسافة من الهدف",
    "live_location": "الموقع المباشر",
    "nearby_header": "الوجهات القريبة",
    "no_locations_available": "لا توجد مواقع متاحة",
    "no_locations_found": "لم يتم العثور على مواقع",
    "no_shift_selected": "الرجاء اختيار وردية العمل أولاً",
    "out_of_range": "خارج النطاق",
    "radius": "نصف القطر",
    "search_placeholder": "البحث عن المواقع...",
    "select_shift_prompt": "اختيار الوردية",
    "shift_header": "وردية العمل",
    "shift_picker_subtitle": "ضبط الوردية مع جدول عملك الحالي",
    "title": "اختيار الموقع",
    "verification_subtitle": "تأكد من صحة موقعك",
    "verification_title": "التحقق من الموقع",
    "within_range": "ضمن النطاق",

    # face.json
    "attendance_data": "بيانات الحضور",
    "break_in": "بداية الاستراحة",
    "break_out": "نهاية الاستراحة",
    "camera_error": "خطأ في الكاميرا",
    "cancel": "إلغاء",
    "checking": "جاري التحقق...",
    "done": "تم",
    "error": "خطأ",
    "exit": "خروج",
    "exit_content": "هل أنت متأكد أنك تريد الخروج من وضع الحضور؟",
    "exit_title": "خروج؟",
    "face_recognized": "تم التعرف على الوجه",
    "failed_init": "فشل التهيئة",
    "in": "دخول",
    "keluar": "خروج",
    "manual_error": "خطأ: لم يتم العثور على جلسة المسؤول",
    "manual_success": "تم الحضور اليدوي بنجاح",
    "masuk": "دخول",
    "no_data": "لا توجد بيانات حضور",
    "out": "خروج",
    "out_of_range": "خارج النطاق",
    "session_count": "عدد الجلسات",
    "start_instruction": "وجه الكاميرا إلى وجهك للبدء",
    "title": "حضور الوجه",
    "unknown": "غير معروف",
    "welcome": "مرحباً",
    "within_range": "ضمن النطاق",

    # fingerprint.json & rfid.json & selfie.json (common ones in attendance)
    "activate_now": "تفعيل الآن",
    "already_attended": "تم الحضور مسبقاً",
    "already_enrolled": "تم تسجيل البصمة مسبقاً",
    "begin_scan": "بدء المسح",
    "belum_ada_mode": "لا يتوفر وضع وردية حتى الآن",
    "berhasil_selesai": "تم التسجيل بنجاح!",
    "break_in": "بدء الاستراحة",
    "break_out": "نهاية الاستراحة",
    "close": "إغلاق",
    "failed_count": "فشل",
    "failed_to_start": "فشل في بدء تشغيل الماسح الضوئي",
    "finger_not_registered": "البصمة غير مسجلة في هذه المنظمة",
    "gagal_memuat_mode": "فشل في تحميل الوضع",
    "later": "فيما بعد",
    "lift_finger": "ارفع إصبعك قليلاً...",
    "manual_check": "فحص يدوي",
    "member": "عضو",
    "minutes": "دقائق",
    "no_data_today": "لا توجد بيانات حضور اليوم",
    "no_database": "لا توجد قاعدة بيانات للبصمات",
    "not_same_finger": "فشل: يجب استخدام نفس الإصبع!",
    "offline_mode": "وضع عدم الاتصال",
    "otg_description": "تتطلب الميزة اتصال OTG نشط. يرجى تفعيل OTG في إعدادات جهازك.",
    "otg_title": "إذن تفعيل OTG",
    "out": "خروج",
    "pending_sync": "في انتظار المزامنة",
    "pilih_mode_shift": "اختر وضع الوردية",
    "place_finger": "ضع إصبعك على الماسح",
    "processing": "جاري المعالجة...",
    "registration_failed": "فشل التسجيل. حاول مرة أخرى.",
    "registration_title": "تسجيل البصمة",
    "saving": "جاري حفظ البصمة...",
    "scan_failed": "فشل التحقق",
    "scan_success": "تم التحقق بنجاح",
    "scanner_not_found": "لم يتم العثور على ماسح ضوئي",
    "select_shift": "اختيار الوردية",
    "shift": "وردية",
    "start_sync": "بدء المزامنة",
    "step_1": "ضع إصبعك (الخطوة 1 من 3)",
    "step_2": "ضع نفس الإصبع (الخطوة 2 من 3)",
    "step_3": "ضع الإصبع مرة أخرى (الخطوة 3 من 3)",
    "step_from": "من 3",
    "step_label": "خطوة",
    "success_count": "ناجح",
    "success_prefix": "نجاح",
    "sync_title": "مزامنة البيانات",
    "system_error": "حدث خطأ في النظام",
    "tap_finger": "ضع إصبعك على الماسح",
    "tap_shift": "اضغط لاختيار الوردية",
    "total_pending": "إجمالي المعلق",
    "try_again_in": "حاول مرة أخرى بعد",
    "usb_permission_denied": "تم رفض إذن الوصول إلى USB",
    "tap_rfid": "مرر بطاقة RFID",
    "card_not_registered": "البطاقة غير مسجلة في هذه المنظمة",
    
    # selfie
    "action": "اختر إجراء",
    "attendance_success": "تم الحضور بنجاح!",
    "back": "رجوع",
    "current_location": "الموقع الحالي",
    "failed_init_camera": "فشل تجهيز الكاميرا",
    "initializing_camera": "تجهيز الكاميرا...",
    "loading_more": "تحميل المزيد...",
    "location": "الموقع",
    "next": "التالي",
    "no_cameras": "لا توجد كاميرا متاحة",
    "no_members": "لم يتم العثور على أعضاء",
    "no_members_match": "لا يوجد أعضاء يطابقون \"{query}\"",
    "non_scheduled": "خارج الجدول المجدول",
    "preparing": "تجهيز الحضور...",
    "review_submit": "مراجعة وإرسال",
    "search_member": "ابحث عن عضو بالاسم",
    "select_location": "اختيار الموقع",
    "select_member": "اختيار العضو",
    "step_x_of_y": "الخطوة {current} من {total}",
    "submit": "إرسال الحضور",
    "submitting": "جاري الإرسال...",
    "take_selfie": "التقاط صورة ذاتية (Selfie)",
    "time": "الوقت",
    "unknown_location": "موقع غير معروف",

    # Petugas dashboard
    "recent_activity": "النشاط الأخير",
    "selfie_gps": "سيلفي & GPS",
    "switch_organization": "تبديل المنظمة",
    "this_week": "هذا الأسبوع",
    "today_attendance": "حضور اليوم",
    "total_hours": "إجمالي الساعات",
    "weekly_overview": "نظرة عامة أسبوعية",
    
    # Petugas members
    "active_members": "الأعضاء النشطين",
    "attendance": "الحضور",
    "back_to_profile": "العودة للملف الشخصي",
    "break_end": "نهاية الاستراحة",
    "break_start": "بداية الاستراحة",
    "card_already_registered_other": "البطاقة مسجلة لعضو آخر",
    "card_id_detected": "تم كشف معرف البطاقة",
    "check_in": "تسجيل الدخول",
    "check_out": "تسجيل الخروج",
    "choose_registration_method": "اختر طريقة التسجيل",
    "department": "القسم",
    "employee_id": "معرف الموظف",
    "enter_page_number": "أدخل رقم الصفحة",
    "example_page": "مثال: 1, 2, 3",
    "face_not_registered_yet": "لم يتم تسجيل الوجه بعد",
    "face_registration": "تسجيل الوجه",
    "invalid_page_number": "رقم صفحة غير صالح",
    "live": "مباشر",
    "manage": "إدارة",
    "members": "الأعضاء",
    "no_activities_today": "لا توجد أنشطة اليوم",
    "no_department": "لا يوجد قسم",
    "no_members_available": "لا يوجد أعضاء متاحين",
    "no_members_found": "لم يتم العثور على أعضاء",
    "on_time_attendance": "حضور في الوقت المحدد",
    "overview": "نظرة عامة",
    "punctuality_rate": "معدل الانضباط",
    "register_face_for_attendance": "تسجيل الوجه للحضور",
    "register_face_id": "تسجيل معرف الوجه",
    "register_rfid_card": "تسجيل بطاقة RFID",
    "rfid_card_registered_success": "تم تسجيل بطاقة RFID بنجاح",
    "rfid_registration": "تسجيل RFID",
    "save_rfid_card": "حفظ بطاقة RFID",
    "scan_rfid_card": "امسح بطاقة RFID",
    "search": "بحث",
    "searching": "جاري البحث...",
    "tap_card_to_scan": "المس البطاقة للقراءة",
    "total_members": "إجمالي الأعضاء",
    "via": "عبر",
    "view_all": "عرض الكل",
    "waiting_for_card": "بانتظار البطاقة..."
}

def update_ar_files():
    base_dir = 'assets/Lang'
    id_dir = os.path.join(base_dir, 'id', 'json')
    ar_dir = os.path.join(base_dir, 'ar', 'json')
    
    for root, _, files in os.walk(id_dir):
        for f in files:
            if not f.endswith('.json'):
                continue
            
            id_path = os.path.join(root, f)
            rel_path = os.path.relpath(id_path, id_dir)
            ar_path = os.path.join(ar_dir, rel_path)
            
            if not os.path.exists(ar_path):
                # if file doesn't exist in ar, create it
                os.makedirs(os.path.dirname(ar_path), exist_ok=True)
                with open(ar_path, 'w', encoding='utf-8') as out_f:
                    out_f.write('{}')
            
            try:
                with open(id_path, 'r', encoding='utf-8') as in_f:
                    id_data = json.load(in_f)
            except:
                continue
                
            try:
                with open(ar_path, 'r', encoding='utf-8') as in_f:
                    ar_data = json.load(in_f)
            except:
                ar_data = {}
                
            updated = False
            for k, v in id_data.items():
                if k not in ar_data:
                    ar_data[k] = ARABIC_TRANSLATIONS.get(k, v + " [AR]") # Add [AR] if fallback to ID
                    updated = True
            
            if updated:
                with open(ar_path, 'w', encoding='utf-8') as out_f:
                    json.dump(ar_data, out_f, ensure_ascii=False, indent=4)
                print(f"Updated {ar_path}")

update_ar_files()
