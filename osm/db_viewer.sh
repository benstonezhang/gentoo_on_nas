#!/bin/bash

if [ $USER != postgres ]; then
	echo "This script must be run as user postgres"
	exit 1
fi
if [ -z "$OSM_VIEWER_PASSWORD" ]; then
	echo "Environment OSM_VIEWER_PASSWORD must be set"
	exit 1
fi

PGHOST=${PGHOST:-"127.0.0.1"}
PGPORT=${PGPORT:-"5432"}
PGDATABASE=${PGDATABASE:-"osm"}
PGUSER=${PGUSER:-"osm_viewer"}

cat <<EOF | psql -d "${PGDATABASE}"
CREATE ROLE readaccess;
GRANT CONNECT ON DATABASE '${PGDATABASE}' TO readaccess;
GRANT USAGE ON SCHEMA public TO readaccess;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readaccess;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readaccess;
CREATE USER '${PGUSER}' WITH PASSWORD '${OSM_VIEWER_PASSWORD}';
GRANT readaccess TO '${PGUSER}';
EOF

