#!/usr/bin/env bash
#
# Mints one ingest credential — one per app+env, so a single app can be rotated
# in isolation and the username identifies it in Traefik's access log.
#
#   ./scripts/add-ingest-user.sh myapp-production
#   ./scripts/add-ingest-user.sh myapp-production 'a-password-you-chose'
#
# Prints two things: what to put in the app host's observability/.env.agent, and
# what to append to INGEST_USERS in the server's .env.lgtm. It edits neither —
# .env.lgtm may already hold other credentials, and a script that rewrites a
# secrets file is a script that can lose one.
#
# The hash is printed with every $ doubled. That is not decoration: Compose
# interpolates values it reads from --env-file, so a bcrypt hash written with
# single $ arrives at Traefik mangled, and the symptom is a 401 that looks exactly
# like a wrong password. scripts/verify-ingest.sh is what proves it round-trips.

set -euo pipefail

user="${1:-}"
if [[ -z "$user" ]]; then
	echo "usage: $0 <app>-<env> [password]" >&2
	exit 2
fi
if [[ ! "$user" =~ ^[a-z0-9-]+$ ]]; then
	echo "username must be [a-z0-9-]+ (it becomes a label value and a log field)" >&2
	exit 2
fi

password="${2:-}"
if [[ -z "$password" ]]; then
	# Alphanumeric only. It travels through a .env file, a Compose env_file and an
	# Alloy sys.env() call, and every punctuation class has a quoting rule in at
	# least one of them.
	password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
fi

# bcrypt, not the default MD5. apache2-utils is not installed everywhere, and
# needing it to add a user on a box that already runs Docker is a poor trade.
if command -v htpasswd >/dev/null 2>&1; then
	entry=$(htpasswd -nbB "$user" "$password")
else
	entry=$(docker run --rm httpd:2-alpine htpasswd -nbB "$user" "$password")
fi

# sed, not ${entry//$/$$}: bash expands $$ in a replacement to its own PID, which
# produces a plausible-looking hash that is silently wrong.
doubled=$(printf '%s' "$entry" | sed 's/\$/$$/g')

cat <<EOF

  On the app host, in observability/.env.agent:

    OBS_INGEST_USER=$user
    OBS_INGEST_PASSWORD=$password

  On the server, appended to INGEST_USERS in .env.lgtm (comma-separated if it
  already has entries — note the doubled \$\$, which Compose collapses back):

    $doubled

  Then \`make lgtm-up\` to re-read it, and ./scripts/verify-ingest.sh to prove it works.

EOF
