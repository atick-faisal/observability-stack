#!/usr/bin/env bash
#
# Resolves the floating image tags to digests, so `image:` lines can be pinned.
#
#   ./scripts/resolve-digests.sh            # print what the tags resolve to now
#   ./scripts/resolve-digests.sh --check    # exit 1 if a pinned digest has drifted
#
# --check is the one worth putting in CI: it says "the tag has moved since you
# pinned it", which is the notification you actually want. It never edits a file.
# Re-pinning is a deliberate act, especially for GlitchTip — see the comment above
# its image line in compose.glitchtip.yml.
#
# Why not `docker buildx imagetools inspect`: it authenticates through the Docker
# credential helper, which on macOS needs an unlocked login keychain and fails in
# any non-interactive session. This talks to the registry anonymously instead, so
# it works the same on a laptop, in CI, and over ssh.
#
# The digest resolved here is the multi-arch *index*, which is the only correct
# thing to pin. `docker manifest inspect -v` reports one Descriptor per platform,
# and the first entry is linux/amd64 — pinning that produces a compose file that
# runs on the VPS and cannot start on an arm64 Mac.

set -euo pipefail

cd "$(dirname "$0")/.."

# tag -> the file whose `image:` line carries the pin.
IMAGES=(
	"traefik:v3.5|compose.edge.yml"
	"glitchtip/glitchtip:6|compose.glitchtip.yml"
	"valkey/valkey:8-alpine|compose.glitchtip.yml"
)

check=0
[[ "${1:-}" == "--check" ]] && check=1

# Docker Hub's anonymous pull token, then a HEAD for the Docker-Content-Digest
# header. Accept must list the index media types or the registry helpfully
# converts the response down to a single-platform manifest and returns *its*
# digest, which is the bug this whole script exists to avoid.
index_digest() {
	local ref="$1" repo tag token
	repo="${ref%%:*}"
	tag="${ref##*:}"
	[[ "$repo" == */* ]] || repo="library/$repo"

	token=$(curl -fsS --max-time 20 \
		"https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" |
		jq -r .token)

	curl -fsSI --max-time 20 -H "Authorization: Bearer $token" \
		-H 'Accept: application/vnd.oci.image.index.v1+json' \
		-H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
		"https://registry-1.docker.io/v2/${repo}/manifests/${tag}" |
		tr -d '\r' |
		awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# What the compose file currently pins, or empty if the line is unpinned.
pinned_digest() {
	local ref="$1" file="$2" name="${1%%:*}"
	grep -oE "image: ${name}:[^@[:space:]]+@sha256:[0-9a-f]{64}" "$file" |
		head -1 | grep -oE 'sha256:[0-9a-f]{64}' || true
}

drift=0
for entry in "${IMAGES[@]}"; do
	ref="${entry%%|*}"
	file="${entry##*|}"

	current=$(index_digest "$ref") || {
		echo "could not reach the registry for $ref" >&2
		exit 2
	}
	pin=$(pinned_digest "$ref" "$file")

	if [[ $check -eq 1 ]]; then
		if [[ -z "$pin" ]]; then
			printf '  UNPINNED  %-26s %s (%s)\n' "$ref" "$current" "$file"
			drift=1
		elif [[ "$pin" != "$current" ]]; then
			printf '  DRIFTED   %-26s\n            pinned %s\n            tag    %s\n' \
				"$ref" "$pin" "$current"
			drift=1
		else
			printf '  ok        %-26s %s\n' "$ref" "$current"
		fi
	else
		printf '  image: %s@%s\n' "$ref" "$current"
	fi
done

if [[ $check -eq 1 && $drift -eq 1 ]]; then
	echo
	echo "a tag has moved since it was pinned — re-pin deliberately, not automatically" >&2
	exit 1
fi
