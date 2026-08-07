FROM grafana/grafana:13.0.1

# Not /var/lib/grafana/dashboards, the path Grafana's own docs use: that directory
# is inside the grafana_data volume, and a named volume only inherits image
# content when it is first created. On any existing volume the baked dashboards
# would be shadowed and silently absent. /etc/grafana is covered by no volume.
COPY provisioning /etc/grafana/provisioning
COPY dashboards /etc/grafana/dashboards
