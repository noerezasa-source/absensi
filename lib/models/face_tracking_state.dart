// lib/models/face_tracking_state.dart

/// State machine untuk reliable face recognition dengan passive anti-spoofing.
enum FaceTrackingState {
  idle,             // Wajah baru terdeteksi, belum ada proses
  livenessCheck,    // Mengumpulkan sinyal passive liveness (blink / approach)
  livenessRejected, // Liveness timeout — wajah tidak terkonfirmasi sebagai nyata
  locked,           // Liveness PASS — siap inference
  cooldown,         // Menunggu sebelum re-recognition
}
