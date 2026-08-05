#!/usr/bin/env bash
#
# Asserts that every signal arrives from the demo app, end to end, with the label
# contract intact and the three of them joinable. Run it a minute or so after
# `make demo-up`.
#
#   ./scripts/verify-signals.sh
#   OBS_APP=myapp PROM_URL=https://... ./scripts/verify-signals.sh
#
# Exit code is the number of failed checks, so it works in CI. Set STRICT_STEPS
# to a subset to let the rest report without failing the run.

set -uo pipefail

APP="${OBS_APP:-demo}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
SERVICE="${OBS_SERVICE:-api}"
STRICT_STEPS="${STRICT_STEPS:-1,2,3,4,5,6,7}"

failed=0
step=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

fail() {
	if [[ ",$STRICT_STEPS," == *",$step,"* ]]; then
		printf '  \033[31mFAIL\033[0m  %s\n' "$1"
		failed=$((failed + 1))
	else
		skip "$1  (not in STRICT_STEPS)"
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

check "span-metrics — Tempo's generator speaks the same label vocabulary"
sm_labels=$(curl -sG --max-time 10 "$PROM_URL/api/v1/query" \
	--data-urlencode "query=traces_spanmetrics_calls_total{app=\"$APP\",span_kind=\"SPAN_KIND_SERVER\",route!=\"\"}" |
	jq -r '[.data.result[0].metric | keys[]] | join(",")')
[[ "$sm_labels" == "__name__,app,env,route,service,span_kind,span_name,span_status,status_code" ]] &&
	pass "span-metric labels are [$sm_labels]" ||
	fail "span-metric labels are [$sm_labels] — Tempo's write_relabel_configs did not apply"

# The milestone assertion. `and` intersects on identical label sets, so a non-zero
# result means the app's own instrumentation and Tempo's generator describe the
# same request with the same five labels — which no rename or reverted config can
# fake. It is also what makes tracesToMetrics resolve.
n=$(promql "count(
  sum by (app,env,service,route,status_code) (traces_spanmetrics_calls_total{app=\"$APP\",span_kind=\"SPAN_KIND_SERVER\"})
  and
  sum by (app,env,service,route,status_code) (fastapi_requests_total{app=\"$APP\"})
)")
[[ "${n:-0}" -gt 0 ]] &&
	pass "span-metrics and fastapi_requests_total join on (app,env,service,route,status_code)" ||
	fail "no series joins fastapi_requests_total to traces_spanmetrics_calls_total"

check "service graph — Tempo's edges carry identity and cross services"
n=$(promql "count(traces_service_graph_request_total{app=\"$APP\",client=\"$APP-loadgen\",server=\"$APP-$SERVICE\"})")
[[ "${n:-0}" -gt 0 ]] && pass "edge $APP-loadgen → $APP-$SERVICE, labelled app=$APP" ||
	fail "no app-labelled service-graph edge from $APP-loadgen to $APP-$SERVICE"

printf '\n'
if [[ "$failed" -eq 0 ]]; then
	printf '\033[32mall required checks passed\033[0m\n'
else
	printf '\033[31m%d required check(s) failed\033[0m\n' "$failed"
fi
exit "$failed"
