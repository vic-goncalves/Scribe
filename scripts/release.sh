#!/bin/sh
# Builds Scribe.app, zips it and publishes a GitHub release tagged with the version in Resources/Info.plist.
# Bump CFBundleShortVersionString before releasing an update.
set -eu
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first, so the release matches the pushed code." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists. Bump CFBundleShortVersionString in Resources/Info.plist." >&2
    exit 1
fi

./scripts/build-app.sh
rm -f build/Scribe.zip
ditto -c -k --keepParent build/Scribe.app build/Scribe.zip

git push
gh release create "$TAG" build/Scribe.zip \
    --title "Scribe $VERSION" \
    --notes "Install or update (Apple Silicon, macOS 15+): paste this into Terminal.

\`\`\`sh
curl -fsSL https://github.com/vic-goncalves/Scribe/releases/latest/download/Scribe.zip -o /tmp/Scribe.zip && rm -rf /Applications/Scribe.app && ditto -xk /tmp/Scribe.zip /Applications && open /Applications/Scribe.app
\`\`\`"
echo "Published $TAG"
