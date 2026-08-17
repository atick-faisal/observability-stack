# The agent with its config baked in, for a platform that re-clones the repo on
# every deploy — Dokploy, Coolify. There, a bind-mounted repo file is empty or
# gone by the second deploy, so compose.agent.deploy.yml builds this instead of
# mounting config.alloy. Same reasoning as lgtm/*/Dockerfile on the server side.
#
# Keep the tag in step with compose.agent.yml's image.
FROM grafana/alloy:v1.16.1

COPY config.alloy /etc/alloy/config.alloy
