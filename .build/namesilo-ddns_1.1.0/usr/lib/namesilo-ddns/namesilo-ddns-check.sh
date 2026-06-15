#!/usr/bin/env bash
#
# NameSilo DDNS one-shot updater.
#
# This script is designed to be executed by a systemd oneshot service.
# It reads configuration from /etc/default/namesilo-ddns, discovers the
# current public IP address, compares it with the last known address,
# and updates the configured NameSilo DNS record only when necessary.
#
# Key behaviors:
#   1. Detect public IP using DNS-based methods first
#   2. Fall back to HTTPS-based IP echo services if DNS-based detection fails
#   3. Skip all NameSilo update API calls when the IP has not changed
#   4. Log detailed lookup failure information for troubleshooting
#
# Supported IP family modes:
#   - IP_FAMILY=4     : force IPv4 lookups only
#   - IP_FAMILY=6     : force IPv6 lookups only
#   - IP_FAMILY=auto  : do not force address family
#
set -Eeuo pipefail

PROGRAM_NAME="namesilo-ddns-check"
CONFIG_FILE="/etc/default/namesilo-ddns"

log() {
    logger -t "$PROGRAM_NAME" -- "$*"
}

fail() {
    log "ERROR: $*"
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

# Load configuration from the packaged config file.
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1091
    source "$CONFIG_FILE"
else
    fail "Configuration file not found or unreadable: $CONFIG_FILE"
fi

# Validate mandatory settings early so failures are explicit.
: "${API_KEY:?API_KEY must be set in $CONFIG_FILE}"
: "${DOMAIN:?DOMAIN must be set in $CONFIG_FILE}"
: "${HOST:?HOST must be set in $CONFIG_FILE}"

# Optional settings and defaults.
STATE_DIR="${STATE_DIR:-/var/lib/namesilo-ddns}"
TTL="${TTL:-3600}"
NO_CHANGE_LOG_INTERVAL_SEC="${NO_CHANGE_LOG_INTERVAL_SEC:-86400}"
CURL_CONNECT_TIMEOUT_SEC="${CURL_CONNECT_TIMEOUT_SEC:-10}"
CURL_MAX_TIME_SEC="${CURL_MAX_TIME_SEC:-30}"
DNS_LOOKUP_RETRY_DELAY_SEC="${DNS_LOOKUP_RETRY_DELAY_SEC:-5}"
ENABLE_STARTUP_RANDOM_DELAY="${ENABLE_STARTUP_RANDOM_DELAY:-yes}"
STARTUP_RANDOM_DELAY_MAX_SEC="${STARTUP_RANDOM_DELAY_MAX_SEC:-5}"

# DNS lookup behavior.
DIG_TIMEOUT_SEC="${DIG_TIMEOUT_SEC:-3}"
DIG_TRIES="${DIG_TRIES:-1}"

# IP family control:
#   4    -> force IPv4
#   6    -> force IPv6
#   auto -> do not force family
IP_FAMILY="${IP_FAMILY:-4}"

# HTTPS fallback behavior.
ENABLE_HTTP_FALLBACK="${ENABLE_HTTP_FALLBACK:-yes}"
HTTP_IP_ECHO_PRIMARY="${HTTP_IP_ECHO_PRIMARY:-https://api.ipify.org}"
HTTP_IP_ECHO_SECONDARY="${HTTP_IP_ECHO_SECONDARY:-https://ifconfig.co}"

require_command curl
require_command dig
require_command xmllint
require_command flock
require_command awk
require_command grep
require_command sed
require_command tr
require_command mktemp
require_command date
require_command chmod
require_command mkdir
require_command cat

mkdir -p "$STATE_DIR"
chmod 0750 "$STATE_DIR"

# Use host-specific state file names so multiple instances can be supported later.
STATE_BASENAME="$(printf '%s_%s' "$HOST" "$DOMAIN" | tr '/ ' '__')"
IP_FILE="$STATE_DIR/${STATE_BASENAME}.last_ip"
TIME_FILE="$STATE_DIR/${STATE_BASENAME}.last_log_time"
LOCK_FILE="$STATE_DIR/${STATE_BASENAME}.lock"

TMPDIR="$(mktemp -d /tmp/namesilo-ddns.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
LIST_XML="$TMPDIR/dns_list_records.xml"
UPDATE_XML="$TMPDIR/dns_update_record.xml"

# Prevent overlapping executions.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another updater instance is already running; exiting."
    exit 0
fi

# Optional small random delay to reduce synchronized API bursts.
if [[ "$ENABLE_STARTUP_RANDOM_DELAY" == "yes" && "$STARTUP_RANDOM_DELAY_MAX_SEC" =~ ^[0-9]+$ && "$STARTUP_RANDOM_DELAY_MAX_SEC" -gt 0 ]]; then
    sleep "$(( RANDOM % (STARTUP_RANDOM_DELAY_MAX_SEC + 1) ))"
fi

read_file_or_empty() {
    local path="$1"
    [[ -f "$path" ]] && cat "$path" || true
}

write_timestamp() {
    date +%s > "$TIME_FILE"
}

run_capture() {
    local output rc
    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    printf '%s' "$output"
    return "$rc"
}

get_dig_family_args() {
    case "$IP_FAMILY" in
        4) printf '%s\n' "-4" ;;
        6) printf '%s\n' "-6" ;;
        auto) printf '%s\n' "" ;;
        *) fail "Invalid IP_FAMILY value '$IP_FAMILY'. Expected: 4, 6, or auto" ;;
    esac
}

get_curl_family_args() {
    case "$IP_FAMILY" in
        4) printf '%s\n' "-4" ;;
        6) printf '%s\n' "-6" ;;
        auto) printf '%s\n' "" ;;
        *) fail "Invalid IP_FAMILY value '$IP_FAMILY'. Expected: 4, 6, or auto" ;;
    esac
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* ]]
}

is_valid_ip_for_family() {
    local ip="$1"
    case "$IP_FAMILY" in
        4) is_ipv4 "$ip" ;;
        6) is_ipv6 "$ip" ;;
        auto) is_ipv4 "$ip" || is_ipv6 "$ip" ;;
        *) return 1 ;;
    esac
}

public_ip_from_opendns() {
    local resolver output rc ip dig_family_arg

    resolver="resolver$(( (RANDOM % 3) + 1 )).opendns.com"
    dig_family_arg="$(get_dig_family_args)"

    if [[ -n "$dig_family_arg" ]]; then
        output="$(run_capture dig "$dig_family_arg" +time="$DIG_TIMEOUT_SEC" +tries="$DIG_TRIES" +short myip.opendns.com @"$resolver")"
    else
        output="$(run_capture dig +time="$DIG_TIMEOUT_SEC" +tries="$DIG_TRIES" +short myip.opendns.com @"$resolver")"
    fi
    rc=$?

    if [[ $rc -ne 0 ]]; then
        log "OpenDNS lookup failed via ${resolver}; rc=${rc}; output=${output}"
        return 1
    fi

    ip="$(printf '%s' "$output" | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        log "OpenDNS lookup returned empty result via ${resolver}; raw_output=${output}"
        return 1
    fi

    if ! is_valid_ip_for_family "$ip"; then
        log "OpenDNS lookup returned unexpected content via ${resolver}; raw_output=${output}; parsed_ip=${ip}; ip_family=${IP_FAMILY}"
        return 1
    fi

    printf '%s %s\n' "$ip" "$resolver"
}

public_ip_from_google() {
    local resolver output rc ip dig_family_arg

    resolver="ns$(( (RANDOM % 3) + 1 )).google.com"
    dig_family_arg="$(get_dig_family_args)"

    if [[ -n "$dig_family_arg" ]]; then
        output="$(run_capture dig "$dig_family_arg" +time="$DIG_TIMEOUT_SEC" +tries="$DIG_TRIES" TXT +short o-o.myaddr.l.google.com @"$resolver")"
    else
        output="$(run_capture dig +time="$DIG_TIMEOUT_SEC" +tries="$DIG_TRIES" TXT +short o-o.myaddr.l.google.com @"$resolver")"
    fi
    rc=$?

    if [[ $rc -ne 0 ]]; then
        log "Google DNS lookup failed via ${resolver}; rc=${rc}; output=${output}"
        return 1
    fi

    ip="$(printf '%s' "$output" | awk -F'"' '{print $2}' | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        log "Google DNS lookup returned empty/parse-failed result via ${resolver}; raw_output=${output}"
        return 1
    fi

    if ! is_valid_ip_for_family "$ip"; then
        log "Google DNS lookup returned unexpected content via ${resolver}; raw_output=${output}; parsed_ip=${ip}; ip_family=${IP_FAMILY}"
        return 1
    fi

    printf '%s %s\n' "$ip" "$resolver"
}

public_ip_from_http() {
    local url="$1"
    local output rc ip curl_family_arg

    curl_family_arg="$(get_curl_family_args)"

    if [[ -n "$curl_family_arg" ]]; then
        output="$(run_capture curl "$curl_family_arg" --silent --show-error --fail \
            --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
            --max-time "$CURL_MAX_TIME_SEC" \
            "$url")"
    else
        output="$(run_capture curl --silent --show-error --fail \
            --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
            --max-time "$CURL_MAX_TIME_SEC" \
            "$url")"
    fi
    rc=$?

    if [[ $rc -ne 0 ]]; then
        log "HTTP IP lookup failed via ${url}; rc=${rc}; output=${output}"
        return 1
    fi

    ip="$(printf '%s' "$output" | tr -d '[:space:]')"

    if [[ -z "$ip" ]]; then
        log "HTTP IP lookup returned empty result via ${url}; raw_output=${output}"
        return 1
    fi

    if ! is_valid_ip_for_family "$ip"; then
        log "HTTP IP lookup returned unexpected content via ${url}; raw_output=${output}; parsed_ip=${ip}; ip_family=${IP_FAMILY}"
        return 1
    fi

    printf '%s %s\n' "$ip" "$url"
}

get_public_ip() {
    local result

    if result="$(public_ip_from_opendns)"; then
        printf '%s\n' "$result"
        return 0
    fi

    log "OpenDNS lookup failed; retrying with Google resolver after ${DNS_LOOKUP_RETRY_DELAY_SEC}s."
    sleep "$DNS_LOOKUP_RETRY_DELAY_SEC"

    if result="$(public_ip_from_google)"; then
        printf '%s\n' "$result"
        return 0
    fi

    if [[ "$ENABLE_HTTP_FALLBACK" == "yes" ]]; then
        log "Google DNS lookup failed; retrying with HTTP IP echo service: ${HTTP_IP_ECHO_PRIMARY}"
        if result="$(public_ip_from_http "$HTTP_IP_ECHO_PRIMARY")"; then
            printf '%s\n' "$result"
            return 0
        fi

        log "Primary HTTP IP echo lookup failed; retrying with secondary service: ${HTTP_IP_ECHO_SECONDARY}"
        if result="$(public_ip_from_http "$HTTP_IP_ECHO_SECONDARY")"; then
            printf '%s\n' "$result"
            return 0
        fi
    fi

    return 1
}

build_record_id_xpath() {
    local h="$1"
    local d="$2"

    if [[ "$h" == "@" ]]; then
        printf "%s" "//namesilo/reply/resource_record[host='@' or host='${d}' or host='${d}.']/record_id/text()"
    else
        printf "%s" "//namesilo/reply/resource_record[host='${h}' or host='${h}.${d}' or host='${h}.${d}.']/record_id/text()"
    fi
}

namesilo_api_get() {
    local url="$1"
    local output_file="$2"

    curl --silent --show-error --fail \
        --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
        --max-time "$CURL_MAX_TIME_SEC" \
        "$url" > "$output_file"
}

extract_response_code() {
    local xml_file="$1"
    xmllint --xpath "string(//namesilo/reply/code)" "$xml_file" 2>/dev/null || true
}

extract_record_id() {
    local xml_file="$1"
    local xpath="$2"
    xmllint --xpath "$xpath" "$xml_file" 2>/dev/null || true
}

KNOWN_IP="$(read_file_or_empty "$IP_FILE")"
LAST_LOG_TS="$(read_file_or_empty "$TIME_FILE")"
LAST_LOG_TS="${LAST_LOG_TS:-0}"

read -r CUR_IP RESOLVER < <(get_public_ip) || fail "Unable to determine current public IP via OpenDNS, Google DNS, and HTTP fallback"

# If the current public IP has not changed, skip ALL NameSilo API calls.
# This guarantees there will be no dnsListRecords or dnsUpdateRecord request
# when the observed public IP is identical to the cached value.
if [[ "$CUR_IP" == "$KNOWN_IP" ]]; then
    if (( $(date +%s) > LAST_LOG_TS + NO_CHANGE_LOG_INTERVAL_SEC )); then
        log "No public IP change detected; current IP remains $CUR_IP (resolver/source: $RESOLVER). Skipping NameSilo API update."
        write_timestamp
    fi
    exit 0
fi

log "Public IP changed from '${KNOWN_IP:-<empty>}' to '$CUR_IP' (resolver/source: $RESOLVER). Proceeding with NameSilo update."

LIST_URL="https://www.namesilo.com/api/dnsListRecords?version=1&type=xml&key=${API_KEY}&domain=${DOMAIN}"
if ! namesilo_api_get "$LIST_URL" "$LIST_XML"; then
    fail "Failed to query NameSilo dnsListRecords API"
fi

LIST_CODE="$(extract_response_code "$LIST_XML")"
if [[ "$LIST_CODE" != "300" ]]; then
    fail "NameSilo dnsListRecords returned code '$LIST_CODE' instead of success code '300'"
fi

RECORD_ID_XPATH="$(build_record_id_xpath "$HOST" "$DOMAIN")"
RECORD_ID="$(extract_record_id "$LIST_XML" "$RECORD_ID_XPATH")"
if [[ -z "$RECORD_ID" ]]; then
    fail "Unable to find DNS record ID for host '$HOST' under domain '$DOMAIN'"
fi

UPDATE_URL="https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=${API_KEY}&domain=${DOMAIN}&rrid=${RECORD_ID}&rrhost=${HOST}&rrvalue=${CUR_IP}&rrttl=${TTL}"
if ! namesilo_api_get "$UPDATE_URL" "$UPDATE_XML"; then
    fail "Failed to query NameSilo dnsUpdateRecord API"
fi

UPDATE_CODE="$(extract_response_code "$UPDATE_XML")"
case "$UPDATE_CODE" in
    300)
        printf '%s\n' "$CUR_IP" > "$IP_FILE"
        write_timestamp
        log "Update succeeded. DNS record '${HOST}.${DOMAIN}' now points to ${CUR_IP}."
        ;;
    280)
        printf '%s\n' "$CUR_IP" > "$IP_FILE"
        write_timestamp
        log "NameSilo reported duplicate record; no update required. Current IP is ${CUR_IP}."
        ;;
    *)
        fail "NameSilo dnsUpdateRecord returned unexpected code '$UPDATE_CODE'"
        ;;
esac