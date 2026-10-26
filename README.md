# Bond Touch Beyond — Android

The Android app for Bond Touch Beyond, in Flutter. The iPhone app is the native one in its own
repository.

It runs on the **original Bond Touch servers**: you sign in with your Bond Touch account, and
your partners, touches and Touch Language are the same ones the official Bond Touch apps
use. Partners on the official app, on the iPhone app, or on this one all reach each other.

## What it does

- **Account:** sign-in by email link, as in the official app. Firebase Auth project
  `bond-touch`, over REST with no Firebase SDK.
- **Partners:** invite by account email, and accept or decline invites
  (`api.bond-touch.com`, `bond/api/v4/bonds`).
- **Touches:** draw one on the touch bar or the bracelet, or send a saved touch from the
  partner's Touch Language. Received touches play on the bracelet (or vibrate the phone), and
  are acknowledged so the sender sees them delivered. The app polls every 4 s on screen and
  every 15 s in the background, as the iPhone app does. The official app gets pushes sent to
  its own app id, which no other app can receive.
- **Presence:** online status, location (when shared) and phone battery, through the same
  endpoints as the official app.
- **On this phone only:** the bracelet over Bluetooth, and stress, HRV and heart rate from
  Health Connect. The Bond Touch servers don't carry mood.

## Layout

| Path | What |
| --- | --- |
| `lib/backend/` | The Bond Touch backend client: sign-in, bonds, touches, presence. |
| `lib/bracelet/` | The bracelet's Bluetooth protocol and connection (port of `BondGATT` / `BraceletManager`). |
| `lib/services/` | Health Connect, location, notifications. |
| `lib/app/` | App state and sync. |
| `lib/ui/` | Screens. |

## Building

    flutter pub get
    flutter test
    flutter build apk --release

CI (`.github/workflows/build.yml`) does the same on every push. Every push to `main` is also
published as a GitHub Release with the APK and an `update.json`:

- Newest build: https://github.com/Coral-coder/Bond-touch-beyond-android/releases/latest/download/BondTouchBeyond.apk
- Installed copies check `releases/latest/download/update.json` on launch and whenever they come
  back to the foreground (at most hourly). When there's a newer build they download it and offer
  to install it (`lib/app/updater.dart`). Settings → App version → Check for updates does the same
  on demand. Android installs an update over the old build only when both are signed with the
  same key, so releases are signed with the shared upload key below.

### Android signing (Play Store / updates)

    keytool -genkeypair -v -storetype PKCS12 -keystore upload-keystore.p12 \
      -alias upload -keyalg RSA -keysize 2048 -validity 10000
    base64 -w0 upload-keystore.p12     # → ANDROID_KEYSTORE_BASE64

The key is the upload key shared with the other apps. Dev_deploy_setup's **Set up app repo**
copies `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD` here. To use your own key instead, generate one as above and add those
secrets yourself. Keep the keystore safe: every future update must be signed with it.
Without it, builds are signed with a throwaway debug key.
