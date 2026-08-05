#!/usr/bin/env bash
#
# Backs up the state this stack cannot rebuild from git.
#
#   ./scripts/backup.sh                 # grafana + glitchtip — the irreplaceable set
#   ./scripts/backup.sh --all           # ...plus the three TSDB volumes
#   ./scripts/backup.sh --keep 7        # prune all but the newest 7 backup directories
#
# Output lands in backups/<utc-timestamp>/ with a manifest and a SHA256SUMS.
# backups/ is gitignored. scripts/restore.sh reads both back.
#
# What is backed up, and why each one the way it is:
#
#   grafana_data      stop → tar → start.  grafana.db is SQLite, and a sequential
#                     tar of the database and its -wal sidecar can capture a pair
#                     that do not agree — a file that restores as a corrupt
#                     database rather than an old one. Grafana is a query UI, so
#                     the few seconds cost no ingest. --no-stop skips the stop.
#                     Dashboards are files in git; the admin account, users,
#                     annotations and alert state are only here.
#
#   glitchtip_pg_data pg_dump -Fc.  Tarring a live PGDATA without pg_backup_start
#                     is the textbook way to produce something that will not
#                     replay. Skipped with a warning if the container is not up,
#                     because a bad dump is worse than an absent one.
#
#   prometheus_data   tar, live, only under --all.  All three replay a write-ahead
#   loki_data         log on start and write blocks temp-then-rename, so a live tar
#   tempo_data        is equivalent to a power cut — which they are built to
#                     survive. They are also bounded by retention (30d/14d/7d) and
#                     capped at 25GB, which is why they are not in the default set:
#                     a routine backup should not be tens of gigabytes.
#
# Deliberately not used: Prometheus' /api/v1/admin/tsdb/snapshot. It is the
# correct way to get an atomic TSDB copy, but it needs --web.enable-admin-api,
# which in the same stroke exposes delete_series and clean_tombstones to every
# container on the `obs` network — including the demo's app containers. Not a
# trade worth making for a volume whose crash-consistent copy is already fine.
#
# Nothing here reads a password. The GlitchTip dump runs as the container's own
# POSTGRES_USER over a local socket, so no credential passes through this script,
# its arguments, or the shell history.

set -uo pipefail

COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-observability}"
BACKUP_ROOT="${BACKUP_ROOT:-backups}"
# Small, has tar, and is almost certainly already pulled. Pinned so a backup
# taken a year from now is taken by the same tool as one taken today.
HELPER_IMAGE="${BACKUP_HELPER_IMAGE:-alpine:3.21}"

DEFAULT_VOLUMES=(grafana_data)
TSDB_VOLUMES=(prometheus_data loki_data tempo_data)

include_all=0
no_stop=0
keep=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--all) include_all=1 ;;
	--no-stop) no_stop=1 ;;
	--keep)
		keep="${2:-0}"
		shift
		;;
	-h | --help)
		sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'unknown argument: %s (try --help)\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

failed=0

info() { printf '  %s\n' "$1"; }
ok() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
err() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	failed=$((failed + 1))
}

# Resolved by compose labels rather than by name, so a project renamed with -p
# does not silently back up nothing.
volume_for() {
	docker volume ls -q \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
		--filter "label=com.docker.compose.volume=$1" | head -1
}

container_for() {
	docker ps -q \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
		--filter "label=com.docker.compose.service=$1" | head -1
}

# tar the whole volume through a throwaway container, so nothing depends on tar
# existing inside grafana's or prometheus' image — and on the archive being
# written by root, which is what lets restore.sh put the ownership back.
tar_volume() {
	local volume="$1" dest="$2"
	docker run --rm \
		-v "$volume:/src:ro" \
		-v "$dest:/dst" \
		"$HELPER_IMAGE" \
		tar czf "/dst/$volume.tar.gz" -C /src . 2>/dev/null
}

human_size() {
	local bytes="$1"
	awk -v b="$bytes" 'BEGIN {
		split("B KB MB GB TB", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		printf "%.1f%s", b, u[i]
	}'
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
outdir="$(cd "$(dirname "$0")/.." && pwd)/$BACKUP_ROOT/$stamp"

if ! mkdir -p "$outdir"; then
	printf 'cannot create %s\n' "$outdir" >&2
	exit 1
fi

manifest="$outdir/manifest.txt"
{
	printf 'created         %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'project         %s\n' "$COMPOSE_PROJECT"
	printf 'git             %s\n' "$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"
	printf 'host            %s\n' "$(hostname)"
	printf 'mode            %s\n' "$([[ $include_all -eq 1 ]] && echo all || echo default)"
	printf '\n'
} >"$manifest"

printf '\nbackup → %s\n\n' "$outdir"

# ── grafana, and any other plain volume ─────────────────────────────────────

volumes=("${DEFAULT_VOLUMES[@]}")
[[ $include_all -eq 1 ]] && volumes+=("${TSDB_VOLUMES[@]}")

for name in "${volumes[@]}"; do
	volume="$(volume_for "$name")"
	if [[ -z $volume ]]; then
		warn "$name — no such volume in project $COMPOSE_PROJECT, skipped"
		continue
	fi

	# Only grafana is stopped. The TSDBs are explicitly taken live; see the header.
	stopped=""
	if [[ $name == grafana_data && $no_stop -eq 0 ]]; then
		if [[ -n $(container_for grafana) ]]; then
			docker stop "$(container_for grafana)" >/dev/null 2>&1 && stopped=grafana
		fi
	fi

	if tar_volume "$volume" "$outdir"; then
		size="$(wc -c <"$outdir/$volume.tar.gz" | tr -d ' ')"
		ok "$(printf '%-24s %8s%s' "$name" "$(human_size "$size")" \
			"$([[ -n $stopped ]] && echo '  (grafana stopped)' || true)")"
		printf 'volume          %s  %s  %s\n' "$name" "$volume.tar.gz" "$size" >>"$manifest"
	else
		err "$name — tar failed"
	fi

	if [[ -n $stopped ]]; then
		docker start "$(docker ps -aq \
			--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
			--filter "label=com.docker.compose.service=grafana" | head -1)" >/dev/null 2>&1 ||
			err "grafana did not restart — start it by hand"
	fi
done

# ── glitchtip's postgres ────────────────────────────────────────────────────

gt="$(container_for glitchtip-postgres)"
if [[ -z $gt ]]; then
	warn "glitchtip_pg_data          not running, skipped (a tar of a live PGDATA is not a backup)"
else
	# -Fc is the custom format: compressed, and restorable selectively by
	# pg_restore. POSTGRES_USER/DB come from the container's own environment, so
	# this stays correct if .env.glitchtip changes.
	if docker exec "$gt" sh -c \
		'pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >"$outdir/glitchtip_pg.dump" 2>/dev/null &&
		[[ -s "$outdir/glitchtip_pg.dump" ]]; then
		size="$(wc -c <"$outdir/glitchtip_pg.dump" | tr -d ' ')"
		ok "$(printf '%-24s %8s' glitchtip_pg "$(human_size "$size")")"
		printf 'pgdump          glitchtip  glitchtip_pg.dump  %s\n' "$size" >>"$manifest"
	else
		rm -f "$outdir/glitchtip_pg.dump"
		err "glitchtip_pg — pg_dump failed"
	fi
fi

# glitchtip_uploads is sourcemaps and release artifacts: re-uploadable, and
# meaningless without the database, so it rides along only under --all.
if [[ $include_all -eq 1 ]]; then
	volume="$(volume_for glitchtip_uploads)"
	if [[ -n $volume ]] && tar_volume "$volume" "$outdir"; then
		size="$(wc -c <"$outdir/$volume.tar.gz" | tr -d ' ')"
		ok "$(printf '%-24s %8s' glitchtip_uploads "$(human_size "$size")")"
		printf 'volume          glitchtip_uploads  %s  %s\n' "$volume.tar.gz" "$size" >>"$manifest"
	fi
fi

# ── checksums, and pruning ──────────────────────────────────────────────────

(
	cd "$outdir" || exit 1
	# manifest.txt is included: it records the sizes, so a truncated archive that
	# somehow re-checksums cleanly still fails the size comparison in restore.sh.
	shasum -a 256 ./*.tar.gz ./*.dump manifest.txt 2>/dev/null >SHA256SUMS
)
ok "SHA256SUMS"

if [[ $keep -gt 0 ]]; then
	pruned=0
	while IFS= read -r old; do
		rm -rf "$old" && pruned=$((pruned + 1))
	done < <(find "$(dirname "$outdir")" -maxdepth 1 -mindepth 1 -type d |
		sort -r | tail -n "+$((keep + 1))")
	[[ $pruned -gt 0 ]] && info "pruned $pruned older backup(s), kept $keep"
fi

printf '\n'
if [[ $failed -eq 0 ]]; then
	printf '\033[32m%s\033[0m\n\n' "backup complete — $outdir"
else
	printf '\033[31m%d step(s) failed\033[0m — the backup in %s is incomplete\n\n' "$failed" "$outdir"
fi
exit "$failed"
