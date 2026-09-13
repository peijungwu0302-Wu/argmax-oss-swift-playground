#!/usr/bin/env bash
set -euo pipefail

# LectureTranscriber SideStore Release Pipeline
# Enforces: Real-device IPA -> Structure validation -> Release upload ->
#           Public URL reachable -> Download & re-validate -> Only then update manifests.

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.7.1"
  exit 1
fi

REPO="peijungwu0302-Wu/argmax-oss-swift-playground"
TAG="v${VERSION}"
IPA="LectureTranscriber-${TAG}.ipa"
URL="https://github.com/${REPO}/releases/download/${TAG}/${IPA}"
BUNDLE_ID="com.peijungwu0302.lecturetranscriber"

echo "=========================================="
echo "Starting SideStore Release for ${TAG}"
echo "Target: ${URL}"
echo "=========================================="

# Stage 1: Build or locate real-device universal IPA
echo "==> [1/8] Locating / building universal real-device IPA..."
if [ -f "${IPA}" ]; then
  echo "Found local ${IPA}"
elif [ -f "LectureTranscriber-v1.7.0.ipa" ] && [ "$VERSION" = "1.7.0" ]; then
  cp "LectureTranscriber-v1.7.0.ipa" "${IPA}"
elif command -v xcodebuild >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then
  echo "Building with xcodebuild for generic iOS device..."
  BUILD_DIR="$(mktemp -d -t lt-build.XXXXXX)"
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec AppBuild/project.yml
  fi
  xcodebuild -project AppBuild/LectureTranscriber.xcodeproj \
    -scheme LectureTranscriber \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${BUILD_DIR}" \
    CODE_SIGNING_ALLOWED=NO build
  python3 AppBuild/package_ipa.py "${BUILD_DIR}/Build/Products/Debug-iphoneos/LectureTranscriber.app" "${IPA}"
  rm -rf "${BUILD_DIR}"
else
  echo "❌ IPA build failed: ${IPA} not found and Xcode toolchain unavailable in this environment."
  echo "   Build the real-device universal IPA on macOS or provide ${IPA} in current directory."
  exit 1
fi
echo "✓ Version: ${VERSION}"
echo "✓ IPA built"

# Stage 2: Validate IPA structure
echo "==> [2/8] Validating IPA integrity and structure..."
if ! unzip -t "${IPA}" >/dev/null 2>&1; then
  echo "❌ Invalid IPA: zip integrity check failed"
  exit 1
fi

if ! unzip -l "${IPA}" | grep -q "Payload/.*\.app/"; then
  echo "❌ Invalid IPA: missing Payload/*.app/ bundle structure"
  exit 1
fi

IPA_SIZE=$(wc -c < "${IPA}" | tr -d ' ')
if [ "$IPA_SIZE" -lt 100000 ]; then
  echo "❌ Invalid IPA: file size too small (${IPA_SIZE} bytes)"
  exit 1
fi
echo "✓ IPA structure valid"

# Stage 3: Create or update GitHub Release
echo "==> [3/8] Preparing GitHub Release ${TAG}..."
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ GitHub CLI (gh) not found in PATH. Please install gh or run in an authenticated environment."
  exit 1
fi

if ! gh release view "${TAG}" --repo "${REPO}" >/dev/null 2>&1; then
  gh release create "${TAG}" --repo "${REPO}" --title "LectureTranscriber ${TAG}" --notes "LectureTranscriber ${TAG} release"
fi
echo "✓ GitHub Release ready"

# Stage 4: Upload IPA Release Asset
echo "==> [4/8] Uploading ${IPA} asset to GitHub Release..."
if ! gh release upload "${TAG}" "${IPA}" --repo "${REPO}" --clobber; then
  echo "❌ Release upload failed"
  exit 1
fi
echo "✓ Release asset uploaded"

# Stage 5: Verify public download URL
echo "==> [5/8] Verifying public download URL reachability..."
REACHABLE=0
for i in {1..6}; do
  if curl -fIL -s "${URL}" >/dev/null 2>&1; then
    REACHABLE=1
    break
  fi
  sleep 5
done

if [ "$REACHABLE" -ne 1 ]; then
  echo "❌ Public URL returned 404 or was unreachable: ${URL}"
  echo "❌ Manifest update aborted"
  exit 1
fi
echo "✓ Public download URL verified"

# Stage 6: Download asset and validate again
echo "==> [6/8] Re-downloading public asset to verify package integrity..."
TMP_IPA="$(mktemp -t LectureTranscriber.XXXXXX.ipa)"
if ! curl -fL -s "${URL}" -o "${TMP_IPA}"; then
  echo "❌ Downloaded asset invalid: failed to fetch ${URL}"
  rm -f "${TMP_IPA}"
  echo "❌ Manifest update aborted"
  exit 1
fi

DL_SIZE=$(wc -c < "${TMP_IPA}" | tr -d ' ')
if [ "$DL_SIZE" -lt 100000 ]; then
  echo "❌ Downloaded asset invalid: size too small (${DL_SIZE} bytes)"
  rm -f "${TMP_IPA}"
  echo "❌ Manifest update aborted"
  exit 1
fi

if ! unzip -t "${TMP_IPA}" >/dev/null 2>&1; then
  echo "❌ Downloaded asset invalid: corrupted zip file"
  rm -f "${TMP_IPA}"
  echo "❌ Manifest update aborted"
  exit 1
fi

if ! unzip -l "${TMP_IPA}" | grep -q "Payload/.*\.app/"; then
  echo "❌ Downloaded asset invalid: missing Payload/*.app/ in downloaded archive"
  rm -f "${TMP_IPA}"
  echo "❌ Manifest update aborted"
  exit 1
fi
rm -f "${TMP_IPA}"
echo "✓ Downloaded IPA verified"

# Stage 7: Update SideStore and App Update manifests
echo "==> [7/8] Updating SideStore and app update manifests..."
python3 - <<PY
import json, sys, datetime

version = "${VERSION}"
url = "${URL}"
size = int("${IPA_SIZE}")

# 1. Update Deliverables/sidestore.json
with open("Deliverables/sidestore.json", "r", encoding="utf-8") as f:
    side_data = json.load(f)

app = side_data["apps"][0]
versions = app.get("versions", [])

existing = next((v for v in versions if v.get("version") == version), None)
now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if existing:
    existing["downloadURL"] = url
    existing["size"] = size
    existing["date"] = now_iso
else:
    new_version_entry = {
        "version": version,
        "date": now_iso,
        "localizedDescription": app.get("localizedDescription", ""),
        "downloadURL": url,
        "size": size,
        "minOSVersion": "16.0"
    }
    versions.insert(0, new_version_entry)

with open("Deliverables/sidestore.json", "w", encoding="utf-8") as f:
    json.dump(side_data, f, ensure_ascii=False, indent=2)
    f.write("\n")

# 2. Update Deliverables/update.json
with open("Deliverables/update.json", "r", encoding="utf-8") as f:
    up_data = json.load(f)

up_data["version"] = version
up_data["downloadURL"] = url

with open("Deliverables/update.json", "w", encoding="utf-8") as f:
    json.dump(up_data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

# Validate JSON schema and syntax
if command -v jq >/dev/null 2>&1; then
  jq empty Deliverables/sidestore.json
  jq empty Deliverables/update.json
else
  python3 -m json.tool Deliverables/sidestore.json >/dev/null
  python3 -m json.tool Deliverables/update.json >/dev/null
fi
echo "✓ sidestore.json updated"
echo "✓ update.json updated"
echo "✓ Manifest JSON valid"

# Stage 8: Commit and push manifest updates
echo "==> [8/8] Committing and pushing manifest updates..."
git add Deliverables/sidestore.json Deliverables/update.json
if ! git diff --cached --quiet; then
  git commit -m "dist: release ${TAG} SideStore manifests"
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  git push origin "${CURRENT_BRANCH}"
  echo "✓ Changes committed"
  echo "✓ Changes pushed"
else
  echo "Manifests were already up to date."
fi

echo "✓ Release complete"