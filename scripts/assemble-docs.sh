#!/usr/bin/env bash
#
# Assembles the pages MkDocs needs but git does not carry.
#
#   ./scripts/assemble-docs.sh          # writes docs/{index,agent,sdk}.md
#
# Three documents are the canonical copy where they live — README.md is what
# GitHub renders, sdk/obstack/README.md is what PyPI renders, agent/README.md
# sits next to the config it describes. Copying them in at build time keeps one
# source of truth instead of two that drift. The three outputs are gitignored.
#
# The sed passes fix the relative links that only hold in the original location:
#
#   README.md              ./docs/foo.md          -> ./foo.md
#                          ./docs/diagrams/       -> ./diagrams/
#                          ./agent/README.md      -> ./agent.md
#                          ./sdk/obstack/README.md -> ./sdk.md
#   sdk/obstack/README.md  ../../docs/labels.md   -> labels.md
#
# Both are anchored on the leading path so they cannot touch prose that merely
# mentions a directory. Anything they miss becomes a `mkdocs build --strict`
# failure in .github/workflows/docs.yml rather than a dead link on the site.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sed -e 's|\./docs/|./|g' \
    -e 's|(\./agent/README\.md)|(./agent.md)|g' \
    -e 's|(\./sdk/obstack/README\.md)|(./sdk.md)|g' \
    README.md >docs/index.md
cp agent/README.md docs/agent.md
sed 's|\.\./\.\./docs/labels\.md|labels.md|g' sdk/obstack/README.md >docs/sdk.md

echo "assembled: docs/index.md docs/agent.md docs/sdk.md"
