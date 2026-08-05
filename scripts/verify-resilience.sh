#!/usr/bin/env bash
#
# Takes the server down for a quarter of an hour while the app keeps serving, and
# asserts that all three signals come back with no hole where the outage was.
#
#   make demo-up && sleep 120          # give every signal a baseline first
#   ./scripts/verify-resilience.sh
#   OUTAGE_SECONDS=120 ./scripts/verify-resilience.sh    # short, for iterating
#
# Exit code is the number of failed checks, so it works in CI. It takes
# OUTAGE_SECONDS plus a drain, so budget about twenty minutes at the default.
#
# The point is not that the stack restarts — it is that the *agent* held on to
# what it could not deliver and replayed it with the original timestamps, so the
# dashboards show a continuous line rather than a gap that has to be explained.
# Three separate mechanisms have to work for that, one per signal, and each has
# its own server-side window that has to be at least as generous:
#
#   metrics  prometheus.remote_write wal    ↔  tsdb.out_of_order_time_window 2h
#   logs     loki.write wal                 ↔  reject_old_samples_max_age 168h
#   traces   otelcol sending_queue on disk  ↔  (none — Tempo takes any timestamp)
#
# The last check exists because the three before it could all pass on retries
# alone, with every buffer still in memory and none of this milestone's work
# doing anything. It reads Alloy's own metrics mid-outage to prove the bytes were
# on disk.
#
# It does NOT call `make demo-down`: that removes observability_alloy_data, which
# is where all three buffers live. Stopping the containers is the whole test;
# deleting the volume would be the opposite of it.

set -uo pipefail

APP="${OBS_APP:-demo}"
SERVICE="${OBS_SERVICE:-api}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
ALLOY_URL="${ALLOY_URL:-http://localhost:12345}"
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-observability}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-900}"
# Measured on a 901s outage: the replay reached the end of the window a little
# over seven minutes after the restart. 900 is that with room, and it is a
# timeout rather than a wait — the poll below exits as soon as the data is there.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-900}"
SERVER_SVCS="${SERVER_SVCS:-prometheus loki tempo grafana}"
STRICT_STEPS="${STRICT_STEPS:-1,2,3,4,5,6,7}"

failed=0
step=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

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

# BSD date takes -r for an epoch, GNU date takes -d @. The agent half of this
# repo runs on Linux and the demo runs on a Mac, so neither can be assumed.
hhmmss() {
	date -u -r "$1" +%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%H:%M:%SZ 2>/dev/null || echo "$1"
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

# One gauge out of Alloy's own /metrics, by exact metric name and an optional
# label substring. Alloy is never stopped, so this is readable throughout.
alloy_metric() {
	curl -s --max-time 10 "$ALLOY_URL/metrics" |
		awk -v m="$1" -v sel="${2:-}" '
			index($0, m "{") == 1 && (sel == "" || index($0, sel) > 0) { print $NF; exit }
		'
}

# ── 1. preconditions ────────────────────────────────────────────────────────

check "preconditions — the pipeline is working before anything is broken"

for svc in alloy demo-api demo-loadgen $SERVER_SVCS; do
	running "$svc" || {
		printf '  \033[31mFAIL\033[0m  %s is not running — run `make demo-up` first\n\n' "$svc"
		exit 1
	}
done
pass "alloy, demo-api, demo-loadgen and $SERVER_SVCS are up"

baseline=$(curl -sG --max-time 10 "$PROM_URL/api/v1/query" \
	--data-urlencode "query=count(fastapi_requests_total{app=\"$APP\",service=\"$SERVICE\"})" |
	jq -r '.data.result[0].value[1] // "0"')
if [[ ${baseline:-0} -gt 0 ]]; then
	pass "$baseline fastapi_requests_total series before the outage"
else
	printf '  \033[31mFAIL\033[0m  no baseline metrics — wait a minute after `make demo-up` and retry\n\n'
	exit 1
fi

[[ "$(alloy_metric loki_write_wal_watcher_running)" == "1" ]] &&
	pass "loki.write WAL watcher is running" ||
	fail "loki.write has no WAL watcher — is the wal block in config.alloy?"

qcap=$(alloy_metric otelcol_exporter_queue_capacity 'data_type="traces"')
qcap="${qcap:-0}"
[[ ${qcap%.*} -gt 1000 ]] &&
	pass "trace sending_queue capacity is ${qcap%.*}" ||
	fail "trace sending_queue capacity is ${qcap:-unset} — the exporter is on defaults"

wal_ts_before=$(alloy_metric loki_write_wal_writer_last_written_timestamp)

# ── 2. the outage ───────────────────────────────────────────────────────────

check "outage — stopping $SERVER_SVCS for ${OUTAGE_SECONDS}s while the app keeps serving"

for svc in $SERVER_SVCS; do docker stop "$(container_for "$svc")" >/dev/null; done
t0=$(date +%s)
info "stopped at $(hhmmss "$t0")"

# Sampled at the end rather than the start: buffering for one second proves
# nothing, buffering for fifteen minutes is the claim.
sleep "$((OUTAGE_SECONDS > 30 ? OUTAGE_SECONDS - 20 : OUTAGE_SECONDS))"
qsize_mid=$(alloy_metric otelcol_exporter_queue_size 'data_type="traces"')
wal_ts_mid=$(alloy_metric loki_write_wal_writer_last_written_timestamp)
[[ $OUTAGE_SECONDS -gt 30 ]] && sleep 20

for svc in $SERVER_SVCS; do docker start "$(container_for "$svc")" >/dev/null; done
t1=$(date +%s)
info "restarted at $(hhmmss "$t1") — outage was $((t1 - t0))s"

# The window the assertions below are made over: strictly inside the outage, so
# nothing they find can have been written live. The margin is a quarter of the
# outage, capped at a minute — a fixed 60s would invert the window whenever
# OUTAGE_SECONDS is set low for a quick run, and an inverted window is a query
# that returns nothing for a reason that has nothing to do with the stack.
margin=$(((t1 - t0) / 4))
[[ $margin -gt 60 ]] && margin=60
[[ $margin -lt 5 ]] && margin=5
inner_start=$((t0 + margin))
inner_end=$((t1 - margin))

# ── 3. drain ────────────────────────────────────────────────────────────────

check "drain — waiting for the agent to reconnect and replay"

# remote_write backs off up to 5m, so the reconnect is not immediate and polling
# is the honest way to wait for it.
#
# The condition is the *newest* bucket the assertions below need, not one from
# inside the outage. The WAL replays in order, so a sample from the middle of the
# outage proves the replay started, not that it finished — waiting on that and
# then asserting reports "19/20 buckets, there is a hole" for a window that turns
# out to be complete a minute later. Measured: on a 901s outage the middle of the
# window was back after 372s and the end of it roughly a minute after that.
#
# Waiting for the last bucket is the same thing as waiting for the agent to catch
# up with the present, and it cannot be satisfied early or by live traffic: t1+120
# has not happened yet when the polling starts, so the query is empty until both
# the clock and the replay have passed it. It subsumes the wall-clock wait this
# used to do, and it covers Loki and Tempo too — they drain faster than the WAL.
catchup=$((t1 + 120))
deadline=$(($(date +%s) + DRAIN_TIMEOUT))
drained=0
while [[ $(date +%s) -lt $deadline ]]; do
	n=$(curl -sG --max-time 10 "$PROM_URL/api/v1/query" \
		--data-urlencode "query=count_over_time(fastapi_requests_total{app=\"$APP\",service=\"$SERVICE\"}[1m])" \
		--data-urlencode "time=$catchup" | jq -r '.data.result | length' 2>/dev/null)
	if [[ ${n:-0} -gt 0 ]]; then
		drained=1
		break
	fi
	sleep 10
done
if [[ $drained -eq 1 ]]; then
	pass "replayed up to the end of the window after $(($(date +%s) - t1))s"
else
	fail "the replay had not reached $(hhmmss "$catchup") after ${DRAIN_TIMEOUT}s — the rest will fail for that reason"
fi

# ── 4. the assertions ───────────────────────────────────────────────────────

check "metrics — no gap in fastapi_requests_total across the outage"

# Every 60s bucket from two minutes before the outage to two minutes after must
# contain at least one sample. A bucket with no data yields no series at that
# step and simply vanishes from the result, so counting the points IS the gap
# check — there is no null to look for.
range=$(curl -sG --max-time 30 "$PROM_URL/api/v1/query_range" \
	--data-urlencode "query=sum(count_over_time(fastapi_requests_total{app=\"$APP\",service=\"$SERVICE\"}[1m]))" \
	--data-urlencode "start=$((t0 - 120))" --data-urlencode "end=$((t1 + 120))" \
	--data-urlencode "step=60")
got=$(jq -r '(.data.result[0].values // []) | length' <<<"$range" 2>/dev/null)
empty=$(jq -r '[.data.result[0].values[]? | select((.[1] | tonumber) == 0)] | length' <<<"$range" 2>/dev/null)
expected=$(((t1 + 120 - (t0 - 120)) / 60 + 1))

if [[ ${got:-0} -eq $expected ]] && [[ ${empty:-1} -eq 0 ]]; then
	pass "$got/$expected 60s buckets present, none empty"
else
	fail "$got/$expected 60s buckets present, $empty empty — there is a hole in the metrics"
fi

check "logs — lines written during the outage reached Loki, with their own timestamps"

# direction=forward matters. Loki answers backward by default, so a limited query
# returns the *newest* lines in the window — and a WAL that replayed only the last
# minute and dropped the rest would satisfy that query exactly as well as one that
# replayed everything. Forward makes the first returned line the first line of the
# outage, which is the half that gets dropped when a retry budget runs out.
lines=$(curl -sG --max-time 30 "$LOKI_URL/loki/api/v1/query_range" \
	--data-urlencode "query={app=\"$APP\",service=\"$SERVICE\"}" \
	--data-urlencode "start=${inner_start}000000000" \
	--data-urlencode "end=${inner_end}000000000" \
	--data-urlencode "direction=forward" \
	--data-urlencode "limit=100")
n=$(jq -r '[.data.result[]?.values[]?] | length' <<<"$lines" 2>/dev/null)
if [[ ${n:-0} -gt 0 ]]; then
	# And the timestamps have to be inside the window, not merely returned by a
	# query that named it — a line stamped at replay time would be the failure the
	# WAL exists to prevent, and it would look identical from the count alone.
	oldest=$(jq -r '[.data.result[]?.values[]?[0] | tonumber] | min / 1000000000 | floor' <<<"$lines")
	# Within a minute of the outage starting: the app logs several lines a second,
	# so anything later means the beginning of the buffer did not survive.
	if [[ $oldest -ge $((inner_start - 5)) ]] && [[ $oldest -le $((inner_start + 60)) ]]; then
		pass "$n lines backfilled, earliest at $(hhmmss "$oldest"), $((oldest - t0))s into the outage"
	else
		fail "$n lines returned but the earliest is at $(hhmmss "$oldest"), $((oldest - t0))s into a $((t1 - t0))s outage — the start of the buffer was lost"
	fi
else
	fail "no log lines in the outage window — the loki.write WAL did not replay"
fi

check "traces — spans emitted during the outage reached Tempo"

# Resolved by trace_id out of a log line from the first minute of the outage,
# not by /api/search over that window.
#
# Measured, and the reason this check is written the awkward way: a search
# bounded to the outage window returns *nothing* for the first ten minutes of a
# fifteen-minute one, while `GET /api/traces/<id>` on a trace from that same
# minute returns 200 with both services on it. The spans are stored; Tempo's
# time-bounded search does not surface backfilled ones. An operator who searches
# the outage window will conclude the traces were lost, and be wrong — which is
# worth knowing, but is a fact about Tempo's query path, not about whether the
# agent's queue held. This asserts the latter.
#
# The first minute matters because the queue drains oldest-first: the entries
# written earliest are exactly the ones a too-small queue or a retry timeout
# throws away.
tid=$(curl -sG --max-time 30 "$LOKI_URL/loki/api/v1/query_range" \
	--data-urlencode "query={app=\"$APP\",service=\"$SERVICE\"}" \
	--data-urlencode "start=${inner_start}000000000" \
	--data-urlencode "end=$((inner_start + 60))000000000" \
	--data-urlencode "direction=forward" --data-urlencode "limit=20" |
	jq -r '[.data.result[]?.stream.trace_id // empty] | first // ""')

if [[ -z $tid ]]; then
	fail "no log line from the first minute of the outage carried a trace_id"
else
	svc=$(curl -s --max-time 30 "$TEMPO_URL/api/traces/$tid" |
		jq -r '[.batches[]?.resource.attributes[]? | select(.key=="service.name") | .value.stringValue] | unique | join(",")')
	if [[ $svc == *"$APP-$SERVICE"* ]]; then
		pass "trace $tid, from the first minute of the outage, resolves in Tempo [$svc]"
	else
		fail "trace $tid from a backfilled log line does not resolve in Tempo — the queue dropped its oldest entries"
	fi
fi

# ── 5. the mechanism, not just the outcome ──────────────────────────────────

check "buffers — the data was on disk during the outage, not merely retried"

wal_ts_after=$(alloy_metric loki_write_wal_writer_last_written_timestamp)
if awk -v a="${wal_ts_before:-0}" -v b="${wal_ts_mid:-0}" 'BEGIN { exit !(b > a) }'; then
	pass "loki.write WAL kept being written to while Loki was down"
else
	fail "loki.write WAL writer did not advance during the outage (before=$wal_ts_before mid=$wal_ts_mid after=$wal_ts_after)"
fi

if [[ ${qsize_mid%.*} -gt 0 ]]; then
	pass "trace queue held ${qsize_mid%.*} batches mid-outage instead of dropping them"
else
	fail "trace queue was empty mid-outage — with Tempo down that means spans were discarded"
fi

printf '\n'
if [[ $failed -eq 0 ]]; then
	printf '\033[32mall required checks passed\033[0m — %ss outage, no gap in any signal\n\n' "$((t1 - t0))"
else
	printf '\033[31m%d required check(s) failed\033[0m\n\n' "$failed"
fi
exit "$failed"
