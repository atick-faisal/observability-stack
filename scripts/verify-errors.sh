#!/usr/bin/env bash
#
# Asserts that an unhandled exception in the demo app becomes an issue in GlitchTip,
# tagged with the same app/env/host values the metrics, logs and traces carry.
#
#   make glitchtip-up
#   ./scripts/verify-errors.sh --bootstrap        # first run: mints an org + project
#   OBS_ERROR_DSN=<printed DSN> make demo-up
#   ./scripts/verify-errors.sh
#
# Exit code is the number of failed checks, so it works in CI.
#
# Reads go through `manage.py shell` rather than GlitchTip's REST API. The API is
# the right tool from outside, but every read on it needs an auth token that only
# exists once someone has logged into the UI — and a verification script that
# cannot run until a human has clicked through a web app is not a verification
# script. This is our own container on our own box; the ORM is the honest path.

set -uo pipefail

PROJECT_SLUG="${GLITCHTIP_PROJECT:-demo-api}"
ORG_SLUG="${GLITCHTIP_ORG:-demo}"
BOOTSTRAP_EMAIL="${GLITCHTIP_EMAIL:-demo@example.com}"
DEMO_API_URL="${DEMO_API_URL:-http://localhost:8000}"
GLITCHTIP_HEALTH_URL="${GLITCHTIP_HEALTH_URL:-http://localhost:8001/_health/}"
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-observability}"
STRICT_STEPS="${STRICT_STEPS:-1,2,3,4,5}"

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

# Resolved by compose labels rather than by name, so a different project name or a
# `-p` flag does not break this.
container_for() {
	docker ps -aq \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
		--filter "label=com.docker.compose.service=$1" | head -1
}

# Runs Python inside glitchtip-web. Only lines the snippet prefixes with RESULT=
# are returned, so Django's startup banner and warnings cannot be mistaken for
# output.
gt_py() {
	docker exec -i "$WEB" sh -c 'cd /code && ./manage.py shell' 2>/dev/null |
		sed -n 's/^RESULT=//p'
}

WEB="$(container_for glitchtip-web)"
if [[ -z "$WEB" ]]; then
	printf '\033[31mglitchtip-web is not running — `make glitchtip-up` first\033[0m\n'
	exit 1
fi

if [[ "${1:-}" == "--bootstrap" ]]; then
	printf 'Creating organisation %s, project %s and an owner (%s)…\n\n' \
		"$ORG_SLUG" "$PROJECT_SLUG" "$BOOTSTRAP_EMAIL"
	# What the UI does on first signup, minus the signup: GlitchTip ships with
	# ENABLE_USER_REGISTRATION unset to true, and .env.glitchtip.example turns it
	# off, so the first account has to come from somewhere else.
	dsn="$(gt_py <<-PY
		from django.apps import apps
		from django.contrib.auth import get_user_model

		Org = apps.get_model("organizations_ext", "Organization")
		OrgUser = apps.get_model("organizations_ext", "OrganizationUser")
		Team = apps.get_model("teams", "Team")
		Project = apps.get_model("projects", "Project")
		ProjectKey = apps.get_model("projects", "ProjectKey")

		user, _ = get_user_model().objects.get_or_create(
		    email="$BOOTSTRAP_EMAIL", defaults={"is_superuser": True, "is_staff": True}
		)
		org, _ = Org.objects.get_or_create(name="$ORG_SLUG", defaults={"slug": "$ORG_SLUG"})
		OrgUser.objects.get_or_create(user=user, organization=org, defaults={"role": 0})
		team, _ = Team.objects.get_or_create(organization=org, slug="$ORG_SLUG")
		project, _ = Project.objects.get_or_create(
		    organization=org, slug="$PROJECT_SLUG",
		    defaults={"name": "$PROJECT_SLUG", "platform": "python"},
		)
		project.teams.add(team)
		key = ProjectKey.objects.filter(project=project).first()
		print("RESULT=http://%s@glitchtip-web:8000/%d" % (key.public_key_hex, project.id))
	PY
	)"
	if [[ -z "$dsn" ]]; then
		printf '\033[31mbootstrap failed\033[0m\n'
		exit 1
	fi
	printf 'Set a password for %s to log in at http://localhost:8001:\n' "$BOOTSTRAP_EMAIL"
	printf '  docker exec -it %s ./manage.py changepassword %s\n\n' "$WEB" "$BOOTSTRAP_EMAIL"
	printf 'Then point the demo at it:\n  OBS_ERROR_DSN=%s make demo-up\n' "$dsn"
	exit 0
fi

printf 'Verifying error reporting  project=%s\n' "$PROJECT_SLUG"

# ── 1 ─────────────────────────────────────────────────────────────────────
check "glitchtip-web is serving"
code="$(curl -s -o /dev/null -w '%{http_code}' "$GLITCHTIP_HEALTH_URL")"
if [[ "$code" == "200" ]]; then
	pass "$GLITCHTIP_HEALTH_URL -> 200"
else
	fail "$GLITCHTIP_HEALTH_URL -> ${code:-no response}"
fi

# ── 2 ─────────────────────────────────────────────────────────────────────
# The one ordering that matters: web must never boot against an unmigrated schema.
check "glitchtip-migrate ran to completion"
migrate="$(container_for glitchtip-migrate)"
if [[ -z "$migrate" ]]; then
	fail "no glitchtip-migrate container"
else
	state="$(docker inspect "$migrate" --format '{{.State.Status}}:{{.State.ExitCode}}')"
	if [[ "$state" == "exited:0" ]]; then
		pass "migrate exited 0"
	else
		fail "migrate is $state, expected exited:0"
	fi
fi

# ── 3 ─────────────────────────────────────────────────────────────────────
check "demo-api is configured with a DSN this GlitchTip issued"
api="$(container_for demo-api)"
dsn=""
if [[ -n "$api" ]]; then
	dsn="$(docker exec "$api" printenv OBS_ERROR_DSN 2>/dev/null)"
fi
if [[ -z "$dsn" ]]; then
	fail "OBS_ERROR_DSN is not set on demo-api — OBS_ERROR_DSN=... make demo-up"
else
	# http://<public key>@<host>:<port>/<project id>
	dsn_key="${dsn#*//}"
	dsn_key="${dsn_key%%@*}"
	known="$(gt_py <<-PY
		from django.apps import apps
		ProjectKey = apps.get_model("projects", "ProjectKey")
		match = [
		    k for k in ProjectKey.objects.filter(project__slug="$PROJECT_SLUG")
		    if k.public_key_hex == "$dsn_key"
		]
		print("RESULT=%d" % len(match))
	PY
	)"
	if [[ "$known" == "1" ]]; then
		pass "DSN key matches a key on project $PROJECT_SLUG"
	else
		fail "DSN key ${dsn_key:0:8}… is not a key of project $PROJECT_SLUG"
	fi
fi

# ── 4 ─────────────────────────────────────────────────────────────────────
check "an unhandled exception reaches GlitchTip"
count_events() {
	gt_py <<-PY
		from django.apps import apps
		IssueEvent = apps.get_model("issue_events", "IssueEvent")
		print("RESULT=%d" % IssueEvent.objects.filter(issue__project__slug="$PROJECT_SLUG").count())
	PY
}
before="$(count_events)"
curl -s -o /dev/null "$DEMO_API_URL/boom"
after="$before"
for _ in $(seq 1 20); do
	after="$(count_events)"
	[[ -n "$after" && -n "$before" && "$after" -gt "$before" ]] && break
	sleep 2
done
if [[ -n "$after" && -n "$before" && "$after" -gt "$before" ]]; then
	pass "events on $PROJECT_SLUG: $before -> $after"
else
	fail "no new event after GET /boom (events stayed at ${before:-?})"
fi

# ── 5 ─────────────────────────────────────────────────────────────────────
# The reason this milestone exists at all. An error nobody can pin to a service,
# an environment and a host is an error nobody can pull the other three signals for.
check "the event carries the label contract"
tags="$(gt_py <<-PY
	from django.apps import apps
	IssueEvent = apps.get_model("issue_events", "IssueEvent")
	event = (
	    IssueEvent.objects.filter(issue__project__slug="$PROJECT_SLUG")
	    .order_by("-timestamp")
	    .first()
	)
	tags = event.tags or {}
	print("RESULT=%s|%s|%s|%s" % (
	    event.transaction, tags.get("environment"), tags.get("release"), tags.get("server_name"),
	))
PY
)"
IFS='|' read -r ev_transaction ev_env ev_release ev_host <<<"$tags"
for probe in "transaction:$ev_transaction:/boom" "environment:$ev_env:local" \
	"release:$ev_release:demo-api@0.1.0" "server_name:$ev_host:demo-host"; do
	name="${probe%%:*}"
	rest="${probe#*:}"
	got="${rest%%:*}"
	want="${rest#*:}"
	if [[ "$got" == "$want" ]]; then
		pass "$name = $got"
	else
		fail "$name = ${got:-<empty>}, expected $want"
	fi
done

printf '\n'
if ((failed == 0)); then
	printf '\033[32mall checks passed\033[0m\n'
else
	printf '\033[31m%d check(s) failed\033[0m\n' "$failed"
fi
exit "$failed"
