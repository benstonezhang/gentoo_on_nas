#!/bin/bash

if [ $USER != postgres ]; then
	echo "This script must be run as user postgres"
	exit 1
fi
if [ -z "$OSM_PASSWORD" ]; then
	echo "Environment OSM_PASSWORD must be set"
	exit 1
fi

PGHOST=${PGHOST:-"127.0.0.1"}
PGPORT=${PGPORT:-"5432"}
PGDATABASE=${PGDATABASE:-"osm"}
PGUSER=${PGUSER:-"osm"}

createuser --no-superuser --no-createrole --createdb "${PGUSER}"
createdb -E UTF8 -O "${PGUSER}" "${PGDATABASE}"

cat <<EOF | psql -d "${PGDATABASE}"
ALTER USER '${PGUSER}' WITH PASSWORD '${OSM_PASSWORD}';
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
-- Extensions needed for OpenMapTiles
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS osml10n;
CREATE EXTENSION IF NOT EXISTS gzip;
EOF

# check the pg_hba.conf file below has the correct path
cat <<EOF
You may need to update pg_hba.conf, add below and restart postgresql!:
===============================================================================
host	${PGDATABASE}	${PGUSER}	127.0.0.1/32		scram-sha-256
===============================================================================

echo "Done."
EOF
