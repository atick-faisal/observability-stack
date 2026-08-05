#!/usr/bin/env bash
#
# Restores a backup written by scripts/backup.sh.
#
#   ./scripts/restore.sh backups/20260805T120000Z            # dry run: says what it would do
#   ./scripts/restore.sh backups/20260805T120000Z --yes      # actually does it
#
# This is destructive. Every volume it touches is emptied before the archive goes
# in, so a restore of a partial backup does not leave a half-old, half-new mix
# that looks like it worked. Without --yes it prints the plan and stops; there is
# no interactive prompt, because a prompt is the thing people learn to hit enter
# on and it makes the script unusable from cron.
#
# The volumes have to exist already, and this script will not create them. Compose
# stamps its own labels and a config-hash on the volumes it makes, and a volume
# forged here would either be rejected on the next `up` or silently adopted with
# the wrong metadata. To restore onto a clean slate:
#
#   docker compose ... down
#   docker volume rm observability_grafana_data          # the ones you are replacing
#   make up                                              # compose recreates them, empty
#   ./scripts/restore.sh backups/<stamp> --yes
#
# GlitchTip's database is restored with pg_restore --clean --if-exists into the
# running container, not by dropping a tarred PGDATA over it — that is the half
# of the pair backup.sh deliberately does not produce.

set -uo pipefail

COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-observability}"
HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-alpine:3.21}"

confirm=0
srcdir=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--yes) confirm=1 ;;
	-h | --help)
		sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		printf 'unknown argument: %s (try --help)\n' "$1" >&2
		exit 2
		;;
	*) srcdir="$1" ;;
	esac
	shift
done

if [[ -z $srcdir ]]; then
	printf 'usage: %s <backup-dir> [--yes]\n' "$0" >&2
	exit 2
fi

srcdir="${srcdir%/}"
[[ -d $srcdir ]] || {
	printf 'no such backup directory: %s\n' "$srcdir" >&2
	exit 1
}

failed=0
ok() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
err() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	failed=$((failed + 1))
}

volume_for() {
	docker volume ls -q \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
		--filter "label=com.docker.compose.volume=$1" | head -1
}

container_for() {
	docker ps -aq \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
		--filter "label=com.docker.compose.service=$1" | head -1
}

running() {
	local id
	id="$(container_for "$1")"
	[[ -n $id ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == true ]]
}

# Which containers must be down before a volume can be swapped underneath them.
holders_of() {
	case "$1" in
	grafana_data) echo grafana ;;
	prometheus_data) echo prometheus ;;
	loki_data) echo loki ;;
	tempo_data) echo tempo ;;
	glitchtip_uploads) echo "glitchtip-web glitchtip-worker" ;;
	esac
}

# ── integrity first: a bad archive must fail before anything is deleted ──────

printf '\nrestore ← %s\n\n' "$srcdir"

if [[ -f "$srcdir/SHA256SUMS" ]]; then
	if (cd "$srcdir" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
		ok "SHA256SUMS verified"
	else
		printf '  \033[31mFAIL\033[0m  SHA256SUMS mismatch — refusing to restore a damaged backup\n\n'
		exit 1
	fi
else
	printf '  \033[31mFAIL\033[0m  no SHA256SUMS in %s — refusing to restore an unverifiable backup\n\n' "$srcdir"
	exit 1
fi

# ── plan ────────────────────────────────────────────────────────────────────

# Read the manifest rather than globbing the directory: it is what records the
# expected size, and what makes "restore only what was actually backed up" true.
plan_volumes=()
plan_sizes=()
while read -r kind name archive size; do
	[[ $kind == volume ]] || continue
	plan_volumes+=("$name")
	plan_sizes+=("$archive:$size")
done <"$srcdir/manifest.txt"

has_pgdump=0
grep -q '^pgdump ' "$srcdir/manifest.txt" 2>/dev/null && has_pgdump=1

printf '\nthis will REPLACE:\n'
for i in "${!plan_volumes[@]}"; do
	name="${plan_volumes[$i]}"
	volume="$(volume_for "$name")"
	printf '  %-22s → %s\n' "$name" "${volume:-<missing: create it with make up first>}"
done
[[ $has_pgdump -eq 1 ]] && printf '  %-22s → pg_restore --clean --if-exists into the running container\n' "glitchtip database"

if [[ $confirm -eq 0 ]]; then
	printf '\ndry run — nothing was changed. Re-run with --yes to proceed.\n\n'
	exit 0
fi

printf '\n'

# ── volumes ─────────────────────────────────────────────────────────────────

for i in "${!plan_volumes[@]}"; do
	name="${plan_volumes[$i]}"
	archive="${plan_sizes[$i]%%:*}"
	expected="${plan_sizes[$i]##*:}"

	volume="$(volume_for "$name")"
	if [[ -z $volume ]]; then
		err "$name — volume does not exist; run make up once so compose creates it, then re-run"
		continue
	fi
	if [[ ! -f "$srcdir/$archive" ]]; then
		err "$name — $archive missing from the backup directory"
		continue
	fi
	actual="$(wc -c <"$srcdir/$archive" | tr -d ' ')"
	if [[ $actual != "$expected" ]]; then
		err "$name — $archive is $actual bytes, manifest says $expected"
		continue
	fi

	restart=()
	for svc in $(holders_of "$name"); do
		if running "$svc"; then
			docker stop "$(container_for "$svc")" >/dev/null 2>&1 && restart+=("$svc")
		fi
	done

	# Empty then fill, in one helper container, so a failure between the two
	# cannot be mistaken for success. Ownership survives because busybox tar has
	# no uname/gname mapping at all — it restores the numeric uid/gid from the
	# header, which is what keeps grafana's 472 and prometheus' 65534 correct.
	# (GNU tar needs --numeric-owner for the same effect; busybox rejects the flag.)
	if docker run --rm \
		-v "$volume:/dst" \
		-v "$(cd "$srcdir" && pwd):/src:ro" \
		"$HELPER_IMAGE" \
		sh -c "find /dst -mindepth 1 -delete && tar xzf '/src/$archive' -C /dst" 2>/dev/null; then
		ok "$name restored from $archive"
	else
		err "$name — extract failed; the volume is now EMPTY, do not start the service against it"
	fi

	for svc in "${restart[@]}"; do
		docker start "$(container_for "$svc")" >/dev/null 2>&1 ||
			err "$svc did not restart — start it by hand"
	done
done

# ── glitchtip's database ────────────────────────────────────────────────────

if [[ $has_pgdump -eq 1 ]]; then
	if ! running glitchtip-postgres; then
		err "glitchtip database — glitchtip-postgres is not running; make glitchtip-up first"
	else
		# web and worker hold open connections, and an open connection is what
		# makes --clean's DROPs fail halfway through.
		restart=()
		for svc in glitchtip-web glitchtip-worker; do
			if running "$svc"; then
				docker stop "$(container_for "$svc")" >/dev/null 2>&1 && restart+=("$svc")
			fi
		done

		# --clean --if-exists drops each object before recreating it, so this is a
		# replace and not a merge. Exit status is ignored on purpose: pg_restore
		# returns non-zero for benign "does not exist, skipping" notices under
		# --if-exists, so the check below is whether the data actually landed.
		docker exec -i "$(container_for glitchtip-postgres)" sh -c \
			'pg_restore --clean --if-exists --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
			<"$srcdir/glitchtip_pg.dump" >/dev/null 2>&1

		count="$(docker exec "$(container_for glitchtip-postgres)" sh -c \
			'psql -tAq -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from django_migrations"' 2>/dev/null | tr -d '[:space:]')"
		if [[ ${count:-0} -gt 0 ]]; then
			ok "glitchtip database restored ($count migrations present)"
		else
			err "glitchtip database — pg_restore left no django_migrations rows"
		fi

		for svc in "${restart[@]}"; do
			docker start "$(container_for "$svc")" >/dev/null 2>&1 ||
				err "$svc did not restart — start it by hand"
		done
	fi
fi

printf '\n'
if [[ $failed -eq 0 ]]; then
	printf '\033[32m%s\033[0m\n\n' "restore complete"
else
	printf '\033[31m%d step(s) failed\033[0m — read the lines above before starting anything\n\n' "$failed"
fi
exit "$failed"
