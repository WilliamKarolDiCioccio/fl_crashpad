#!/bin/sh
# Embeds crashpad_handler in this pod's framework, from the same place the
# Dart build hook takes the library: $FL_CRASHPAD_ARTIFACTS_DIR if set, else
# the per-user cache, else a download verified against the lock. Run by the
# script phase in fl_crashpad.podspec.
#
# It fetches for itself rather than waiting for the hook, because Xcode
# orders nothing between building the pods and Flutter's own assemble step.
# The cache layout and the atomic download match
# lib/src/build/native_artifacts.dart, which is the reference.
set -eu

fail() {
  echo "error: fl_crashpad: $*" >&2
  exit 1
}

lock="${PODS_TARGET_SRCROOT}/../native/artifacts.lock.txt"
value() { awk -v key="$1" '$1 == key { print $2 }' "$lock"; }
version=$(value artifacts)
base_url=$(value baseUrl)
sha256=$(value macos-universal)

if [ -n "${FL_CRASHPAD_ARTIFACTS_DIR:-}" ]; then
  source_dir="$FL_CRASHPAD_ARTIFACTS_DIR"
else
  cache="$HOME/Library/Caches/fl_crashpad/$version"
  source_dir="$cache/macos-universal"
  if [ ! -f "$source_dir/.complete" ]; then
    if [ "$sha256" = "-" ]; then
      fail "no macos-universal build of native $version has been published" \
        "yet. Build it from source with 'dart run tool/build_native.dart" \
        "--install' in the fl_crashpad package, or set FL_CRASHPAD_ARTIFACTS_DIR."
    fi
    mkdir -p "$cache"
    staging=$(mktemp -d "$cache/.macos-universal-pod-XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    archive="fl_crashpad-native-$version-macos-universal.tar.gz"
    curl --fail --silent --show-error --location \
      "$base_url$archive" --output "$staging/$archive" ||
      fail "downloading $archive failed"
    echo "$sha256  $staging/$archive" | shasum -a 256 -c - >/dev/null ||
      fail "$archive does not match the sha256 in the lock; nothing was unpacked"
    tar -xzf "$staging/$archive" -C "$staging"
    rm "$staging/$archive"
    echo "$sha256" > "$staging/.complete"
    if [ ! -f "$source_dir/.complete" ]; then
      rm -rf "$source_dir"
      # Another build may win this race; its copy is as good as ours.
      mv "$staging" "$source_dir" 2>/dev/null || true
    fi
  fi
fi

handler="$source_dir/bin/crashpad_handler"
[ -f "$handler" ] || fail "there is no crashpad_handler at $handler"

if [ "${WRAPPER_EXTENSION:-}" != "framework" ]; then
  fail "this pod is being built as a static library, so there is no" \
    "framework to embed crashpad_handler in. fl_crashpad needs the Podfile's" \
    "default 'use_frameworks!', without ':linkage => :static'."
fi

helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
cp -f "$handler" "$helpers/crashpad_handler"
if [ -f "$source_dir/bin/crashpad_handler.rev" ]; then
  cp -f "$source_dir/bin/crashpad_handler.rev" "$helpers/crashpad_handler.rev"
fi
chmod 755 "$helpers/crashpad_handler"
ln -sfh "Versions/Current/Helpers" "$TARGET_BUILD_DIR/$WRAPPER_NAME/Helpers"

# Ad hoc, so that the framework's own signature — applied when the app embeds
# it — seals a helper that is already signed. A Developer ID build re-signs
# it first; the README has the order.
codesign --force --sign - --options runtime --timestamp=none \
  "$helpers/crashpad_handler"
