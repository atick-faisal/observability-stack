#!/usr/bin/env bash
#
# Asserts that all five signals arrive from the demo app, end to end, with the
# label contract intact. Run it a minute or so after `make demo-up`.
#
#   ./scripts/verify-signals.sh
#   OBS_APP=myapp PROM_URL=https://... ./scripts/verify-signals.sh
#
# Exit code is the number of failed checks, so it works in CI. Steps 4 and 5
# cover exemplars and span-metrics, which M5 owns; until then they report
# without failing the run.

set -uo pipefail

APP="${OBS_APP:-demo}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
SERVICE="${OBS_SERVICE:-api}"
STRICT_STEPS="${STRICT_STEPS:-1,2,3,4}"

failed=0
step=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

fail() {
	if [[ ",$STRICT_STEPS," == *",$step,"* ]]; then
		printf '  \033[31mFAIL\033[0m  %s\n' "$1"
		failed=$((failed + 1))
	else
		skip "$1  (not required until M5)"
	fi
}

check() {
	step=$((step + 1))
	printf '\n%d. %s\n' "$step" "$1"
}

promql() {
	curl -sG --max-time 10 "$PROM_URL/api/v1/query" \
		--data-urlencode "query=$1" | jq -r '.data.result | length'
}

check "metrics — the app's own series reached Prometheus"
n=$(promql "count(fastapi_requests_total{app=\"$APP\"})")
[[ "${n:-0}" -gt 0 ]] && pass "fastapi_requests_total{app=\"$APP\"}" \
	|| fail "no fastapi_requests_total for app=$APP"

labels=$(curl -sG --max-time 10 "$PROM_URL/api/v1/query" \
	--data-urlencode "query=fastapi_requests_total{app=\"$APP\",service=\"$SERVICE\"}" |
	jq -r '[.data.result[0].metric | keys[]] | join(",")')
case "$labels" in
*app*) ;;
*) fail "identity labels missing from the series: [$labels]" ;;
esac
for l in env host service instance; do
	case ",$labels," in
	*",$l,"*) ;;
	*) fail "series is missing the $l label: [$labels]" ;;
	esac
done
case "$labels" in
*exported_*) fail "label collision: [$labels] — honor_labels is off" ;;
*) pass "identity labels intact, no exported_* collision" ;;
esac

check "metrics — the agent's other exporters reached Prometheus"
for m in node_uname_info container_memory_usage_bytes pg_up; do
	n=$(promql "count($m{app=\"$APP\"})")
	[[ "${n:-0}" -gt 0 ]] && pass "$m" || fail "$m absent for app=$APP"
done

check "logs — streams reached Loki with the six-label contract"
app_values=$(curl -sG --max-time 10 "$LOKI_URL/loki/api/v1/label/app/values" | jq -r '.data // [] | join(" ")')
case " $app_values " in
*" $APP "*) pass "app=$APP present in Loki" ;;
*) fail "app=$APP not among Loki's app values: [$app_values]" ;;
esac

# /labels is resolved over a coarse time window and keeps reporting labels from
# streams that are no longer written. /series returns the label sets of streams
# actually active in the range, which is the thing being asserted.
start=$(($(date +%s) - 300))000000000
stream_labels=$(curl -sG --max-time 10 "$LOKI_URL/loki/api/v1/series" \
	--data-urlencode "match[]={app=\"$APP\"}" --data-urlencode "start=$start" |
	jq -r '[.data[]? | keys] | flatten | unique | join(",")')
[[ "$stream_labels" == "app,container,env,host,level,service" ]] &&
	pass "stream labels are exactly the six in docs/labels.md §3.2" ||
	fail "stream labels are [$stream_labels], expected app,container,env,host,level,service"

# Without the categorize-labels encoding flag Loki merges structured metadata
# into the stream object, which is where trace_id shows up.
#
# The window ends 90s in the past on purpose. A log line is in Loki within a
# second; the trace it belongs to has to clear the SDK's batch processor and
# Tempo's ingester first, so picking the newest line races the trace lookup below.
tid=$(curl -sG --max-time 10 "$LOKI_URL/loki/api/v1/query_range" \
	--data-urlencode "query={app=\"$APP\",service=\"$SERVICE\"}" \
	--data-urlencode "start=$start" --data-urlencode "end=$((($(date +%s) - 90)))000000000" \
	--data-urlencode "limit=20" |
	jq -r '[.data.result[]?.stream.trace_id // empty] | first // ""')
[[ -n "$tid" ]] && pass "trace_id in structured metadata: $tid" ||
	fail "no log line carried trace_id in structured metadata"

check "traces — spans reached Tempo through the agent"
n=$(curl -sG --max-time 10 "$TEMPO_URL/api/search" \
	--data-urlencode "tags=service.name=$APP-$SERVICE" | jq -r '.traces // [] | length')
[[ "${n:-0}" -gt 0 ]] && pass "$n traces for service.name=$APP-$SERVICE" ||
	fail "no traces for service.name=$APP-$SERVICE"

if [[ -n "$tid" ]]; then
	svc=$(curl -s --max-time 10 "$TEMPO_URL/api/traces/$tid" |
		jq -r '[.batches[]?.resource.attributes[]? | select(.key=="service.name") | .value.stringValue] | unique | join(" ")')
	[[ -n "$svc" ]] && pass "the trace_id from Loki resolves in Tempo: $svc" ||
		fail "trace_id $tid from a log line does not resolve in Tempo"
fi

check "exemplars — a metric sample carries a link to a trace"
n=$(curl -sG --max-time 10 "$PROM_URL/api/v1/query_exemplars" \
	--data-urlencode "query=fastapi_requests_duration_seconds_bucket{app=\"$APP\"}" \
	--data-urlencode "start=$(($(date +%s) - 900))" --data-urlencode "end=$(date +%s)" |
	jq -r '.data // [] | length')
[[ "${n:-0}" -gt 0 ]] && pass "$n exemplar series" || fail "no exemplars stored"

check "span-metrics — Tempo's generator produced series for this app"
n=$(promql "count(traces_spanmetrics_calls_total{app=\"$APP\"})")
[[ "${n:-0}" -gt 0 ]] && pass "traces_spanmetrics_calls_total{app=\"$APP\"}" ||
	fail "no span-metrics for app=$APP"

printf '\n'
if [[ "$failed" -eq 0 ]]; then
	printf '\033[32mall required checks passed\033[0m\n'
else
	printf '\033[31m%d required check(s) failed\033[0m\n' "$failed"
fi
exit "$failed"
