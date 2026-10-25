# Bond Touch Beyond — Android & iOS

Bond Touch Beyond in Flutter, one codebase for Android and iPhone: your Bond Touch bracelet over Bluetooth,
touches and chat with your partners, live status and location, and stress, HRV and heart rate
from Health Connect. Partners can be on Android or iPhone.

## How partners connect

Through Firebase, end-to-end encrypted, with the same record layout and payloads as the iPhone
app's iCloud relay:

- A bond is a random 8-character **code**, shared in an invite link
  (`bondtouchbeyond://join?code=…`). It is never stored online.
- Each phone stretches the code (PBKDF2-SHA256, 210 000 rounds) and splits it (HKDF) into an
  AES-GCM key and an opaque **locator** — byte for byte the same as the iPhone app
  (`lib/core/bond_crypto.dart`, checked by `test/bond_crypto_test.dart`).
- Firestore holds one document per record in collection `r`, named `<locator>-<suffix>`,
  containing only ciphertext. The rules (`firestore.rules`) allow reading a record by exact
  name, never listing, and only the writer may change it.

## Layout

| Path | What |
| --- | --- |
| `lib/core/` | JSON in the iPhone app's format, and the bond encryption. |
| `lib/relay/` | The Firebase relay: bonds, touch & chat rings, presence, profile. |
| `lib/bracelet/` | The bracelet's Bluetooth protocol and connection (port of `BondGATT` / `BraceletManager`). |
| `lib/services/` | Health Connect, location, notifications. |
| `lib/app/` | App state and sync. |
| `l## Running it on your own accounts

Nothing in this repository depends on any particular company's servers or accounts. Whoever
builds it brings a Firebase project (free Spark plan is enough), and optionally a Google Play
upload key and an Apple developer account. All of it goes into this repo's
**Settings → Secrets and variables → Actions**; the full list is at the top of
`.github/workflows/build.yml`. Every secret is optional, so the project builds without them.

### Firebase (how partners reach each other)

**Quick way:** `scripts/setup_firebase.sh --new <project-id>` creates the project, the database,
the rules and the apps, and stores the config as GitHub secrets. Use `--project <id>` to reuse
an existing project instead (read the notes it prints). It's all on the free Spark plan.

By hand:

1. Create a Firebase project.
2. Add an **Android app** with package `com.lightwave.beyond`, and download
   `google-services.json`. Add an **iOS app** with your iOS bundle ID (default
   `com.lightwave.bondTouchBeyond`), and download `GoogleService-Info.plist`.
3. Turn on **Authentication → Sign-in method → Anonymous** and create a **Firestore**
   database.
4. Publish the rules in `firestore.rules`: paste them into Firestore → Rules, or run
   `firebase deploy --only firestore:rules`.
5. Add the two files as the secrets `GOOGLE_SERVICES_JSON` and `GOOGLE_SERVICE_INFO_PLIST`.
   Paste the whole file; base64 also works.

Firebase API keys identify the project; they are not passwords. The Firestore rules and the
end-to-end encryption are what protect the data. Even so, the files are kept as secrets
rather than committed.

### Android signing (Play Store / updates)

    keytool -genkeypair -v -storetype PKCS12 -keystore upload-keystore.p12 \
      -alias upload -keyalg RSA -keysize 2048 -validity 10000
    base64 -w0 upload-keystore.p12     # → ANDROID_KEYSTORE_BASE64

Then add `ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` (`upload`). Keep the keystore
safe: every future update must be signed with it. If you don't set it up, builds are signed
with a throwaway debug key.

### iOS signing (TestFlight / App Store)

1. Create an App Store Connect API key with the **App Manager** role (Users and Access →
   Integrations).
2. Add the secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the
   `.p8` contents).
3. Create the app in App Store Connect with your bundle ID. If it isn't
   `com.lightwave.bondTouchBeyond`, set the repository variable `IOS_BUNDLE_ID`.

Uploads to TestFlight happen only when you ask: Actions → Build → Run workflow → tick
"Upload to TestFlight". Xcode signing sets up the certificate, the
profile, and the HealthKit and Push capabilities automatically. Without these secrets, the
iOS build is unsigned and only checks that the app compiles.

## Building

CI (`.github/workflows/build.yml`) runs on every push:

1. Analyze and test.
2. Android: APK + App Bundle.
3. iOS: signed build, or unsigned without the Apple secrets.

On `main` it also publishes a GitHub Release with the APK. It never uploads to TestFlight
unless you run it by hand with that box ticked.
Public repositories get these runners free.

Locally:

    flutter pub get
    flutter test
    scripts/firebase_defines.py --android google-services.json --ios GoogleService-Info.plist > firebase.env.json
    flutter run --dart-define-from-file=firebase.env.json
