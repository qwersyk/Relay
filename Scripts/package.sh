#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build --build-system native -c release
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/dist/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Relay.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
cp "$binary_dir/Relay" "$app_dir/Contents/MacOS/Relay"
cp "$binary_dir/relay-cli" "$app_dir/Contents/Helpers/relay-cli"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -f Resources/Relay.icns ]]; then cp Resources/Relay.icns "$app_dir/Contents/Resources/Relay.icns"; fi
codesign --force --sign - --identifier local.relay.helper "$app_dir/Contents/Helpers/relay-cli"
codesign --force --sign - --identifier local.relay.mac "$app_dir"
codesign --verify --deep --strict "$app_dir"
destination="$project_dir/dist/Relay.app"
# Replace the bundle without overwriting executable files mapped by a running app.
if [[ -d "$destination" ]]; then
    backup="$project_dir/dist/.Relay.previous.$$.app"
    mv "$destination" "$backup"
    if ! mv "$app_dir" "$destination"; then mv "$backup" "$destination"; exit 1; fi
    rm -rf "$backup"
else
    mv "$app_dir" "$destination"
fi
print "Built: $destination"
