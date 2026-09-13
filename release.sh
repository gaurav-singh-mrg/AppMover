#!/bin/bash
# Publishes a GitHub release that running copies of AppMover will offer as an update.
# Usage: ./release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version, e.g. 0.2.0>}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "version must look like 0.2.0" >&2; exit 1; }
TAG="v$VERSION"
ZIP="AppMover-$VERSION.zip"

# build-app.sh reads the version from the newest tag. Uncommitted changes would ship in a
# build the tag doesn't describe; building before tagging would ship an app that thinks it
# is the previous version, and offers its own release as an update forever.
[[ -z "$(git status --porcelain)" ]] || { echo "commit or ignore every change first" >&2; exit 1; }
git tag "$TAG"
./build-app.sh
# ditto, not zip: it keeps the bundle's symlinks and extended attributes, which the code
# signature covers.
ditto -c -k --keepParent AppMover.app "$ZIP"

git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "AppMover $VERSION" --generate-notes
rm "$ZIP"
