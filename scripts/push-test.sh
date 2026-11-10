#!/usr/bin/env bash
# Sends one "needs you" notification of Hirte's push contract (HerdrKit/Sources/HerdrKit/Push.swift) to a
# device token through APNs, as the sender on a machine does. For trying the app on a device; the
# sender proper reads the token files in ~/.config/hirte/push there and watches herdr-core for a
# terminal without a parent whose status becomes "blocked".
#
#   scripts/push-test.sh --token <hex> --host-id <uuid> --address t7 [--created-ms <ms>]
#       [--title "shop-api"] [--body "Run the database migration?"] [--bundle-id io.github.sa1mk0.hirte.dev]
#       [--environment development|production]
#
#   The token, host_id, bundle_id and environment are the token file's. The environment defaults to
#   development for a bundle id ending in .dev (Debug builds), production otherwise; it must match the
#   build's aps-environment, or APNs answers BadDeviceToken.
#   An APNs auth key (Apple Developer → Keys, "Apple Push Notifications service (APNs)"), from the
#   environment; never printed, never committed:
#     APNS_KEY_FILE=/path/AuthKey_ABC123DEF4.p8  APNS_KEY_ID=ABC123DEF4  APNS_TEAM_ID=G3667P8VAV
#   Needs curl with HTTP/2 and openssl (both on macOS); python3 for the JSON.
#
#   --simulator <udid|booted>: delivers the same payload to that simulator with `xcrun simctl push`
#   instead (no token, key or network): what a tap does can be tried there. The host_id is the
#   machine's UUID in the app's saved hosts; the demo machine's works, although it never gets a file.
set -euo pipefail

token="" host_id="" address="" created_ms="" title="" body="Needs your decision"
bundle_id="io.github.sa1mk0.hirte.dev" environment="" simulator=""
while [ $# -gt 0 ]; do
    case "$1" in
        --token) token="$2"; shift 2 ;;
        --host-id) host_id="$2"; shift 2 ;;
        --address) address="$2"; shift 2 ;;
        --created-ms) created_ms="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --body) body="$2"; shift 2 ;;
        --bundle-id) bundle_id="$2"; shift 2 ;;
        --environment) environment="$2"; shift 2 ;;
        --simulator) simulator="$2"; shift 2 ;;
        -h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done
[ -n "$host_id" ] && [ -n "$address" ] || { echo "--host-id and --address are required (see --help)" >&2; exit 2; }
[ -n "$title" ] || title="$address"
if [ -z "$environment" ]; then
    case "$bundle_id" in *.dev) environment=development ;; *) environment=production ;; esac
fi
case "$environment" in development | production) ;; *) echo "--environment is development or production" >&2; exit 2 ;; esac

# The payload: APNs alert with the terminal's name and what it waits for; the route for the app.
payload="$(python3 -I - "$title" "$body" "$host_id" "$address" "$created_ms" <<'EOF'
import json, sys
title, body, host_id, address, created_ms = sys.argv[1:6]
hirte = {"v": 1, "host_id": host_id, "address": address}
if created_ms:
    hirte["created_ms"] = int(created_ms)
print(json.dumps({
    "aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": host_id,
            "interruption-level": "time-sensitive"},
    "hirte": hirte,
}, separators=(",", ":")))
EOF
)"

if [ -n "$simulator" ]; then
    file="$(mktemp -t hirte-push).json"
    trap 'rm -f "$file"' EXIT
    printf '%s\n' "$payload" > "$file"
    xcrun simctl push "$simulator" "$bundle_id" "$file"
    echo "delivered to simulator $simulator: $payload"
    exit 0
fi

[ -n "$token" ] || { echo "--token is required for APNs (or use --simulator)" >&2; exit 2; }
[[ "$token" =~ ^[0-9a-f]+$ ]] || { echo "--token is the device token from the token file: lowercase hex" >&2; exit 2; }
: "${APNS_KEY_FILE:?set APNS_KEY_FILE to the .p8 auth key}" "${APNS_KEY_ID:?set APNS_KEY_ID}" "${APNS_TEAM_ID:?set APNS_TEAM_ID}"
[ -r "$APNS_KEY_FILE" ] || { echo "cannot read APNS_KEY_FILE" >&2; exit 1; }

# A provider token: ES256 JWT of {"iss": team, "iat": now}, signed with the key. OpenSSL gives a DER
# signature; APNs wants the raw 64-byte r||s.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
header="$(printf '{"alg":"ES256","kid":"%s"}' "$APNS_KEY_ID" | b64url)"
claims="$(printf '{"iss":"%s","iat":%d}' "$APNS_TEAM_ID" "$(date +%s)" | b64url)"
umask 077
work="$(mktemp -d -t hirte-push)"
trap 'rm -rf "$work"' EXIT
printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$APNS_KEY_FILE" -out "$work/sig.der"
raw=""
for part in $(openssl asn1parse -inform DER -in "$work/sig.der" | awk -F: '/INTEGER/ {print $4}'); do
    raw="$raw$(printf '%064s' "$part" | tr ' ' 0)"
done
[ ${#raw} -eq 128 ] || { echo "unexpected signature from openssl" >&2; exit 1; }
signature="$(printf '%s' "$raw" | xxd -r -p | b64url)"
# The bearer header goes to curl from a file, so the token isn't in the process list.
printf 'authorization: bearer %s.%s.%s\n' "$header" "$claims" "$signature" > "$work/auth"

host=api.push.apple.com
[ "$environment" = development ] && host=api.sandbox.push.apple.com
echo "sending to $host for $bundle_id ($environment): $payload"
status="$(curl -sS --http2 -o "$work/response" -w '%{http_code}' -H @"$work/auth" \
    -H "apns-topic: $bundle_id" -H "apns-push-type: alert" -H "apns-priority: 10" -H "apns-expiration: 0" \
    --data-binary "$payload" "https://$host/3/device/$token")"
if [ "$status" = 200 ]; then
    echo "APNs accepted it (200)"
else
    echo "APNs refused it ($status): $(cat "$work/response")" >&2
    exit 1
fi
