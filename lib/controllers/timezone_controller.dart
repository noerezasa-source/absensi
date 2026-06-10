import 'package:get/get.dart';
import '../services/timezone_service.dart';

class TimezoneController extends GetxController {
  final RxString currentTimezone = 'Asia/Jakarta'.obs;
  final RxBool autoDetect = true.obs;
  final Rx<DateTime?> currentTime = Rx<DateTime?>(null);

  final TimezoneService _service = TimezoneService();

  @override
  void onInit() {
    super.onInit();
    loadSettings();
  }

  Future<void> loadSettings() async {
    currentTimezone.value = await _service.getSelectedTimezone();
    autoDetect.value = await _service.isAutoDetectEnabled();
  }

  Future<void> setTimezone(String timezone) async {
    currentTimezone.value = timezone;
    await _service.setSelectedTimezone(timezone);
  }

  Future<void> setAutoDetect(bool value) async {
    autoDetect.value = value;
    await _service.setAutoDetectEnabled(value);
  }

  Future<void> updateCurrentTime() async {
    currentTime.value = await _service.getCurrentTimeInTimezone();
  }

  String getTimezoneDisplay() {
    final info = TimezoneService.getTimezoneInfo(currentTimezone.value);
    if (info != null) {
      return '${info['display']} (${info['gmt']})';
    }
    return currentTimezone.value;
  }

  String getGMTOffset() {
    final info = TimezoneService.getTimezoneInfo(currentTimezone.value);
    return info?['gmt'] ?? 'GMT+7';
  }
}
