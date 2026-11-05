#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version="${1:-1.3.0}"
release_dir="$project_dir/dist"
work_dir="$(mktemp -d)"
app_dir="$work_dir/app"
dmg_root="$work_dir/dmg"
output_path="$release_dir/SnipAItrans-$version-macOS.dmg"

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$app_dir" "$dmg_root" "$release_dir"
APP_OUTPUT_DIR="$app_dir" APP_VERSION="$version" SIGNING_IDENTITY="-" \
    zsh "$project_dir/scripts/build-app.sh"

cp -R "$app_dir/SnipAItrans.app" "$dmg_root/SnipAItrans.app"
ln -s /Applications "$dmg_root/Applications"

rm -f "$output_path"
hdiutil create \
    -volname "SnipAItrans" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$output_path" >/dev/null

codesign --verify --deep --strict "$dmg_root/SnipAItrans.app"
(
    cd "$release_dir"
    shasum -a 256 "${output_path:t}" > "${output_path:t}.sha256"
)
print "$output_path"
