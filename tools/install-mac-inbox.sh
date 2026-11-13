#!/bin/bash
# Builds and installs the native receiver utility without enabling listening, sending, or login items.
set -euo pipefail
task_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
task_project=""
task_root=""
task_node="/opt/homebrew/bin/node"
task_managed_node="$HOME/Library/Application Support/AnnotateKit/runtimes/node22/bin/node"
if [[ -x "$task_managed_node" ]]; then task_node="$task_managed_node"; fi
task_destination="$HOME/Applications/Annotate Inbox.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) task_project="$2"; shift 2 ;;
    --root) task_root="$2"; shift 2 ;;
    --node) task_node="$2"; shift 2 ;;
    --destination) task_destination="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$task_project" || -z "$task_root" || ! -d "$task_root" || ! -x "$task_node" ]]; then
  echo 'Usage: tools/install-mac-inbox.sh --project <T3 project ID> --root <source checkout> [--node <node>] [--destination <app path>]' >&2
  exit 1
fi
if ! "$task_node" -e 'if (Number(process.versions.node.split(".")[0]) < 22 || typeof globalThis.WebSocket !== "function") process.exit(1)' >/dev/null 2>&1; then
  echo 'Annotate Inbox requires Node 22 or newer with WebSocket support. Pass its executable with --node; no app was replaced.' >&2
  exit 1
fi
cd "$task_repo_root"
swift build --configuration debug --product annotate-t3
task_bin="$(swift build --configuration debug --show-bin-path)"
task_stage="$task_repo_root/.build/mac-inbox/Annotate Inbox.app"
mkdir -p "$task_repo_root/.build/mac-inbox"
rm -rf "$task_stage"
# Finder launches the menu bar app, which routes to the nested window app when menu bar mode
# is disabled. Separate bundle identities keep their lifecycles independent; no login item is used.
task_helper="$task_stage/Contents/Helpers/Annotate Inbox Window.app"
# SwiftPM's generated accessor looks for its resource bundle beside the packaged executable.
task_resource_candidates=("$task_bin/"*AnnotateT3CLI*.bundle)
task_resource_bundle="${task_resource_candidates[0]}"
if [[ ! -d "$task_resource_bundle" ]]; then
  echo 'SwiftPM receiver resource bundle was not found.' >&2
  exit 1
fi
for task_bundle in "$task_stage" "$task_helper"; do
  mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
  cp "$task_bin/annotate-t3" "$task_bundle/Contents/MacOS/annotate-t3"
  cp -R "$task_resource_bundle" "$task_bundle/Contents/Resources/"
  cp "$task_repo_root/tools/mac-inbox/AppIcon.icns" "$task_bundle/Contents/Resources/AppIcon.icns"
done
python3 - "$task_stage" "$task_helper" "$task_project" "$task_root" "$task_node" "$HOME" <<'PY'
import json, pathlib, plistlib, sys
app, helper, project, root, node, user_home = sys.argv[1:]
common = {
    'CFBundleExecutable': 'annotate-t3',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.1',
    'CFBundleVersion': '3',
    'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
    'CFBundleIconFile': 'AppIcon',
}
bundles = {
    app: {'CFBundleIdentifier': 'dev.annotatekit.inbox.menu', 'CFBundleName': 'Annotate Inbox',
          'CFBundleDisplayName': 'Annotate Inbox', 'LSUIElement': True,
          'LSApplicationCategoryType': 'public.app-category.developer-tools'},
    helper: {'CFBundleIdentifier': 'dev.annotatekit.inbox', 'CFBundleName': 'Annotate Inbox',
             'CFBundleDisplayName': 'Annotate Inbox', 'LSUIElement': False,
             'LSApplicationCategoryType': 'public.app-category.developer-tools',
             'CFBundleURLTypes': [{'CFBundleURLName': 'dev.annotatekit.inbox', 'CFBundleURLSchemes': ['annotate-inbox']}]},
}
config = {'projectID': project, 'root': str(pathlib.Path(root).resolve()), 'node': node,
          'credentials': str(pathlib.Path(user_home) / 'Library/Application Support/AnnotateKit/t3-credentials.json')}
for bundle, values in bundles.items():
    contents = pathlib.Path(bundle) / 'Contents'
    with (contents / 'Info.plist').open('wb') as file:
        plistlib.dump({**common, **values}, file)
    (contents / 'Resources/receiver-config.json').write_text(json.dumps(config))
PY
codesign --force --sign - "$task_helper"
codesign --force --deep --sign - "$task_stage"
mkdir -p "$(dirname "$task_destination")"
if [[ -e "$task_destination" ]]; then
  task_backup="$task_repo_root/.build/mac-inbox/previous-$(date +%Y%m%d-%H%M%S).app-backup"
  mv "$task_destination" "$task_backup"
fi
ditto "$task_stage" "$task_destination"
codesign --verify --deep --strict "$task_destination"
echo "Installed: $task_destination"
