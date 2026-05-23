import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => android;

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDtZfvhn2bzNXZiFA-oQ5f5jTLFVlRnJTQ',
    appId: '1:90896881699:android:b0e131c0872616b7df7996',
    messagingSenderId: '90896881699',
    projectId: 'indirim-takip-71bc8',
    storageBucket: 'indirim-takip-71bc8.firebasestorage.app',
  );
}
