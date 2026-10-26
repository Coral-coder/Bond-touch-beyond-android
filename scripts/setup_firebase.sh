#!/usr/bin/env bash
# Sets up Firebase for Bond Touch Beyond and puts its config into the GitHub repos as secrets.
# Everything here is on Firebase's free Spark plan: no billing account, no card.
#
#   scripts/setup_firebase.sh --new bond-touch-beyond-1234      # a new project (recommended)
#   scripts/setup_firebase.sh --project my-existing-project     # reuse a project you have
#
# Options
#   --android-repo OWNER/REPO   default Coral-coder/Bond-touch-beyond-android
#   --ios-repo OWNER/REPO       the native iPhone app, default Coral-coder/bond-touch-beyond
#   --no-secrets                only write the config files to ./firebase-config/
#
# Needs: Node (for the Firebase CLI), python3, and the GitHub CLI `gh` (logged in) for the
# secrets. Optional: gcloud, to turn on anonymous sign-in without the console.
set -euo pipefail

PROJECT="" NEW=false SECRETS=true
ANDROID_REPO="Coral-coder/Bond-touch-beyond-android"
IOS_REPO="Coral-coder/bond-touch-beyond"
ANDROID_PACKAGE="com.lightwave.beyond"
NATIVE_IOS_BUNDLE="com.lightwave.beyond"

while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=true; PROJECT="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --android-repo) ANDROID_REPO="$2"; shift 2 ;;
    --ios-repo) IOS_REPO="$2"; shift 2 ;;
    --no-secrets) SECRETS=false; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { sed -n '2,16p' "$0"; exit 1; }

cd "$(dirname "$0")/.."
FB="firebase"
command -v firebase > /dev/null || FB="npx -y firebase-tools@latest"
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "Signing in to Firebase (a browser opens the first time)"
$FB login --no-localhost 2> /dev/null || $FB login

if $NEW; then
  step "Creating project $PROJECT"
  $FB projects:create "$PROJECT" --display-name "Bond Touch Beyond"
else
  step "Using your project $PROJECT"
  cat <<'NOTE'
Heads up, reusing a project:
  * This app keeps its data in the Firestore collection "r" only; your other app's data is
    untouched.
  * Anonymous sign-in gets turned on for the whole project. If your other app's Firestore or
    Storage rules allow "any signed-in user" (request.auth != null), anonymous users could
    then reach that data. Check those rules before going on.
  * The Firestore rules are NOT deployed (that would replace your other app's rules). Paste
    the "match /r/{record}" block from firestore.rules into your existing rules instead.
  * Handing this app over later means moving it to its own project anyway.
NOTE
  read -r -p "Continue? [y/N] " ok; [ "$ok" = y ] || [ "$ok" = Y ] || exit 1
fi

step "Firestore database"
$FB firestore:databases:create "(default)" --location nam5 --project "$PROJECT" 2>&1 | tail -2 \
  || echo "(Already exists, or create it in the console: Firestore Database → Create database.)"

if $NEW; then
  step "Firestore rules"
  $FB deploy --only firestore:rules --project "$PROJECT"
fi

# Finds an app by package / bundle ID, creating it if it isn't there. Prints its app ID.
app_id() { # platform id-field id name
  local platform="$1" field="$2" id="$3" name="$4" found
  found=$($FB apps:list "$platform" --project "$PROJECT" --json 2> /dev/null | python3 -c "
import json, sys
apps = json.load(sys.stdin).get('result', [])
print(next((a['appId'] for a in apps if a.get('$field') == '$id'), ''))" || true)
  if [ -z "$found" ]; then
    if [ "$platform" = ANDROID ]; then
      found=$($FB apps:create ANDROID "$name" --package-name "$id" --project "$PROJECT" --json | json "d['result']['appId']")
    else
      found=$($FB apps:create IOS "$name" --bundle-id "$id" --project "$PROJECT" --json | json "d['result']['appId']")
    fi
  fi
  echo "$found"
}

step "Apps"
mkdir -p firebase-config
ANDROID_APP=$(app_id ANDROID packageName "$ANDROID_PACKAGE" "Bond Touch Beyond Android")
NATIVE_IOS_APP=$(app_id IOS bundleId "$NATIVE_IOS_BUNDLE" "Bond Touch Beyond iPhone")
$FB apps:sdkconfig ANDROID "$ANDROID_APP" --project "$PROJECT" --out firebase-config/google-services.json
$FB apps:sdkconfig IOS "$NATIVE_IOS_APP" --project "$PROJECT" --out firebase-config/GoogleService-Info.plist
echo "Config files are in firebase-config/ (git-ignored)."

step "Anonymous sign-in"
enabled=false
if command -v gcloud > /dev/null && token=$(gcloud auth print-access-token 2> /dev/null); then
  if curl -sf -X PATCH -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
       -H "X-Goog-User-Project: $PROJECT" \
       "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config?updateMask=signIn.anonymous.enabled" \
       -d '{"signIn":{"anonymous":{"enabled":true}}}' > /dev/null; then
    enabled=true; echo "Turned on."
  fi
fi
if ! $enabled; then
  echo "Turn it on by hand (one click):"
  echo "  https://console.firebase.google.com/project/$PROJECT/authentication/providers"
  echo "  → Get started (if shown) → Anonymous → Enable → Save"
  read -r -p "Press Enter when done. " _
fi

if $SECRETS; then
  step "GitHub secrets"
  command -v gh > /dev/null || { echo "Install the GitHub CLI (https://cli.github.com), run 'gh auth login', then re-run."; exit 1; }
  gh secret set GOOGLE_SERVICES_JSON -R "$ANDROID_REPO" < firebase-config/google-services.json
  gh secret set GOOGLE_SERVICE_INFO_PLIST -R "$IOS_REPO" < firebase-config/GoogleService-Info.plist
  echo "Set on $ANDROID_REPO and $IOS_REPO. The next build of each uses Firebase."
fi

step "Done"
echo "Project: https://console.firebase.google.com/project/$PROJECT"
