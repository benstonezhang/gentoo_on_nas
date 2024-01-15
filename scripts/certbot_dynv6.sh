#!/bin/bash

set -e

# default remain time is 10 days
CERT_REMAIN_TIME=${CERT_REMAIN_TIME:-1296000}
NS_SERVER=ns1.dynv6.com

DYNV6_TOKEN_FILE=dynv6.token
if [ ! -e $DYNV6_TOKEN_FILE ]; then
	echo "Please save Dynv6 HTTP token to file $DYNV6_TOKEN_FILE"
	exit 1
fi
DYNV6_AUTH="Authorization: Bearer $(cat $DYNV6_TOKEN_FILE)"

NEW_ACCOUNT_ID=create
ACCOUNT_ID="$(ls -1 | sed '/^[0-9]\+\.key$/{s/\.key//; p}; d')"
if [ -z "$ACCOUNT_ID" ]; then
	ACCOUNT_ID=$NEW_ACCOUNT_ID
fi

DOMAIN="$(ls -1 | sed '/.*\..*\.key/{s/\.key//; p}; d')"
if [ -z "$DOMAIN" ]; then
	DOMAIN="$1"
	if [ -z "$DOMAIN" ]; then
		echo "Usage: $0 domain [alt_domain ...]"
		echo "Environments: CERT_RENEW"
		exit 1
	fi
fi

if [ -e "${DOMAIN}.crt" ]; then
	crt_time=$(date -d "$(openssl x509 -in ${DOMAIN}.crt -noout -text | grep 'Not After *:' | sed 's/^.*: //')" '+%s')
	today_time=$(date '+%s')
	if [ $((crt_time-today_time)) -gt $CERT_REMAIN_TIME ]; then
		echo "Certificate still valid, skip"
		exit 2
	fi
fi

DOMAINS=("$@")
if [ ${#DOMAINS[@]} -lt 2 ]; then
	DOMAINS=("$DOMAIN" "*.$DOMAIN")
fi
SUBJALTNAME="DNS:${DOMAINS[0]}"
for (( i=1; i < ${#DOMAINS[@]}; i++ )); do
	SUBJALTNAME="${SUBJALTNAME},DNS:${DOMAINS[$i]}"
done

echo "Primary domain: ${DOMAIN}"
echo "Subject Alternative Names: ${SUBJALTNAME}"

ZONE_ID_LIST=${ZONE_ID_LIST:-zone_id.lst}

# ACME API to use
API='https://acme-v02.api.letsencrypt.org'

# Staging API for test
#API='https://acme-staging-v02.api.letsencrypt.org'

HEADER_CONTENT_TYPE_ACME='Content-Type: application/jose+json'
HEADER_CONTENT_TYPE_JSON='Content-Type: application/json'
DNS_ACME_CHALLENGE='_acme-challenge'

dynv6_records=''


# base64url encoding
# https://tools.ietf.org/html/rfc4648#section-5
function base64url() {
	base64 -w 0 | sed 's|+|-|g; s|/|_|g; s|=*$||g'
}

# hex to binary
function hexbin() {
	xxd -p -r
}

# remove newlines and duplicate whitespace
function flatstring() {
	tr -d '\n\r' | sed 's/[[:space:]]\+/ /g'
}

# make and ACME API request
# $1 = URL
# $2 = body
function api_request() {
	local URL="$1"
	local BODY="$2"

	# get new nonce by HEAD to newNonce API
	#echo "Getting nonce ..." >&2
	local NONCE="$(curl -sS -I "${API}/acme/new-nonce" | sed '/^replay-nonce: /{s/^replay-nonce: //i; q}; d' | flatstring)"

	# JSON Web Signature
	local HEADER="{ \"alg\": \"RS256\", ${JWS_AUTH}, \"nonce\": \"${NONCE}\", \"url\": \"${URL}\" }"
	local JWS_PROTECTED="$(echo -n "${HEADER}" | base64url)"
	local JWS_PAYLOAD="$(echo -n "${BODY}" | base64url)"
	local JWS_SIGNATURE="$(echo -n "${JWS_PROTECTED}.${JWS_PAYLOAD}" | openssl dgst -sha256 -sign "${ACCOUNT_ID}.key" -passin "file:${ACCOUNT_ID}.pass" | base64url)"
	local JWS="{ \"protected\": \"${JWS_PROTECTED}\", \"payload\": \"${JWS_PAYLOAD}\", \"signature\": \"${JWS_SIGNATURE}\" }"

	#echo "Request URL: ${URL}" >&2
	#echo "JWS Header: ${HEADER}" >&2
	#echo "JWS Body: ${BODY}" >&2
	# base64 encoding/decoding necessary to stay binary safe.
	# e.g. the new-cert operation responds with a der encoded certificate.
	local RESPONSE="$(echo -n "data-raw = \"$(echo ${JWS} | sed 's|"|\\"|g')\"" | \
			curl -sSi -X POST -H "$HEADER_CONTENT_TYPE_ACME" -K - "${URL}" | base64 -w 0 | base64 -d)"
	#echo "${RESPONSE}" >&2
	# just in case we get a 2xx status code but an echo in response body (spec is not clear on that)
	local ACME_ERROR_CHECK="$(echo -n "${RESPONSE}" | flatstring | sed 's/^.*"type": "urn:acme:error.*$/ERROR/')"
	if [ "${ACME_ERROR_CHECK}" != "ERROR" ]; then
		#echo "API request successful" >&2
		echo "${RESPONSE}"
	else
		echo "API request error" >&2
		echo "Request URL: ${URL}" >&2
		echo "HTTP status: ${HTTP_CODE}" >&2
		echo "${RESPONSE}" >&2
		exit 1
	fi

	return 0
}

function dynv6_get_zoneid() {
	if [ -e "${ZONE_ID_LIST}" ]; then
		zone_id="$(sed "/^$1 /{s/^.* //; p}; d" "${ZONE_ID_LIST}")"
		if [ -n "$zone_id" ]; then
			echo -n "$zone_id"
			return
		fi
	fi
	local zone_id="$(echo -n "-H \"${DYNV6_AUTH}\"" | \
			curl -sS -X GET -H "$HEADER_CONTENT_TYPE_JSON" -K - "https://dynv6.com/api/v2/zones" | \
			sed -E '/"name":"'"${1}"'"/{s/^.*"name":"'"${1}"'"[^}]*,"id":([0-9]+)[^0-9].*$/\1/; q}; d')"
	echo -n "$1 ${zone_id}" >> "${ZONE_ID_LIST}"
	echo -n "${zone_id}"
}

function dynv6_update() {
	local zone_id="$(dynv6_get_zoneid "$1")"
	local RESPONSE="$(echo -en "-H \"${DYNV6_AUTH}\"\ndata-raw = \"{\\\"name\\\":\\\"${DNS_ACME_CHALLENGE}\\\",\\\"data\\\":\\\"${2}\\\",\\\"type\\\":\\\"TXT\\\"}\"" | \
			curl -sS -X POST -H "$HEADER_CONTENT_TYPE_JSON" -K - "https://dynv6.com/api/v2/zones/${zone_id}/records")"
	local record_id="$(echo -n ${RESPONSE} | sed 's/^.*"id"://; s/,.*$//')"
	dynv6_records="${dynv6_records} $zone_id $record_id"
}

function dynv6_delete() {
	echo -n "-H \"${DYNV6_AUTH}\"" | curl -sS -X DELETE -H "$HEADER_CONTENT_TYPE_JSON" -K - "https://dynv6.com/api/v2/zones/${1}/records/${2}"
}

function check_dns_txt() {
	local count=0
	while [ $count -lt 20 ]; do
		dig "@${NS_SERVER}" "${DNS_ACME_CHALLENGE}.${1}" TXT | grep -E "^${DNS_ACME_CHALLENGE}.${1}.\s+[0-9]+\s+IN\s+TXT" && return
		sleep 3
		count=$((count+1))
	done
	echo "DNS TXT record query timeout"
	exit 1
}

function on_exit() {
	if [ -n "$dynv6_records" ]; then
		echo "Delete validation TXT record"
		echo $dynv6_records | while read -r zone_id record_id; do
			dynv6_delete "$zone_id" "$record_id"
		done
		dynv6_records=''
	fi
}


# create a new account key for certificate request
if [ ! -e "${ACCOUNT_ID}.key" ]; then
	if [ ! -e "${ACCOUNT_ID}.pass" ]; then
		dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p -c0 > "${ACCOUNT_ID}.pass"
		chmod 400 "${ACCOUNT_ID}.pass"
	fi
	openssl genrsa -out "${ACCOUNT_ID}.key" -passout "file:${ACCOUNT_ID}.pass" 4096
	chmod 400 "${ACCOUNT_ID}.key"
fi
if [ ! -e "${ACCOUNT_ID}.pub" ]; then
	openssl rsa -in "${ACCOUNT_ID}.key" -passin "file:${ACCOUNT_ID}.pass" -out "${ACCOUNT_ID}.pub" -pubout
	chmod 444 "${ACCOUNT_ID}.pub"
fi

# account public key exponent
# formatting: Exponent dec => hex => binary => base64url
# e.g. 65537 => 0x010001 => ... => AQAB
# printf 0.32 and cutting 00 in pairs makes sure we have even number of digits for hexbin
JWK_E="$(openssl rsa -pubin -in "${ACCOUNT_ID}.pub" -text -noout | grep ^Exponent | awk '{ printf "%0.32x",$2; }' | sed 's/^\(00\)*//g' | hexbin | base64url)"

# account public key modulus
JWK_N="$(openssl rsa -pubin -in "${ACCOUNT_ID}.pub" -modulus -noout | sed 's/^Modulus=//' | hexbin | base64url)"

# Important: no whitespaces at all. The server computes the thumbprint from our
# E and N values in JWK and does so with this exact JSON. The sha256 from us
# will not match theirs if we use a different JSON formatting.
# see example in https://tools.ietf.org/html/rfc7638
JWK_THUMBPRINT="$(echo -n "{\"e\":\"${JWK_E}\",\"kty\":\"RSA\",\"n\":\"${JWK_N}\"}" | openssl dgst -sha256 -binary | base64url)"
#echo "jwk_thumbprint = ${JWK_THUMBPRINT}"


# create new account if account id not found
if [ "${ACCOUNT_ID}" != "$NEW_ACCOUNT_ID" ]; then
	ACCOUNT_URL="${API}/acme/acct/${ACCOUNT_ID}"
else
	# API authentication by JWK until we have an account
	JWS_AUTH="\"jwk\": { \"e\": \"${JWK_E}\", \"kty\": \"RSA\", \"n\": \"${JWK_N}\" }"

	echo "Registering account ..."
	RESPONSE="$(api_request "${API}/acme/new-acct" "{ \"termsOfServiceAgreed\": true }")"
	ACCOUNT_URL="$(echo -n "${RESPONSE}" | grep -i '^location: ' | sed 's/^location: //i' | flatstring)"
	ACCOUNT_ID="$(echo "$ACCOUNT_URL" | sed 's|^.*/||')"
	mv "${NEW_ACCOUNT_ID}.key" "${ACCOUNT_ID}.key"
	mv "${NEW_ACCOUNT_ID}.pub" "${ACCOUNT_ID}.pub"
	if [ -z "${NO_KEY_PASS}" ]; then
		mv "${NEW_ACCOUNT_ID}.pass" "${ACCOUNT_ID}.pass"
	fi
fi
echo "Account URL: ${ACCOUNT_URL}"


# generate domain private key if absent
if [ ! -e "${DOMAIN}.key" ]; then
	echo "Generating domain private key: ${DOMAIN}.key"
	openssl genrsa -out "${DOMAIN}.key" 4096
	chmod 400 "${DOMAIN}.key"
fi

# API authentication by account URL from now on
JWS_AUTH="\"kid\": \"${ACCOUNT_URL}\""
#echo "jws_kid_auth=${JWS_AUTH}"


echo "Creating order ..."
REQUEST="{ \"identifiers\": ["
for (( i=0; i < ${#DOMAINS[@]}; i++ )); do
	REQUEST="${REQUEST} { \"type\": \"dns\", \"value\": \"${DOMAINS[$i]}\" }"
	if [ $i -lt $((${#DOMAINS[@]}-1)) ]; then REQUEST="${REQUEST},"; fi
done
REQUEST="${REQUEST} ] }"
RESPONSE="$(api_request "${API}/acme/new-order" "${REQUEST}")"
ORDER_URL=$(echo -n "${RESPONSE}" | grep -i '^location: ' | sed 's/^location: //i' | flatstring)
FLAT_RESP="$(echo -n "${RESPONSE}" | flatstring)"
IFS=" " read -r -a AUTHORIZATION_URLS <<<$(echo -n "${FLAT_RESP}" | sed 's/^.*"authorizations"\:\ \[\ \(.*\)\ \].*$/\1/' | tr -d ',"')
#echo "authorization_urls=${AUTHORIZATION_URLS[*]}"
if [ ${#DOMAINS[@]} -ne ${#AUTHORIZATION_URLS[@]} ]; then
	echo "${RESPONSE}"
	echo "Number of returned authorization URLs (${#AUTHORIZATION_URLS[@]}) does not match the number your requested domains (${#DOMAINS[@]}). Cannot continue."
	exit 1
fi
FINALIZE_URL="$(echo -n "${FLAT_RESP}" | sed 's/^.*"finalize"\:\ "\([^"]*\)".*$/\1/')"
#echo "finalize_url=${FINALIZE_URL}"


echo "Getting authorization tokens ..."
CHALLENGE_URLS=()
CHALLENGE_TOKENS=()
KEYAUTHS=()
for (( i=0; i < ${#DOMAINS[@]}; i++ )); do
	echo "  $i: ${DOMAINS[$i]}"
	RESPONSE="$(api_request "${AUTHORIZATION_URLS[$i]}" "")"
	FLAT_RESP=$(echo -n "${RESPONSE}" | flatstring)
	read -r URL TOKEN <<<$(echo -n "${FLAT_RESP}" | sed 's/^.*"type": "dns-01", "status": "[^"]*", "url": "\([^"]*\)", "token": "\([^"]*\)".*$/\1 \2/')
	CHALLENGE_URLS[$i]="$URL"
	CHALLENGE_TOKENS[$i]="$TOKEN"
	KEYAUTHS[$i]="$(echo -n ${TOKEN}.${JWK_THUMBPRINT} | openssl dgst -sha256 -binary | base64url)"
done


trap on_exit EXIT

echo "Doing DNS validation"
for (( i=0; i < ${#DOMAINS[@]}; i++ )); do
	domain="$(echo "${DOMAINS[$i]}" | sed 's/^*\.//')"
	dynv6_update "${domain}" "${KEYAUTHS[$i]}"
done
sleep 15
for (( i=0; i < ${#DOMAINS[@]}; i++ )); do
	domain="${DOMAINS[$i]}"
	echo "${domain}" | grep '^*\.' > /dev/null && continue
	check_dns_txt "${domain}"
done


echo "Responding to challenges ..."
for (( i=0; i < ${#CHALLENGE_URLS[@]}; i++ )); do
	echo "  ${CHALLENGE_URLS[$i]}"
	RESPONSE="$(api_request "${CHALLENGE_URLS[$i]}" "{}")"
	STATUS="$(echo -n "$RESPONSE" | flatstring | sed 's/^.*"status"\:\ "\([^"]*\)".*$/\1/')"
	if [ "${STATUS}" != "valid" ]; then
		echo "Failed to responding to challenge"
		echo "$RESPONSE"
		exit 1
	fi
done
sleep 10


echo "Waiting for validation ..."
for attempt in $(seq 1 10); do
	RESPONSE="$(api_request "${ORDER_URL}" "")"
	STATUS="$(echo -n "$RESPONSE" | flatstring | sed 's/^.*"status"\:\ "\([^"]*\)".*$/\1/')"
	[ "${STATUS}" != "pending" ] && break
	sleep 3
done
if [ "${STATUS}" = ready ]; then
	echo "Validation successful."
else
	echo "${RESPONSE}"
	echo "The server unsuccessfully validated your authorization challenge(s). Certificate order status is \"${STATUS}\" instead of \"ready\". Something went wrong validating the authorization challenge(s). Cannot continue."
	exit 1
fi
sleep 10


echo "Creating CSR ..."
openssl req -new -sha256 -key "${DOMAIN}.key" -subj "/CN=${DOMAIN}" -addext "subjectAltName=${SUBJALTNAME}" -out "${DOMAIN}.csr"
echo "Done ${DOMAIN}.csr"


echo "Finalizing order ..."
CSR="$(openssl req -in "${DOMAIN}.csr" -inform PEM -outform DER | base64url)"
REQUEST="{ \"csr\": \"${CSR}\" }"
for attempt in $(seq 1 10); do
	RESPONSE="$(api_request "${FINALIZE_URL}" "${REQUEST}")"
	FLAT_RESP="$(echo -n "$RESPONSE" | flatstring)"
	STATUS="$(echo -n "$FLAT_RESP" | sed 's/^.*"status"\:\ "*//; s/[", }].*$//')"
	[ "${STATUS}" != "processing" ] && break
	sleep 3
done
case "${STATUS}" in
	valid)
		CERTIFICATE_URL="$(echo -n "${FLAT_RESP}" | sed 's/^.*"certificate"\:\ "\([^"]*\)".*$/\1/')"
		echo "OK"
		;;
	403)
		RESPONSE="$(api_request "${ORDER_URL}" "")"
		CERTIFICATE_URL="$(echo -n "$RESPONSE" | flatstring | grep certificate | sed 's/^.*"certificate"\:\ "\([^"]*\)".*$/\1/')"
		if [ -z "$CERTIFICATE_URL" ]; then
			echo "Certificate order status wrong ($STATUS). Cannot continue."
			exit 1
		fi
		;;
	*)
		echo "${RESPONSE}"
		echo "Certificate order status wrong ($STATUS). Cannot continue."
		exit 1
esac


echo "Downloading certificate ..."
echo "${CERTIFICATE_URL}"
RESPONSE="$(api_request "${CERTIFICATE_URL}" "")"
# Response contains the server and intermediate certificate(s). Store all in one chained file. They are in the right order already.
rm -f "${DOMAIN}.crt"
echo "${RESPONSE}" | awk '/-----BEGIN CERTIFICATE-----/,0' > "${DOMAIN}.crt"
chmod 444 "${DOMAIN}.crt"
echo "Success! Certificate with intermediates saved to: ${DOMAIN}.crt"


echo "Finished."
exit 0
