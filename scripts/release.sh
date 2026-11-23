#!/bin/zsh
# Publishes the next release from a clean, pushed-or-pushable main:
# sets CLIUpdate.version (committing the bump if needed), builds, checks the
# binary reports the version, tags v<version>, pushes, and creates the GitHub
# release with reprise-<version>-macos-arm64.tar.gz attached.
#
#   scripts/release.sh                  next patch after the latest tag
#   scripts/release.sh 0.2.0            a chosen version
#   scripts/release.sh 0.2.0 notes.md   with written notes (default: commit subjects)
set -euo pipefail
cd "${0:A:h}/.."

[[ $(git branch --show-current) == main ]] || { echo "Release from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash changes first."; exit 1; }

last=$(git tag --list 'v*' --sort=-v:refname | head -1)
last=${last#v}
version=${1:-}
if [[ -z $version ]]; then
  parts=(${(s:.:)last})
  version="${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))"
fi
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "v$version already exists."; exit 1
fi

file=Sources/reprise/CLIUpdate.swift
current=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' $file)
if [[ $current != $version ]]; then
  sed -i '' "s/static let version = \"$current\"/static let version = \"$version\"/" $file
  git commit -q -m "Version $version" $file
fi

swift build -c release
[[ $(.build/release/reprise --version) == "reprise $version" ]] || { echo "Binary doesn't report $version."; exit 1; }

work=$(mktemp -d)
trap 'rm -rf $work' EXIT
archive="$work/reprise-$version-macos-arm64.tar.gz"
tar -czf $archive -C .build/release reprise

notes="$work/notes.md"
if [[ -n ${2:-} ]]; then
  cat $2 > $notes
else
  git log --no-merges --format='- %s' "v$last..HEAD" | grep -v '^- Version ' > $notes || true
fi
cat >> $notes <<EOF

Already on 0.1.5 or later? Run \`reprise update\`.

The binary is unsigned. After downloading:
\`\`\`sh
tar -xzf reprise-$version-macos-arm64.tar.gz
xattr -d com.apple.quarantine reprise
./reprise
\`\`\`
Or build from source with \`scripts/install.sh\`.
EOF

git tag "v$version"
git push -q origin main "v$version"
gh release create "v$version" $archive --title "Reprise Terminal $version" --notes-file $notes
echo "Released $version."
