#!/bin/bash

SRC_DIR=${SRC_DIR:-"$HOME/src"}
MAPS_DIR=${MAPS_DIR:-"$PWD/maps"}
IMPORT_DIR=${IMPORT_DIR:-"$PWD/import"}
MAP_SERVICE_URL=${MAP_SERVICE_URL:-}

PGHOST=${PGHOST:-"127.0.0.1"}
PGPORT=${PGPORT:-"5432"}
PGDATABASE=${PGDATABASE:-"osm"}
PGUSER=${PGUSER:-"osm"}

#OSM_PUB_PBF='https://planet.openstreetmap.org/pbf'
OSM_MIRROR=${OSM_MIRROR:-'https://planet.osm.org'}
#OSM_MIRROR='https://ftp5.gwdg.de/pub/misc/openstreetmap/planet.openstreetmap.org'
#OSM_MIRROR='https://planet.maps.mail.ru'
#OSM_MIRROR='https://ftpmirror.your.org/pub/openstreetmap'

# OSM_SERVERS='geofabrik osmfr bbbike'
# http://download.geofabrik.de/
# https://download.openstreetmap.fr/extracts/
# https://download.bbbike.org/osm/

OSM_PBF_TORRENT="${OSM_MIRROR}/pbf/planet-latest.osm.pbf.torrent"
OSM_DAILY_STATE="${OSM_MIRROR}/replication/day/state.txt"

if [ -z "$PGPASSWORD" ]; then
	PGPASSWORD=$(grep "$PGHOST:$PGPORT:$PGDATABASE:$PGUSER:" "${HOME}/.pgpass" | awk 'BEGIN {FS=":"} {print $5}')
fi

if [ -z "$PGPASSWORD" ]; then
	echo "PostgreSQL password must present in $HOME/.pgpass or environment PGPASSWORD" >&2
	exit 1
fi

export PGPASSWORD="$PGPASSWORD"
export PGCLIENTENCODING="UTF8"

PGCONN="dbname=$PGDATABASE user=$PGUSER host=$PGHOST password=$PGPASSWORD port=$PGPORT"
PSQL_CLI="psql -h $PGHOST -p $PGPORT -d $PGDATABASE -U $PGUSER -v ON_ERROR_STOP=1 -c \\timing"

NATURAL_EARTH_VECTOR_VERSION=v5.1.2
#NATURAL_EARTH_VECTOR_URL='https://naciscdn.org/naturalearth/packages/natural_earth_vector.sqlite.zip'
NATURAL_EARTH_VECTOR_URL="https://dev.maptiler.download/geodata/omt/natural_earth_vector.sqlite_${NATURAL_EARTH_VECTOR_VERSION}.zip"

WATER_TABLE_NAME=osm_ocean_polygon
LAKE_CENTERLINE_TABLE=lake_centerline

OPENMAPTILES_GIT=https://github.com/benstonezhang/openmaptiles.git
OPENMAPTILES_SRC="${SRC_DIR}/openmaptiles"
OPENMAPTILES_VERSION=v3.16

OPENMAPTILES_TOOLS_GIT=https://github.com/benstonezhang/openmaptiles-tools.git
OPENMAPTILES_TOOLS_SRC="${SRC_DIR}/openmaptiles-tools"
OPENMAPTILES_TOOLS_VERSION=v7.2.0
export PYTHONPATH=${OPENMAPTILES_TOOLS_SRC}

SPRITEZERO_PYTHON_GIT=https://github.com/benstonezhang/spritezero_python.git
SPRITEZERO_PYTHON_SRC="${SRC_DIR}/spritezero_python"

IMPOSM_CONFIG="${IMPORT_DIR}/config.json"

function usage() {
	set +x
	cat <<EOF
Usage: $0 [env|build|import|read|read2|write|autodiff|diff|tables|cache_tiles] ...

Please follow steps below:
   1. source your python virtual environment
   2. prepare sources and install python packages:	$0 env
   3. build style and sprite:				$0 build
   4. import additional resource:			$0 import
   5. convert osm pbf file to leveldb:			$0 read [planet-yymmdd.osm.pbf]
      (optional) add more pbf files:			$0 read2 [region-yymmdd.osm.pbf]
   6. write data from leveldb to postgresql:		$0 write
      (generate derivative tables and indices then public tables and views)
   7. create tables and functions for query:		$0 tables
   8. (optional) pre-generate nginx cache:		$0 cache_tiles
EOF
	exit 1
}

function get_natural_earth_clean_tables() {
	cat <<EOF | sqlite3 "$1"
select name from sqlite_master
WHERE type='table' AND name like 'ne%' and name not in (
'ne_10m_admin_0_boundary_lines_land',
'ne_10m_admin_0_countries',
'ne_10m_admin_0_boundary_lines_map_units',
'ne_10m_admin_1_states_provinces',
'ne_10m_admin_1_states_provinces_lines',
'ne_10m_antarctic_ice_shelves_polys',
'ne_10m_geography_marine_polys',
'ne_10m_glaciated_areas',
'ne_10m_lakes',
'ne_10m_ocean',
'ne_10m_populated_places',
'ne_10m_urban_areas',
'ne_50m_admin_0_boundary_lines_land',
'ne_50m_antarctic_ice_shelves_polys',
'ne_50m_glaciated_areas',
'ne_50m_lakes',
'ne_50m_ocean',
'ne_50m_rivers_lake_centerlines',
'ne_50m_urban_areas',
'ne_110m_admin_0_boundary_lines_land',
'ne_110m_glaciated_areas',
'ne_110m_lakes',
'ne_110m_ocean',
'ne_110m_rivers_lake_centerlines');
EOF
}

function generate_clean_natural_earth_sql() {
	for x in $(get_natural_earth_clean_tables "$1"); do
		cat <<EOF
DROP TABLE $x;
DELETE FROM geometry_columns WHERE f_table_name = '$x';
EOF
	done
	echo "VACUUM;"
}

function clean_natural_earth() {
	echo "Cleaning up: removing all unneeded tables. Initial size $(du -h "$1" | cut -f1)"
	set +x
	generate_clean_natural_earth_sql "$1" | sqlite3 "$1"
	set -x
	echo "Done: final size $(du -h "$1" | cut -f1)"
}

function import_tables() {
	if [ -d "$1" ]; then
		find "$1" -name "*.sql" -print0 | xargs -0 -I{} $PSQL_CLI -f "{}"
	else
		$PSQL_CLI -f "$1"
	fi
}

function bulk_import_tables() {
	# Assume this dir may contain run_first.sql, parallel/*.sql, and run_last.sql
	if [ -f "$1/run_first.sql" ]; then
		$PSQL_CLI -f "$1/run_first.sql"
	else
		echo "File $1/run_first.sql not found, skipping" >&2
	fi
	find "$1/parallel" -name "*.sql" -print0 | xargs -0 -I{} --max-procs=4 $PSQL_CLI -f "{}"
	if [ -f "$1/run_last.sql" ]; then
		$PSQL_CLI -f "$1/run_last.sql"
	else
		echo "File $1/run_last.sql not found, skipping" >&2
	fi
}

function gen_imposm_conf() {
	cat <<EOF > "${IMPOSM_CONFIG}"
{
	"mapping": "${IMPORT_DIR}/openmaptiles-mapping.yaml",
	"cachedir": "${IMPORT_DIR}/cache",
	"diffdir": "${IMPORT_DIR}/diff",
	"connection": "postgis://${PGUSER}:$PGPASSWORD@localhost:$PGPORT/${PGDATABASE}",
	"replication_url": "${OSM_MIRROR}/replication/day/",
	"replication_interval": "24h",
	"srid": 3857
}
EOF
	cat "${IMPOSM_CONFIG}"
}

function gen_tiles_url() {
	set +x
	for z in $(seq $1 $2); do
		limit=$(echo "2^$z-1" | bc)
		if [ $z -eq 0 ]; then
			echo "${MAP_SERVICE_URL}/tiles/getmvt/0/0/0"
		elif [ $z -lt 9 ]; then
			echo "${MAP_SERVICE_URL}/tiles/getmvt/$z/[0-$limit]/[0-$limit]"
		else
			echo "--parallel-max 4 ${MAP_SERVICE_URL}/tiles/getmvt/$z/[0-$limit]/[0-$limit]"
		fi
	done
}

mkdir -p "${IMPORT_DIR}"

set -ex

case $1 in
	env)
		set +x
		echo -n "checking openmaptiles ... "
		if [ -d "${OPENMAPTILES_SRC}" ]; then
			echo "found"
			echo 'updating ...'
			git -C "${OPENMAPTILES_SRC}" reset --hard
			git -C "${OPENMAPTILES_SRC}" checkout master
			git -C "${OPENMAPTILES_SRC}" pull --all --force
		else
			echo "not exist, create"
			git clone "${OPENMAPTILES_GIT}" "${OPENMAPTILES_SRC}"
		fi
		echo -n "checking openmaptiles-tools ... "
		if [ -d "${OPENMAPTILES_TOOLS_SRC}" ]; then
			echo "found"
			echo 'updating ...'
			git -C "${OPENMAPTILES_TOOLS_SRC}" reset --hard
			git -C "${OPENMAPTILES_TOOLS_SRC}" checkout master
			git -C "${OPENMAPTILES_TOOLS_SRC}" pull --all --force
		else
			echo "not exist, create"
			git clone "${OPENMAPTILES_TOOLS_GIT}" "${OPENMAPTILES_TOOLS_SRC}"
		fi
		git -C "${OPENMAPTILES_TOOLS_SRC}" checkout "${OPENMAPTILES_TOOLS_VERSION}"
		pip install -r "${OPENMAPTILES_TOOLS_SRC}/requirements.txt"
		echo -n "checking spritezero_python ... "
		if [ -d "${SPRITEZERO_PYTHON_SRC}" ]; then
			echo "found"
			echo 'updating ...'
			git -C "${SPRITEZERO_PYTHON_SRC}" reset --hard
			git -C "${SPRITEZERO_PYTHON_SRC}" checkout master
			git -C "${SPRITEZERO_PYTHON_SRC}" pull --all --force
		else
			echo "not exist, create"
			git clone "${SPRITEZERO_PYTHON_GIT}" "${SPRITEZERO_PYTHON_SRC}"
		fi
		git -C "${SPRITEZERO_PYTHON_SRC}" checkout main
		pip install -r "${SPRITEZERO_PYTHON_SRC}/requirements.txt"
		gen_imposm_conf
		set -x
		;;
	build)
		POSTGIS_VERSION=$(find /usr -name postgis.sql -print0 2>/dev/null | xargs -0 grep 'INSTALL VERSION' | awk '{print $4}' | sed "s/'//g")
		git -C "${OPENMAPTILES_SRC}" checkout "${OPENMAPTILES_VERSION}"
		git -C "${OPENMAPTILES_TOOLS_SRC}" checkout "${OPENMAPTILES_TOOLS_VERSION}"
		#mkdir -p "${IMPORT_DIR}/openmaptiles.tm2source"
		#python "${OPENMAPTILES_TOOLS_SRC}/bin/generate-tm2source" "${OPENMAPTILES_SRC}/openmaptiles.yaml" > "${IMPORT_DIR}/openmaptiles.tm2source/data.yml"
		python "${OPENMAPTILES_TOOLS_SRC}/bin/generate-imposm3" "${OPENMAPTILES_SRC}/openmaptiles.yaml" > "${IMPORT_DIR}/openmaptiles-mapping.yaml"
		mkdir -p "${IMPORT_DIR}/sql"
		python "${OPENMAPTILES_TOOLS_SRC}/bin/generate-sql" "${OPENMAPTILES_SRC}/openmaptiles.yaml" --dir "${IMPORT_DIR}/sql"
		# Remove usage of LEAKPROOF
		#grep -r security_barrier "${IMPORT_DIR}/sql" >/dev/null || find "${IMPORT_DIR}/sql" -type f -name "*.sql" -exec sed 's/LEAKPROOF//' -i {} \;
		python "${OPENMAPTILES_TOOLS_SRC}/bin/generate-sqltomvt" "${OPENMAPTILES_SRC}/openmaptiles.yaml" --key --postgis-ver $POSTGIS_VERSION --function --fname=getmvt >> "${IMPORT_DIR}/sql/run_last.sql"
		mkdir -p "${IMPORT_DIR}/style"
		python "${OPENMAPTILES_TOOLS_SRC}/bin/style-tools" recompose "${OPENMAPTILES_SRC}/openmaptiles.yaml" "${IMPORT_DIR}/style/style.json" "${OPENMAPTILES_SRC}/style/style-header.json"
		mkdir -p "${IMPORT_DIR}/osm"
		echo '<?php header('Content-Type: application/json'); ?>' > "${IMPORT_DIR}/osm/style.php"
		cat "${IMPORT_DIR}/style/style.json" >> "${IMPORT_DIR}/osm/style.php"
		sed 's|"url": ".*"|"url": "<?php echo $_SERVER["SERVER_URI"] ?>/maps/tiles/getmvt"|; s|"glyphs": "[^{]*{|"glyphs": "<?php echo $_SERVER["SERVER_URI"] ?>/maps/fonts/{|; s|"sprite": ".*sprite|"sprite": "<?php echo $_SERVER["SERVER_URI"] ?>/maps/style/sprite|' -i "${IMPORT_DIR}/osm/style.php"
		python ${SRC_DIR}/spritezero_python/spritezero.py "${IMPORT_DIR}/style/sprite" "${OPENMAPTILES_SRC}/style/icons"
		python ${SRC_DIR}/spritezero_python/spritezero.py --retina "${IMPORT_DIR}/style/sprite@2x" "${OPENMAPTILES_SRC}/style/icons"
		;;
	import)
		echo "Importing Natural Earth ..."
		if [ ! -e "${IMPORT_DIR}/natural_earth/natural_earth_vector.sqlite" ]; then
			mkdir -p "${IMPORT_DIR}/natural_earth"
			# Prepare Natural Earth data from http://www.naturalearthdata.com/
			ne_sqlite_zip="natural_earth_vector.sqlite_$NATURAL_EARTH_VECTOR_VERSION.zip"
			if [ ! -e "${MAPS_DIR}/naturalearthdata/${ne_sqlite_zip}" ]; then
				wget -P "${MAPS_DIR}/naturalearthdata" "https://dev.maptiler.download/geodata/omt/${ne_sqlite_zip}" -O "${ne_sqlite_zip}"
			fi
			unzip -ojd "${IMPORT_DIR}/natural_earth" "${MAPS_DIR}/naturalearthdata/${ne_sqlite_zip}"
			clean_natural_earth "${IMPORT_DIR}/natural_earth/natural_earth_vector.sqlite"
		fi
		ogr2ogr -progress -f Postgresql -s_srs EPSG:4326 -t_srs EPSG:3857 -clipsrc -180.1 -85.0511 180.1 85.0511 -lco GEOMETRY_NAME=geometry -lco OVERWRITE=YES -lco DIM=2 -nlt GEOMETRY -overwrite "PG:${PGCONN}" "${IMPORT_DIR}/natural_earth/natural_earth_vector.sqlite"
		echo "Importing water polygons ..."
		if [ ! -e "${IMPORT_DIR}/water_polygons/water_polygons.shp" ]; then
			mkdir -p "${IMPORT_DIR}/water_polygons"
			# Download water polygons data from http://osmdata.openstreetmap.de
			if [ ! -e "${MAPS_DIR}/mercator/water-polygons-split-3857.zip" ]; then
				wget -P "${MAPS_DIR}/mercator" "http://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip"
			fi
			unzip -ojd "${IMPORT_DIR}/water_polygons" "${MAPS_DIR}/mercator/water-polygons-split-3857.zip"
		fi
		ogr2ogr -progress -f Postgresql -s_srs EPSG:3857 -t_srs EPSG:3857 -lco OVERWRITE=YES -lco GEOMETRY_NAME=geometry -overwrite -nln "${WATER_TABLE_NAME}" -nlt geometry --config PG_USE_COPY YES "PG:${PGCONN}" "${IMPORT_DIR}/water_polygons/water_polygons.shp"
		echo "Importing lake lines ..."
		if [ ! -e "${IMPORT_DIR}/lake_centerline/lake_centerline.geojson" ]; then
			mkdir -p "${IMPORT_DIR}/lake_centerline"
			# Download lake centerlines from https://dev.maptiler.download/geodata/omt/lake_centerline.geojson
			if [ ! -e "${MAPS_DIR}/lake_centerline/lake_centerline.geojson.lz" ]; then
				wget -P "${MAPS_DIR}/lake_centerline" "https://dev.maptiler.download/geodata/omt/lake_centerline.geojson"
				lzip "${MAPS_DIR}/lake_centerline/lake_centerline.geojson"
			fi
			lzip -d -c "${MAPS_DIR}/lake_centerline/lake_centerline.geojson.lz" > "${IMPORT_DIR}/lake_centerline/lake_centerline.geojson"
		fi
		ogr2ogr -progress -f Postgresql -s_srs EPSG:3857 -t_srs EPSG:3857 -lco OVERWRITE=YES -overwrite -nln "${LAKE_CENTERLINE_TABLE}" "PG:${PGCONN}" "${IMPORT_DIR}/lake_centerline/lake_centerline.geojson"
		;;
	read)
		mkdir -p "${IMPORT_DIR}/cache" "${IMPORT_DIR}/diff"
		pbf="$2"
		shift 2
		imposm import -config "${IMPOSM_CONFIG}" -read "$pbf" -diff "$@"
		;;
	read2)
		pbf="$2"
		shift 2
		imposm import -config "${IMPOSM_CONFIG}" -read "$pbf" -diff -appendcache "$@"
		;;
	write)
		imposm import -config "${IMPOSM_CONFIG}" -write -generate -optimize -deployproduction
		;;
	autodiff)
		imposm run -config "${IMPOSM_CONFIG}"
		;;
	diff)
		shift 1
		imposm diff -config "${IMPOSM_CONFIG}" "$@"
		;;
	tables)
		import_tables "${OPENMAPTILES_TOOLS_SRC}/sql"
		bulk_import_tables "${IMPORT_DIR}/sql"
		;;
	cache_tiles)
		if [ -z "${MAP_SERVICE_URL}" ]; then
			echo 'Please set MAP_SERVICE_URL'
			exit 1
		fi
		minz=${2:-0}
		maxz=${3:-$minz}
		for z in $(seq $minz $maxz); do
			echo "zoom $z tiles ..."
			if [ $z -lt 7 ]; then
				gen_tiles_url $z $z | xargs curl -kSZ#o /dev/null --parallel-max 2 --tcp-fastopen
			else
				gen_tiles_url $z $z | xargs curl -kSZ#o /dev/null --parallel-max 4 --tcp-fastopen
			fi
		done
		;;
	cache_tiles_verbose)
		if [ -z "${MAP_SERVICE_URL}" ]; then
			echo 'Please set MAP_SERVICE_URL'
			exit 1
		fi
		set +x
		minz=${2:-0}
		maxz=${3:-$minz}
		if [ $minz -eq 0 ]; then
			t1=$(date '+%s')
			echo -n 'Tile: 0/0/0 ...'
			curl -ksSo /dev/null --tcp-fastopen "${MAP_SERVICE_URL}/tiles/getmvt/0/0/0"
			minz=$((minz+1))
			t2=$(date '+%s')
			echo " elapse $((t2-t1)) seconds"
		else
			t2=$(date '+%s')
		fi
		offz2=${4:-0}
		for z in $(seq $minz $maxz); do
			limit=$(echo "2^$z-1" | bc)
			for x in $(seq $offz2 $limit); do
				for y in $(seq 0 $limit); do
					t1=$t2
					echo -n "Tile: $z/$x/$y ..."
					curl -ksSo /dev/null --tcp-fastopen "${MAP_SERVICE_URL}/tiles/getmvt/$z/$x/$y"
					t2=$(date '+%s')
					echo " elapse $((t2-t1)) seconds"
				done
			done
			offz2=0
		done
		;;
	*)
		usage;;
esac

