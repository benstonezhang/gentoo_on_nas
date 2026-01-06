#!/bin/bash

if [ $USER != postgres ]; then
	echo "This script must be run as user postgres"
	exit 1
fi
if [ -z "$OSM_VIEWER_PASSWORD" ]; then
	echo "Environment OSM_VIEWER_PASSWORD must be set"
	exit 1
fi

cat <<EOF | psql -d osm
CREATE ROLE readaccess;
GRANT CONNECT ON DATABASE osm TO readaccess;
GRANT USAGE ON SCHEMA public TO readaccess;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readaccess;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readaccess;
CREATE USER osm_viewer WITH PASSWORD '$OSM_VIEWER_PASSWORD';
GRANT readaccess TO osm_viewer;
EOF

