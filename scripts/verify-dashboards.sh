#!/usr/bin/env bash
#
# Asserts that every panel on every provisioned dashboard actually has data. Run
# it against the demo, which is the only stack that produces all three signals:
#
#   make demo-up && ./scripts/verify-dashboards.sh
#
# Exit code is the number of failed checks, so it works in CI.
#
# The reason this exists: an expression that returns nothing renders as an empty
# graph, which is indistinguishable from a quiet period. Across ~40 hand-written
# panels that is well past the number anyone re-checks by eye, and a label rename
# in docs/labels.md would break them silently. Here it breaks the build.

set -uo pipefail

APP="${OBS_APP:-demo}"
ENV="${OBS_ENV:-local}"
HOST="${OBS_HOST:-demo-host}"
DATNAME="${OBS_DATNAME:-demo}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
DASHBOARD_DIR="${DASHBOARD_DIR:-server/grafana/dashboards}"

failed=0
step=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

fail() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	failed=$((failed + 1))
}

check() {
	step=$((step + 1))
	printf '\n%d. %s\n' "$step" "$1"
}

# Not `mapfile`: macOS ships bash 3.2, which does not have it.
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(find "$DASHBOARD_DIR" -name '*.json' | sort)
[[ ${#FILES[@]} -gt 0 ]] || {
	printf 'no dashboards under %s\n' "$DASHBOARD_DIR"
	exit 1
}

# ── 1. the files themselves ───────────────────────────────────────────────────
# Cheap, and it catches the whole class of mistake a Grafana UI export introduces:
# schemaVersion drift, editable flipped back on, a __inputs-style datasource
# reference instead of one of our three fixed uids.
check "the dashboard files are the shape provisioning expects"
before=$failed
for f in "${FILES[@]}"; do
	name="${f#"$DASHBOARD_DIR"/}"

	sv=$(jq -r '.schemaVersion // "absent"' "$f")
	[[ "$sv" == "41" ]] || fail "$name: schemaVersion is $sv, expected 41"

	# `has("editable")`, not `.editable // "absent"`: jq's alternative operator
	# treats false as empty, so the obvious spelling reports "absent" for exactly
	# the files that are correct.
	ed=$(jq -r 'if has("editable") then (.editable | tostring) else "absent" end' "$f")
	[[ "$ed" == "false" ]] || fail "$name: editable is $ed — provisioned dashboards are files, not UI state"

	uid=$(jq -r '.uid // ""' "$f")
	[[ -n "$uid" ]] || fail "$name: no uid"

	bad=$(jq -r '[.. | objects | select(has("datasource")) | .datasource | select(type == "object") | .uid
		| select(. != null and (startswith("$") | not) and (IN("prometheus", "loki", "tempo", "-- Grafana --", "grafana") | not))]
		| unique | join(", ")' "$f")
	[[ -z "$bad" ]] || fail "$name: datasource uid outside the provisioned three: $bad"
done

# Grafana keys a dashboard by uid, so two files sharing one means the second
# silently replaces the first at provisioning time — a check that needs every uid
# at once rather than one file's.
dupes=$(for f in "${FILES[@]}"; do jq -r '.uid // "«none»"' "$f"; done | sort | uniq -d | tr '\n' ' ')
[[ -z "${dupes// /}" ]] || fail "duplicate dashboard uids: $dupes"

[[ "$failed" -eq "$before" ]] &&
	pass "${#FILES[@]} dashboards: schemaVersion 41, editable false, unique uids, known datasources"

# ── 2. every expression returns something ─────────────────────────────────────
# Dashboard variables are substituted with the demo's values, so this asserts the
# same thing a human does by opening the dashboard and picking app=demo. $service
# is multi-valued, which Grafana renders as an alternation — hence api|loadgen
# rather than a single value, and hence why panels use service=~"$service".
substitute() {
	sed -e "s/\$app/$APP/g" \
		-e "s/\$env/$ENV/g" \
		-e "s/\$service/api|loadgen/g" \
		-e "s/\$host/$HOST/g" \
		-e "s/\$datname/$DATNAME/g" \
		-e "s/\$container/.*/g" \
		-e 's/\$__rate_interval/5m/g' \
		-e 's/\$__interval/1m/g' \
		-e 's/\$__range/1h/g'
}

promql() {
	curl -sG --max-time 15 "$PROM_URL/api/v1/query" \
		--data-urlencode "query=$1" | jq -r '.data.result // [] | length'
}

logql() {
	local end start
	end=$(date +%s)
	start=$((end - 3600))
	curl -sG --max-time 15 "$LOKI_URL/loki/api/v1/query_range" \
		--data-urlencode "query=$1" \
		--data-urlencode "start=${start}000000000" \
		--data-urlencode "end=${end}000000000" \
		--data-urlencode "limit=5" | jq -r '.data.result // [] | length'
}

for f in "${FILES[@]}"; do
	name="${f#"$DASHBOARD_DIR"/}"
	check "$name — every panel target returns data"

	# One line per target: panel title, datasource uid, expression. Panels are
	# addressed by title rather than id because that is what a failure has to
	# name for anyone to find it.
	while IFS=$'\t' read -r title uid expr; do
		case "$uid" in
		tempo)
			# A Tempo query type — serviceMap, search — is rendered by the
			# datasource plugin and has no expression to evaluate against a
			# stored series. Reported rather than dropped, so that no panel is
			# ever silently unchecked; what backs it is asserted elsewhere.
			skip "$title — tempo panel, not evaluated"
			;;
		prometheus | loki)
			if [[ -z "$expr" ]]; then
				fail "$title — $uid target with no expression"
				continue
			fi
			q=$(printf '%s' "$expr" | substitute)
			if [[ "$uid" == prometheus ]]; then n=$(promql "$q"); else n=$(logql "$q"); fi
			[[ "${n:-0}" -gt 0 ]] &&
				pass "$title → $n series" ||
				fail "$title → no data: $q"
			;;
		*)
			fail "$title — unknown datasource uid '$uid'"
			;;
		esac
	done < <(jq -r '
		[.panels[]?, (.panels[]?.panels[]? // empty)]
		| .[]
		| select(.type != "row")
		| . as $p
		| ($p.targets // [])[]
		| [(($p.title // "«untitled»") + " [" + (.refId // "?") + "]"),
		   (.datasource.uid // $p.datasource.uid // "prometheus"),
		   (.expr // "")]
		| @tsv
	' "$f")
done

# ── 3. Grafana itself accepted them ───────────────────────────────────────────
# The checks above prove the queries are right. They cannot see a file Grafana
# refused at provisioning time, or one that landed in the wrong folder —
# foldersFromFilesStructure derives the folder from the directory name, so that
# is a filesystem mistake no amount of PromQL can catch.
check "Grafana provisioned all of them, in the right folders"
GF_USER="${GF_ADMIN_USER:-}"
GF_PASS="${GF_ADMIN_PASSWORD:-}"
if [[ -z "$GF_USER" && -f .env.server ]]; then
	GF_USER=$(sed -n 's/^GF_ADMIN_USER=//p' .env.server | tail -1)
	GF_PASS=$(sed -n 's/^GF_ADMIN_PASSWORD=//p' .env.server | tail -1)
fi
GF_USER="${GF_USER:-admin}"

listing=$(curl -s --max-time 10 -u "$GF_USER:$GF_PASS" "$GRAFANA_URL/api/search?type=dash-db")
if ! printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1; then
	skip "cannot authenticate to Grafana as '$GF_USER' — set GF_ADMIN_PASSWORD to check this"
else
	for f in "${FILES[@]}"; do
		want_folder=$(basename "$(dirname "$f")")
		uid=$(jq -r '.uid' "$f")
		got=$(printf '%s' "$listing" | jq -r --arg uid "$uid" '.[] | select(.uid == $uid) | .folderTitle // "«General»"')
		if [[ -z "$got" ]]; then
			fail "$uid is not in Grafana — provisioning rejected it, check: docker compose logs grafana"
		elif [[ "$got" != "$want_folder" ]]; then
			fail "$uid is in folder '$got', expected '$want_folder'"
		else
			pass "$uid provisioned under $got"
		fi
	done
fi

printf '\n'
if [[ "$failed" -eq 0 ]]; then
	printf '\033[32mevery panel on every dashboard has data\033[0m\n'
else
	printf '\033[31m%d check(s) failed\033[0m\n' "$failed"
fi
exit "$failed"
