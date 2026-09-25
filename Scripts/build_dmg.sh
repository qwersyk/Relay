#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
"$project_dir/Scripts/package.sh"
staging_dir="$(mktemp -d "$project_dir/dist/.dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$project_dir/dist/Relay.app" "$staging_dir/Relay.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname Relay -srcfolder "$staging_dir" -ov -format UDZO "$project_dir/dist/Relay.dmg"
hdiutil verify "$project_dir/dist/Relay.dmg"
print "Built: $project_dir/dist/Relay.dmg"
