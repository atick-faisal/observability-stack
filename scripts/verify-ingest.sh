#!/usr/bin/env bash
#
# Asserts that the ingest endpoints are authenticated, rate-limited, and route to
# the three native upstream paths and nothing else. Run it against a stack brought
# up with the edge in front:
#
#   make demo-up EDGE=1 && ./scripts/verify-ingest.sh
#
# Exit code is the number of failed checks, so it works in CI.
#
# --resolve rather than DNS: the hostnames are the real ones from OBS_DOMAIN,
# whose records point at the VPS, and locally the edge is on this machine. curl -k
# because Let's Encrypt cannot have issued for a domain that does not resolve here,
# so Traefik serves its built-in self-signed certificate. Neither is papering over
# anything the deployed stack does differently — the routers, the middlewares and
# the credential are identical.

set -uo pipefail

if [[ -z "${OBS_DOMAIN:-}" && -f .env.lgtm ]]; then
	OBS_DOMAIN=$(sed -n 's/^OBS_DOMAIN=//p' .env.lgtm | tail -1)
fi
DOMAIN="${OBS_DOMAIN:-localhost}"
EDGE_ADDR="${EDGE_ADDR:-127.0.0.1}"
USER="${OBS_INGEST_USER:-demo}"
PASS="${OBS_INGEST_PASSWORD:-demo}"

HOST="ingest.$DOMAIN"

failed=0
step=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }

fail() {
	printf '  \033[31mFAIL\033[0m  %s\n' "$1"
	failed=$((failed + 1))
}

check() {
	step=$((step + 1))
	printf '\n%d. %s\n' "$step" "$1"
}

# Status code only, for a POST to the edge. The body is a caller's argument, not
# baked in: curl concatenates repeated -d with &, so a second one would corrupt it.
code() {
	local path="$1"
	shift
	curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
		--resolve "$HOST:443:$EDGE_ADDR" \
		-X POST "https://$HOST$path" "$@"
}

expect() {
	local want="$1" got="$2" what="$3"
	[[ "$got" == "$want" ]] && pass "$what → $got" || fail "$what → $got, expected $want"
}

printf 'edge: https://%s (resolved to %s), credential %s\n' "$HOST" "$EDGE_ADDR" "$USER"

check "the edge is answering at all"
if [[ -z "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$HOST:443:$EDGE_ADDR" "https://$HOST/" 2>/dev/null)" ]]; then
	fail "nothing responding on $EDGE_ADDR:443 — is the stack up with EDGE=1?"
	exit "$failed"
fi
pass "TLS handshake completes and Traefik responds"

check "no credential is rejected"
# 401 and not 404: the router matched, the middleware ran, and it is the auth that
# stopped the request. A 404 here would mean the router never matched and the
# endpoint is unauthenticated for a different reason.
expect 401 "$(code /api/v1/write -d '')" "POST /api/v1/write with no credential"
expect 401 "$(code /loki/api/v1/push -d '')" "POST /loki/api/v1/push with no credential"
expect 401 "$(code /v1/traces -d '')" "POST /v1/traces with no credential"

check "a wrong credential is rejected"
expect 401 "$(code /api/v1/write -d '' -u "$USER:definitely-not-the-password")" "wrong password"
expect 401 "$(code /api/v1/write -d '' -u "no-such-user:$PASS")" "unknown user"

check "the right credential reaches the backend"
# 400, not 200: the body is empty, so each backend parses it and rejects it. That
# is the point — a 400 can only come from the upstream, so auth passed and the
# proxying works. It is also what proves the $$-doubling in INGEST_USERS survived
# Compose, which a 401 could not distinguish from a typo.
expect 400 "$(code /api/v1/write -d '' -u "$USER:$PASS")" "prometheus remote-write"
expect 400 "$(code /loki/api/v1/push -d '' -u "$USER:$PASS")" "loki push"
# Tempo needs the content type — without one it answers 415 before it looks at the
# body. `{}` is a well-formed OTLP request carrying no spans, so this is the one
# backend that can be asked to *accept* something rather than reject it, which is
# a stronger statement than a 400.
expect 200 "$(code /v1/traces -u "$USER:$PASS" -H 'Content-Type: application/json' --data-binary '{}')" \
	"tempo OTLP/HTTP accepts a well-formed payload"

check "nothing else on the ingest host is reachable"
# Native upstream paths only. Every one of these is a real, useful endpoint on the
# backend it belongs to — a query API, a delete API, an admin UI — and none of them
# has a router, so none of them is exposed.
for path in /graph /-/quit /api/v1/query /api/v1/admin/tsdb/delete_series /loki/api/v1/query /ready /metrics /; do
	expect 404 "$(code "$path" -d '' -u "$USER:$PASS")" "POST $path"
done

check "the rate limit engages"
# 100/s average with a burst of 200. Fire enough, fast enough, that the bucket
# cannot keep up regardless of how quick the loop is.
# In parallel, and this matters: sequential curl invocations each pay process
# startup and a TLS handshake, which caps out well under 100/s and never trips a
# limit set at 100/s. The first version of this check passed a broken config.
#
# 400 requests was that fix, and it holds on a fast machine — but it is a
# knife-edge amount: measured on a GitHub-hosted runner, 400 requests at -P 50
# complete in ~2.1s (~190/s), and burst(200) + refill(100/s * 2.1s) is close
# enough to 400 that whether any single request lands past the bucket depends
# on how front-loaded that particular run happened to be, not on whether the
# limiter is wired up. 1500 requests at the same achieved rate runs for ~8s,
# by which point the bucket is oversubscribed by several hundred requests
# regardless of how that rate is distributed across the run.
requests=1500
hits=$(seq 1 "$requests" | xargs -P 50 -I{} \
	curl -sk -o /dev/null -w '%{http_code}\n' --max-time 5 \
	--resolve "$HOST:443:$EDGE_ADDR" "https://$HOST/api/v1/write" -u "$USER:$PASS" -X POST -d '' |
	grep -c 429)
[[ "$hits" -gt 0 ]] &&
	pass "$hits/$requests requests rate-limited with 429" ||
	fail "$requests requests, none rate-limited — obs-ingest-ratelimit is not applied"

printf '\n'
if [[ "$failed" -eq 0 ]]; then
	printf '\033[32mthe ingest endpoints are authenticated and scoped\033[0m\n'
else
	printf '\033[31m%d check(s) failed\033[0m\n' "$failed"
fi
exit "$failed"
