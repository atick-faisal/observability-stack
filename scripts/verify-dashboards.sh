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

	# Grafana renders "All" whenever includeAll is set, even over an empty option
	# list — and with no allValue it then interpolates to "", so a panel filtering
	# `x=~"$var"` matches nothing. An empty variable and a working one look
	# identical in the dropdown, which is what made this cost an afternoon on the
	# live stack. ".+" is exactly the union of the options, because Prometheus
	# never returns an empty label value.
	noall=$(jq -r '[(.templating.list // [])[] | select(.includeAll == true)
		| select((.allValue // "") == "") | .name] | join(", ")' "$f")
	[[ -z "$noall" ]] || fail "$name: includeAll with no allValue: $noall — \"All\" would interpolate to \"\""
done

# Grafana keys a dashboard by uid, so two files sharing one means the second
# silently replaces the first at provisioning time — a check that needs every uid
# at once rather than one file's.
dupes=$(for f in "${FILES[@]}"; do jq -r '.uid // "«none»"' "$f"; done | sort | uniq -d | tr '\n' ' ')
[[ -z "${dupes// /}" ]] || fail "duplicate dashboard uids: $dupes"

[[ "$failed" -eq "$before" ]] &&
	pass "${#FILES[@]} dashboards: schemaVersion 41, editable false, unique uids, known datasources"

# ── 2. the variables resolve, and every expression returns something ──────────
# The panels below are checked with the values the dashboard's own template
# variables produce, not with constants this script invents. That distinction is
# the whole point: substituting `$container` with `.*` and asserting the panel
# returns rows proves the panel, and proves nothing at all about the variable
# feeding it. The Infrastructure dashboard shipped with a $container whose option
# list no Grafana had ever resolved, and every panel behind it passed this check
# on every run.
#
# Resolution mirrors what the Prometheus datasource does for
# label_values(<selector>, <label>): split on the last comma — the label always
# follows it, so commas inside {} are safe — interpolate the variables already
# resolved, and ask /api/v1/label/<label>/values.
VARS=""

# bash 3.2 on macOS has no associative arrays, so this is a NAME<TAB>VALUE string.
# Longest name first, so a variable cannot eat the prefix of a longer one.
var_interpolate() {
	local s="$1" n v
	while IFS=$'\t' read -r n v; do
		[[ -n "$n" ]] || continue
		s="${s//\$$n/$v}"
	done < <(printf '%s' "$VARS" | awk -F'\t' 'NF { print length($1) "\t" $0 }' | sort -rn | cut -f2-)
	printf '%s' "$s"
}

# The window is the dashboards' own default range. Without start/end this
# endpoint searches the full retention, where a variable that no longer resolves
# for anyone opening the dashboard still answers.
resolve_label_values() {
	local end start
	end=$(date +%s)
	start=$((end - 3600))
	curl -sG --max-time 15 "$PROM_URL/api/v1/label/$1/values" \
		--data-urlencode "match[]=$2" \
		--data-urlencode "start=$start" \
		--data-urlencode "end=$end" | jq -r '.data // [] | .[]'
}

substitute() {
	var_interpolate "$(cat)" |
		sed -e 's/\$__rate_interval/5m/g' \
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

	check "$name — every template variable resolves"
	VARS=""
	unresolved=""
	while IFS=$'\t' read -r vname vmulti vquery; do
		if [[ "$vquery" != label_values\(*\) ]]; then
			fail "\$$vname — not a label_values() query: $vquery"
			unresolved="$unresolved \$$vname"
			continue
		fi
		inner="${vquery#label_values(}"
		inner="${inner%)}"
		vlabel="${inner##*,}"
		vlabel="${vlabel// /}"
		vselector=$(var_interpolate "${inner%,*}")

		values=$(resolve_label_values "$vlabel" "$vselector" | sort)
		if [[ -z "$values" ]]; then
			fail "\$$vname → no values: label_values($vselector,$vlabel)"
			unresolved="$unresolved \$$vname"
			continue
		fi

		# Multi-valued variables are checked as the alternation Grafana builds
		# when every option is selected, which is both the strictest case and
		# what allValue=".+" is equivalent to.
		if [[ "$vmulti" == true ]]; then
			resolved=$(printf '%s\n' "$values" | paste -sd '|' -)
		else
			resolved=$(printf '%s\n' "$values" | head -1)
		fi
		VARS="${VARS}${vname}"$'\t'"${resolved}"$'\n'
		pass "\$$vname → $resolved"
	done < <(jq -r '(.templating.list // [])[]
		| select(.type == "query")
		| [.name, (.multi // false | tostring), (if (.query | type) == "string" then .query else (.query.query // "") end)]
		| @tsv' "$f")

	check "$name — every panel target returns data"
	if [[ -n "$unresolved" ]]; then
		skip "panels not evaluated — unresolved variable(s):$unresolved"
		continue
	fi

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
