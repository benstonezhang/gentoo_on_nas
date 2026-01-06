#!/bin/bash

if [ $USER != postgres ]; then
	echo "This script must be run as user postgres"
	exit 1
fi
if [ -z "$OSM_PASSWORD" ]; then
	echo "Environment OSM_PASSWORD must be set"
	exit 1
fi

createuser --no-superuser --no-createrole --createdb osm
createdb -E UTF8 -O osm osm

cat <<EOF | psql -d osm
alter user osm with password '$OSM_PASSWORD';
create extension if not exists postgis;
create extension if not exists hstore;
create extension if not exists fuzzystrmatch;
create extension if not exists pg_stat_statements;
-- Extensions needed for OpenMapTiles
create extension if not exists unaccent;
create extension if not exists osml10n;
create extension if not exists gzip;
EOF

# check the pg_hba.conf file below has the correct path
cat <<EOF
You may need to update pg_hba.conf, add below and restart postgresql!:
===============================================================================
host	osm		osm		127.0.0.1/32		scram-sha-256
===============================================================================

echo "Done."
EOF
