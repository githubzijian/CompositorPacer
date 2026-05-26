#!/bin/zsh
set -eu

project_dir="$(cd "$(dirname "$0")" && pwd)"
app_name="Compositor Pacer"
bundle_id="local.CompositorPacer"
version="0.1.0"

release_dir="$project_dir/release/CompositorPacer"
app_dir="$release_dir/${app_name}.app"
contents="$app_dir/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"

rm -rf "$release_dir"
mkdir -p "$macos" "$resources"

clang -fobjc-arc \
  -arch x86_64 \
  -arch arm64 \
  "$project_dir/Sources/CompositorPacerManager.m" \
  -framework Cocoa \
  -framework QuartzCore \
  -framework Metal \
  -framework CoreVideo \
  -o "$macos/$app_name"

cp "$project_dir/Resources/Info.plist" "$contents/Info.plist"
plutil -replace CFBundleExecutable -string "$app_name" "$contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents/Info.plist"
plutil -replace CFBundleName -string "$app_name" "$contents/Info.plist"
plutil -replace CFBundleDisplayName -string "$app_name" "$contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"

if [[ -d "$project_dir/Resources/Assets.xcassets" ]]; then
  xcrun actool "$project_dir/Resources/Assets.xcassets" \
    --compile "$resources" \
    --platform macosx \
    --minimum-deployment-target 10.13 \
    --app-icon AppIcon \
    --output-partial-info-plist "$contents/assetcatalog-info.plist" >/dev/null
  icon_name="$(plutil -extract CFBundleIconFile raw "$contents/assetcatalog-info.plist" 2>/dev/null || true)"
  if [[ -n "$icon_name" ]]; then
    plutil -replace CFBundleIconFile -string "$icon_name" "$contents/Info.plist"
  fi
fi

print "built: $app_dir"
