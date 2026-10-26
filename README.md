# Bond Touch Beyond — Android

The Android app for Bond Touch Beyond, in Flutter (the iPhone app is the native one in its own
repository): your Bond Touch bracelet over Bluetooth,
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
upload key. All of it goes into this repo's
**Settings → Secrets and variables → Actions**; the full list is at the top of
`.github/workflows/build.yml`. Every secret is optional, so the project builds without them.

### Firebase (how partners reach each other)

**Quick way:** `scripts/setup_firebase.sh --new <project-id>` creates the project, the database,
the rules and the apps, and stores the config as GitHub secrets. Use `--project <id>` to reuse
an existing project instead (read the notes it prints). It's all on the free Spark plan.

By hand:

1. Create a Firebase project.
2. Add an **Android app** with package `com.lightwave.beyond`, and download
   `google-services.json`. Add an **iOS app** `com.lightwave.beyond` for the iPhone app, and
   download `GoogleService-Info.plist`.
3. Turn on **Authentication → Sign-in method → Anonymous** and create a **Firestore**
   database.
4. Publish the rules in `firestore.rules`: paste them into Firestore → Rules, or run
   `firebase deploy --only firestore:rules`.
5. Add `google-services.json` here as the secret `GOOGLE_SERVICES_JSON`, and
   `GoogleService-Info.plist` to the iPhone app's repository as `GOOGLE_SERVICE_INFO_PLIST`.
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


## Building

CI (`.github/workflows/build.yml`) runs on every push:

1. Analyze and test.
2. Android: APK + App Bundle.

On `main` it also publishes a GitHub Release with the APK.
Public repositories get these runners free.

Locally:

    flutter pub get
    flutter test
    scripts/firebase_defines.py --android google-services.json > firebase.env.json
    flutter run --dart-define-from-file=firebase.env.json
