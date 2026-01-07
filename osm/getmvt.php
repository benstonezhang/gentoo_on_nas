<?php
$db_host = 'localhost';
$db_port = 5432;
$db_name = 'osm';
$db_user = 'osm_viewer';
$db_password = 'MY_OSM_VIEWER_PASSWORD';

/*
 * add below to nginx:
 *   fastcgi_param REQUEST_URI https://$host:$server_port/maps/tiles/getmvt;
 */

if ($_SERVER['QUERY_STRING']) {
	$db = pg_connect("host='$db_host' port='$db_port' dbname='$db_name' user='$db_user' password='$db_password'");
	$result = pg_query_params($db, 'SELECT mvt, key from getmvt($1, $2, $3)', array(intval($_GET['zoom']), intval($_GET['x']), $y = intval($_GET['y'])));
	$row = pg_fetch_row($result);
	if ($row) {
		$mvt = $row[0];
		$key = $row[1];
		header('Content-Type: application/x-protobuf');
		header("ETag: $key");
		$mvt = pg_unescape_bytea($mvt);
		if (strlen($mvt) > 500) {
			ob_start("ob_gzhandler");
		}
		echo $mvt;
	} else {
		http_response_code(404);
	}
} else {
	echo '{"tilejson":"3.0.0","tiles":["'.$_SERVER['REQUEST_URI'].'/{z}/{x}/{y}"],"description":"public.getmvt","name":"getmvt"}';
}
?>
