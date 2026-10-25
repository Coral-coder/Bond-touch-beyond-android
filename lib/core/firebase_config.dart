import 'dart:io';

import 'package:firebase_core/firebase_core.dart';

/// The Firebase project this build talks to, passed in at build time
/// (`--dart-define-from-file=firebase.env.json`, written by `scripts/firebase_defines.py` from
/// the console's `google-services.json` / `GoogleService-Info.plist`). Nothing about the
/// project is in the source, so whoever builds the app brings their own.
class FirebaseConfig {
  static const _projectID = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderID = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _bucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const _androidKey = String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
  static const _androidApp = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  static const _iosKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const _iosApp = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _iosBundle = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

  /// This platform's options, or null when the build has none (then the native config file,
  /// if any, is used).
  static FirebaseOptions? get options {
    final ios = Platform.isIOS;
    final key = ios ? _iosKey : _androidKey;
    final app = ios ? _iosApp : _androidApp;
    if (_projectID.isEmpty || key.isEmpty || app.isEmpty) return null;
    return FirebaseOptions(
      apiKey: key,
      appId: app,
      messagingSenderId: _senderID,
      projectId: _projectID,
      storageBucket: _bucket.isEmpty ? null : _bucket,
      iosBundleId: ios && _iosBundle.isNotEmpty ? _iosBundle : null,
    );
  }
}
