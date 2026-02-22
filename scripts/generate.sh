#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_JSON="$SCRIPT_DIR/metadata.json"
TEMPLATE_JSON="$SCRIPT_DIR/template.json"
WORKDIR=$(mktemp -d)
APPS_FULL_JSON="$WORKDIR/apps_full.json"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "[]" > "$APPS_FULL_JSON"

jq -c 'to_entries[] | select(.value | type == "object" and has("displayName"))' "$METADATA_JSON" | while read -r entry; do
  BUNDLE_ID=$(echo "$entry" | jq -r '.key')
  app_json=$(echo "$entry" | jq '.value')

  DISPLAY_NAME=$(echo "$app_json" | jq -r '.displayName // empty')
  IPA_URL=$(echo "$app_json" | jq -r '.ipaURL // empty')
  VERSION_DESCRIPTION=$(echo "$app_json" | jq -r '.versionDescription // empty')
  DATE=$(echo "$app_json" | jq -r '.date // empty')
  TINT_COLOR=$(echo "$app_json" | jq -r '.tintColor // empty')
  SUBTITLE=$(echo "$app_json" | jq -r '.subtitle // empty')
  DESCRIPTION=$(echo "$app_json" | jq -r '.appDescription // empty')
  ICON_URL=$(echo "$app_json" | jq -r '.iconURL // empty')
  SCREENSHOTS=$(echo "$app_json" | jq -c '.screenshots // []')

  echo "Processing $DISPLAY_NAME..."

  IPA_FILE="$WORKDIR/app.ipa"

  if [[ "$IPA_URL" =~ ^https?:// ]]; then
    echo "  Downloading IPA..."
    if [[ "$IPA_URL" == *"github.com"* ]]; then
      curl -H "Authorization: token $GITHUB_TOKEN" -L -o "$IPA_FILE" "$IPA_URL"
    else
      curl -L -o "$IPA_FILE" "$IPA_URL"
    fi
  else
    echo "  Copying local IPA..."
    cp "$IPA_URL" "$IPA_FILE"
  fi

  TMP_DIR=$(mktemp -d)
  unzip -q "$IPA_FILE" -d "$TMP_DIR"

  APP_PATH=$(find "$TMP_DIR/Payload" -name "*.app" -type d | head -n 1)
  INFO_PLIST="$APP_PATH/Info.plist"

  EXECUTABLE=$(defaults read "$INFO_PLIST" CFBundleExecutable 2>/dev/null || echo "")
  BUNDLE_ID=$(defaults read "$INFO_PLIST" CFBundleIdentifier 2>/dev/null || echo "")
  VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString 2>/dev/null || echo "")
  MIN_OS_VERSION=$(defaults read "$INFO_PLIST" MinimumOSVersion 2>/dev/null || echo "")

  ENTITLEMENTS_RAW=$(ldid -e "$APP_PATH/$EXECUTABLE" 2>/dev/null || echo '{}')
  ENTITLEMENTS_JSON=$(echo "$ENTITLEMENTS_RAW" | plutil -convert json -o - - 2>/dev/null || echo '{}')
  ENTITLEMENTS=$(echo "$ENTITLEMENTS_JSON" | jq 'keys' 2>/dev/null || echo '[]')

  PRIVACY=$(plutil -convert json -o - "$INFO_PLIST" 2>/dev/null \
    | jq 'to_entries | map(select(.key | test("^NS.*UsageDescription$")) | .value = (if .value == "" then "No usage description provided by app'\''s developer" else .value end)) | from_entries' \
    2>/dev/null || echo '{}')

  SIZE=$(stat -f%z "$IPA_FILE" 2>/dev/null || echo 0)

  FULL_APP_JSON=$(jq -n \
    --arg displayName "$DISPLAY_NAME" \
    --arg bundleIdentifier "$BUNDLE_ID" \
    --arg version "$VERSION" \
    --arg minOSVersion "$MIN_OS_VERSION" \
    --arg date "$DATE" \
    --argjson size "$SIZE" \
    --argjson entitlements "$ENTITLEMENTS" \
    --argjson privacy "$PRIVACY" \
    --arg versionDescription "$VERSION_DESCRIPTION" \
    --arg iconURL "$ICON_URL" \
    --arg downloadURL "$IPA_URL" \
    --arg tintColor "$TINT_COLOR" \
    --arg subtitle "$SUBTITLE" \
    --arg description "$DESCRIPTION" \
    --argjson screenshots "$SCREENSHOTS" \
    '{
      displayName: $displayName,
      bundleIdentifier: $bundleIdentifier,
      version: $version,
      minOSVersion: $minOSVersion,
      date: $date,
      size: $size,
      entitlements: $entitlements,
      privacy: $privacy,
      versionDescription: $versionDescription,
      iconURL: $iconURL,
      downloadURL: $downloadURL,
      tintColor: $tintColor,
      subtitle: $subtitle,
      description: $description,
      screenshots: $screenshots
    }') || {
    echo "  Failed to create app entry for $DISPLAY_NAME"
    rm -rf "$TMP_DIR"
    continue
  }

  jq --argjson app "$FULL_APP_JSON" '. + [$app]' "$APPS_FULL_JSON" > "$APPS_FULL_JSON.tmp" || {
    echo "  Failed to add $DISPLAY_NAME to list"
    rm -rf "$TMP_DIR"
    continue
  }
  mv "$APPS_FULL_JSON.tmp" "$APPS_FULL_JSON"

  echo "  ok $DISPLAY_NAME added successfully"
  rm -rf "$TMP_DIR"
done

echo ""
echo "Building repo.json..."

OUTPUT_JSON="$SCRIPT_DIR/../repo.json"
PRESET=$(jq '.["repo.json"]' "$TEMPLATE_JSON")

APPS_ARRAY=$(jq 'map({
  name: .displayName,
  bundleIdentifier: .bundleIdentifier,
  developerName: "miyukowo",
  subtitle: .subtitle,
  localizedDescription: .description,
  iconURL: .iconURL,
  tintColor: .tintColor,
  screenshotURLs: .screenshots,
  appPermissions: {
    entitlements: .entitlements,
    privacy: .privacy
  },
  versions: [{
    version: .version,
    minOSVersion: .minOSVersion,
    date: (.date | split("T")[0]),
    size: .size,
    downloadURL: .downloadURL,
    localizedDescription: .versionDescription
  }]
})' "$APPS_FULL_JSON")

echo "$PRESET" | jq --argjson apps "$APPS_ARRAY" '.apps = $apps' > "$OUTPUT_JSON"

echo "ok repo.json generated at $OUTPUT_JSON"
echo "DONE!"