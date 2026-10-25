#!/usr/bin/env python3
"""Turns Firebase console config files into build defines for the app.

    scripts/firebase_defines.py [--android google-services.json] [--ios GoogleService-Info.plist] \
        [--package com.lightwave.beyond] > firebase.env.json
    flutter build apk --dart-define-from-file=firebase.env.json

Either file may be left out; the app then has Firebase on the other platform only.
"""
import argparse
import json
import plistlib
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--android")
ap.add_argument("--ios")
ap.add_argument("--package", default="com.lightwave.beyond", help="Android applicationId")
args = ap.parse_args()

out = {}
if args.android:
    with open(args.android) as f:
        g = json.load(f)
    clients = g.get("client", [])
    client = next((c for c in clients
                   if c.get("client_info", {}).get("android_client_info", {}).get("package_name") == args.package),
                  clients[0] if clients else None)
    if client is None:
        sys.exit("google-services.json has no Android app")
    info = g["project_info"]
    out.update({
        "FIREBASE_PROJECT_ID": info["project_id"],
        "FIREBASE_SENDER_ID": info.get("project_number", ""),
        "FIREBASE_STORAGE_BUCKET": info.get("storage_bucket", ""),
        "FIREBASE_ANDROID_API_KEY": client["api_key"][0]["current_key"],
        "FIREBASE_ANDROID_APP_ID": client["client_info"]["mobilesdk_app_id"],
    })
if args.ios:
    with open(args.ios, "rb") as f:
        p = plistlib.load(f)
    out.setdefault("FIREBASE_PROJECT_ID", p["PROJECT_ID"])
    out.setdefault("FIREBASE_SENDER_ID", p.get("GCM_SENDER_ID", ""))
    out.setdefault("FIREBASE_STORAGE_BUCKET", p.get("STORAGE_BUCKET", ""))
    out.update({
        "FIREBASE_IOS_API_KEY": p["API_KEY"],
        "FIREBASE_IOS_APP_ID": p["GOOGLE_APP_ID"],
        "FIREBASE_IOS_BUNDLE_ID": p.get("BUNDLE_ID", ""),
    })
json.dump(out, sys.stdout, indent=2)
print()
