#!/usr/bin/env bash
#
# NameSilo DDNS one-shot updater.
#
# This script is designed to be executed by a systemd oneshot service. It loads
# general runtime settings and record-specific settings from separate files,
# detects the current public IP through an adaptive provider pool, compares it
# with the last known IP, and updates the configured NameSilo DNS record only
# when the public IP has changed.
#
set -Eeuo pipefail
umask 0077

PROGRAM_NAME="namesilo-ddns-check"
GENERAL_CONFIG_FILE="${NAMESILO_DDNS_CONFIG:-/etc/default/namesilo-ddns}"

log() {
    logger -p daemon.info -t "$PROGRAM_NAME" -- "$*" 2>/dev/null || true
}

warn() {
    logger -p daemon.warning -t "$PROGRAM_NAME" -- "WARNING: $*" 2>/dev/null || true
}

fail() {
    logger -p daemon.err -t "$PROGRAM_NAME" -- "ERROR: $*" 2>/dev/null || true
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

require_uint_config() {
    local name="$1"
    local value="${!name}"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "Invalid numeric configuration $name='$value'"
}

uint_or_zero() {
    local value="$1"
    local field="$2"
    local id="$3"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    else
        warn "Invalid numeric provider statistic field '$field' for '$id'; using 0."
        printf '0\n'
    fi
}

# Load general runtime configuration first.
if [[ -r "$GENERAL_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$GENERAL_CONFIG_FILE"
else
    fail "General configuration file not found or unreadable: $GENERAL_CONFIG_FILE"
fi

# Load record-specific configuration second.
DOMAIN_CONFIG_FILE="${NAMESILO_DDNS_RECORD_CONFIG:-${DOMAIN_CONFIG_FILE:-/etc/namesilo-ddns/record.conf}}"
if [[ -r "$DOMAIN_CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$DOMAIN_CONFIG_FILE"
else
    fail "Domain configuration file not found or unreadable: $DOMAIN_CONFIG_FILE"
fi

: "${API_KEY:?API_KEY must be set in $DOMAIN_CONFIG_FILE}"
: "${DOMAIN:?DOMAIN must be set in $DOMAIN_CONFIG_FILE}"
: "${HOST:?HOST must be set in $DOMAIN_CONFIG_FILE}"

[[ "$API_KEY" != "REPLACE_WITH_YOUR_NAMESILO_API_KEY" ]] || fail "API_KEY still contains the packaged placeholder in $DOMAIN_CONFIG_FILE"
[[ "$DOMAIN" != "example.com" ]] || fail "DOMAIN still contains the packaged placeholder in $DOMAIN_CONFIG_FILE"

STATE_DIR="${STATE_DIR:-/var/lib/namesilo-ddns}"
NO_CHANGE_LOG_INTERVAL_SEC="${NO_CHANGE_LOG_INTERVAL_SEC:-86400}"
ENABLE_STARTUP_RANDOM_DELAY="${ENABLE_STARTUP_RANDOM_DELAY:-yes}"
STARTUP_RANDOM_DELAY_MAX_SEC="${STARTUP_RANDOM_DELAY_MAX_SEC:-5}"
TTL="${TTL:-3600}"

CURL_CONNECT_TIMEOUT_SEC="${CURL_CONNECT_TIMEOUT_SEC:-10}"
CURL_MAX_TIME_SEC="${CURL_MAX_TIME_SEC:-30}"
DIG_TIMEOUT_SEC="${DIG_TIMEOUT_SEC:-3}"
DIG_TRIES="${DIG_TRIES:-1}"
DNS_LOOKUP_RETRY_DELAY_SEC="${DNS_LOOKUP_RETRY_DELAY_SEC:-5}"

IP_FAMILY="${IP_FAMILY:-4}"
IP_PROVIDER_MODE="${IP_PROVIDER_MODE:-adaptive}"
ENABLE_HTTP_PROVIDERS="${ENABLE_HTTP_PROVIDERS:-${ENABLE_HTTP_FALLBACK:-yes}}"
HTTP_IP_ECHO_PRIMARY="${HTTP_IP_ECHO_PRIMARY:-https://ifconfig.co/ip}"
HTTP_IP_ECHO_SECONDARY="${HTTP_IP_ECHO_SECONDARY:-https://ifconfig.me/ip}"
HTTP_IP_ECHO_PROVIDERS="${HTTP_IP_ECHO_PROVIDERS:-$HTTP_IP_ECHO_PRIMARY $HTTP_IP_ECHO_SECONDARY https://ifconfig.io/ip https://ident.me https://icanhazip.com https://api.ipify.org}"
DNS_IP_ECHO_PROVIDERS="${DNS_IP_ECHO_PROVIDERS:-opendns google}"

PROVIDER_STATS_FILE="${PROVIDER_STATS_FILE:-}"
PROVIDER_MAX_CONSECUTIVE_FAILS="${PROVIDER_MAX_CONSECUTIVE_FAILS:-3}"
PROVIDER_COOLDOWN_BASE_SEC="${PROVIDER_COOLDOWN_BASE_SEC:-300}"
PROVIDER_COOLDOWN_MAX_SEC="${PROVIDER_COOLDOWN_MAX_SEC:-3600}"
PROVIDER_EXPLORATION_INTERVAL_SEC="${PROVIDER_EXPLORATION_INTERVAL_SEC:-86400}"
PROVIDER_LOG_RANKING="${PROVIDER_LOG_RANKING:-no}"

require_uint_config NO_CHANGE_LOG_INTERVAL_SEC
require_uint_config STARTUP_RANDOM_DELAY_MAX_SEC
require_uint_config TTL
require_uint_config CURL_CONNECT_TIMEOUT_SEC
require_uint_config CURL_MAX_TIME_SEC
require_uint_config DIG_TIMEOUT_SEC
require_uint_config DIG_TRIES
require_uint_config DNS_LOOKUP_RETRY_DELAY_SEC
require_uint_config PROVIDER_MAX_CONSECUTIVE_FAILS
require_uint_config PROVIDER_COOLDOWN_BASE_SEC
require_uint_config PROVIDER_COOLDOWN_MAX_SEC
require_uint_config PROVIDER_EXPLORATION_INTERVAL_SEC

require_command curl
require_command dig
require_command xmllint
require_command flock
require_command awk
require_command grep
require_command sed
require_command sort
require_command tr
require_command mktemp
require_command date
require_command chmod
require_command mkdir
require_command cat
require_command mv
require_command rm
require_command dirname
require_command sleep

ensure_state_dir() {
    if ! mkdir -p "$STATE_DIR"; then
        fail "Unable to create state directory: $STATE_DIR"
    fi
    [[ -d "$STATE_DIR" ]] || fail "State path exists but is not a directory: $STATE_DIR"
    chmod 0750 "$STATE_DIR" || warn "Unable to chmod state directory to 0750: $STATE_DIR"
    [[ -w "$STATE_DIR" ]] || fail "State directory is not writable; cannot safely maintain last IP cache: $STATE_DIR"
}

ensure_state_dir

if [[ -z "$PROVIDER_STATS_FILE" ]]; then
    PROVIDER_STATS_FILE="$STATE_DIR/provider_stats.tsv"
fi

STATE_BASENAME="$(printf '%s_%s' "$HOST" "$DOMAIN" | tr '/ ' '__')"
IP_FILE="$STATE_DIR/${STATE_BASENAME}.last_ip"
TIME_FILE="$STATE_DIR/${STATE_BASENAME}.last_log_time"
LOCK_FILE="$STATE_DIR/${STATE_BASENAME}.lock"

TMPDIR="$(mktemp -d /tmp/namesilo-ddns.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
LIST_XML="$TMPDIR/dns_list_records.xml"
UPDATE_XML="$TMPDIR/dns_update_record.xml"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Another updater instance is already running; exiting."
    exit 0
fi

if [[ "$ENABLE_STARTUP_RANDOM_DELAY" == "yes" && "$STARTUP_RANDOM_DELAY_MAX_SEC" -gt 0 ]]; then
    sleep "$(( RANDOM % (STARTUP_RANDOM_DELAY_MAX_SEC + 1) ))"
fi

read_critical_state_file_or_empty() {
    local path="$1"
    [[ ! -e "$path" ]] && return 0
    [[ -f "$path" ]] || fail "Critical state path exists but is not a regular file: $path"
    [[ -r "$path" ]] || fail "Critical state file exists but is not readable: $path"
    cat "$path"
}

read_optional_state_file_or_empty() {
    local path="$1"
    [[ ! -e "$path" ]] && return 0
    if [[ ! -f "$path" ]]; then
        warn "Optional state path exists but is not a regular file; ignoring: $path"
        return 0
    fi
    if [[ ! -r "$path" ]]; then
        warn "Optional state file exists but is not readable; ignoring: $path"
        return 0
    fi
    cat "$path"
}

write_critical_state_file() {
    local path="$1"
    local value="$2"
    printf '%s\n' "$value" > "$path" || fail "Unable to write critical state file: $path"
    chmod 0600 "$path" || warn "Unable to chmod critical state file to 0600: $path"
}

write_timestamp() {
    if ! date +%s > "$TIME_FILE"; then
        warn "Unable to write optional timestamp state file: $TIME_FILE"
        return 0
    fi
    chmod 0600 "$TIME_FILE" || warn "Unable to chmod optional timestamp state file to 0600: $TIME_FILE"
}

now_ms() {
    local value
    value="$(date +%s%3N)"
    if [[ "$value" == *N* ]]; then
        printf '%s\n' "$(( $(date +%s) * 1000 ))"
    else
        printf '%s\n' "$value"
    fi
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

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ "$1" == *:* ]]; }

is_valid_ip_for_family() {
    case "$IP_FAMILY" in
        4) is_ipv4 "$1" ;;
        6) is_ipv6 "$1" ;;
        auto) is_ipv4 "$1" || is_ipv6 "$1" ;;
        *) return 1 ;;
    esac
}

sanitize_provider_id() {
    printf '%s_%s' "$1" "$2" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

declare -A STAT_TYPE=()
declare -A STAT_ENDPOINT=()
declare -A STAT_SUCCESS=()
declare -A STAT_FAIL=()
declare -A STAT_CONSECUTIVE_FAIL=()
declare -A STAT_EWMA_MS=()
declare -A STAT_LAST_SUCCESS=()
declare -A STAT_LAST_FAIL=()
declare -A STAT_COOLDOWN_UNTIL=()
declare -A STAT_LAST_ATTEMPT=()

declare -a PROVIDER_IDS=()
declare -a PROVIDER_TYPES=()
declare -a PROVIDER_ENDPOINTS=()

load_provider_stats() {
    local id provider_type endpoint success fail_count consecutive_fail ewma_ms last_success last_fail cooldown_until last_attempt

    if [[ ! -e "$PROVIDER_STATS_FILE" ]]; then
        log "Provider statistics file not found; starting with empty provider statistics: $PROVIDER_STATS_FILE"
        return 0
    fi
    if [[ ! -f "$PROVIDER_STATS_FILE" ]]; then
        warn "Provider statistics path exists but is not a regular file; using empty provider statistics: $PROVIDER_STATS_FILE"
        return 0
    fi
    if [[ ! -r "$PROVIDER_STATS_FILE" ]]; then
        warn "Provider statistics file exists but is not readable; using empty provider statistics: $PROVIDER_STATS_FILE"
        return 0
    fi

    while IFS=$'\t' read -r id provider_type endpoint success fail_count consecutive_fail ewma_ms last_success last_fail cooldown_until last_attempt; do
        [[ -z "${id:-}" || "$id" == "id" ]] && continue
        STAT_TYPE["$id"]="${provider_type:-}"
        STAT_ENDPOINT["$id"]="${endpoint:-}"
        STAT_SUCCESS["$id"]="$(uint_or_zero "${success:-0}" success "$id")"
        STAT_FAIL["$id"]="$(uint_or_zero "${fail_count:-0}" fail "$id")"
        STAT_CONSECUTIVE_FAIL["$id"]="$(uint_or_zero "${consecutive_fail:-0}" consecutive_fail "$id")"
        STAT_EWMA_MS["$id"]="$(uint_or_zero "${ewma_ms:-0}" ewma_ms "$id")"
        STAT_LAST_SUCCESS["$id"]="$(uint_or_zero "${last_success:-0}" last_success "$id")"
        STAT_LAST_FAIL["$id"]="$(uint_or_zero "${last_fail:-0}" last_fail "$id")"
        STAT_COOLDOWN_UNTIL["$id"]="$(uint_or_zero "${cooldown_until:-0}" cooldown_until "$id")"
        STAT_LAST_ATTEMPT["$id"]="$(uint_or_zero "${last_attempt:-0}" last_attempt "$id")"
    done < "$PROVIDER_STATS_FILE"
}

register_provider() {
    local provider_type="$1"
    local endpoint="$2"
    local id

    id="$(sanitize_provider_id "$provider_type" "$endpoint")"
    PROVIDER_IDS+=("$id")
    PROVIDER_TYPES+=("$provider_type")
    PROVIDER_ENDPOINTS+=("$endpoint")

    STAT_TYPE["$id"]="${STAT_TYPE[$id]:-$provider_type}"
    STAT_ENDPOINT["$id"]="${STAT_ENDPOINT[$id]:-$endpoint}"
    STAT_SUCCESS["$id"]="${STAT_SUCCESS[$id]:-0}"
    STAT_FAIL["$id"]="${STAT_FAIL[$id]:-0}"
    STAT_CONSECUTIVE_FAIL["$id"]="${STAT_CONSECUTIVE_FAIL[$id]:-0}"
    STAT_EWMA_MS["$id"]="${STAT_EWMA_MS[$id]:-0}"
    STAT_LAST_SUCCESS["$id"]="${STAT_LAST_SUCCESS[$id]:-0}"
    STAT_LAST_FAIL["$id"]="${STAT_LAST_FAIL[$id]:-0}"
    STAT_COOLDOWN_UNTIL["$id"]="${STAT_COOLDOWN_UNTIL[$id]:-0}"
    STAT_LAST_ATTEMPT["$id"]="${STAT_LAST_ATTEMPT[$id]:-0}"
}

build_configured_providers() {
    local endpoint provider
    PROVIDER_IDS=()
    PROVIDER_TYPES=()
    PROVIDER_ENDPOINTS=()

    if [[ "$ENABLE_HTTP_PROVIDERS" == "yes" ]]; then
        for endpoint in $HTTP_IP_ECHO_PROVIDERS; do
            [[ -n "$endpoint" ]] && register_provider http "$endpoint"
        done
    fi

    for provider in $DNS_IP_ECHO_PROVIDERS; do
        case "$provider" in
            opendns|google) register_provider dns "$provider" ;;
            "") ;;
            *) warn "Ignoring unsupported DNS IP provider: $provider" ;;
        esac
    done
}

save_provider_stats() {
    local stats_dir tmp_file id output rc

    if [[ -e "$PROVIDER_STATS_FILE" && ! -f "$PROVIDER_STATS_FILE" ]]; then
        warn "Provider statistics path exists but is not a regular file; adaptive ranking will not persist this run: $PROVIDER_STATS_FILE"
        return 0
    fi

    stats_dir="$(dirname "$PROVIDER_STATS_FILE")"
    set +e
    output="$(mkdir -p "$stats_dir" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        warn "Unable to create provider statistics directory: $stats_dir; output=$output"
        return 0
    fi
    [[ -d "$stats_dir" ]] || { warn "Provider statistics directory path exists but is not a directory: $stats_dir"; return 0; }
    [[ -w "$stats_dir" ]] || { warn "Provider statistics directory is not writable; adaptive ranking will not persist this run: $stats_dir"; return 0; }

    tmp_file="$TMPDIR/provider_stats.tsv"
    if ! {
        printf 'id\ttype\tendpoint\tsuccess\tfail\tconsecutive_fail\tewma_ms\tlast_success\tlast_fail\tcooldown_until\tlast_attempt\n'
        for id in "${PROVIDER_IDS[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$id" "${STAT_TYPE[$id]:-}" "${STAT_ENDPOINT[$id]:-}" \
                "${STAT_SUCCESS[$id]:-0}" "${STAT_FAIL[$id]:-0}" "${STAT_CONSECUTIVE_FAIL[$id]:-0}" \
                "${STAT_EWMA_MS[$id]:-0}" "${STAT_LAST_SUCCESS[$id]:-0}" "${STAT_LAST_FAIL[$id]:-0}" \
                "${STAT_COOLDOWN_UNTIL[$id]:-0}" "${STAT_LAST_ATTEMPT[$id]:-0}"
        done
    } > "$tmp_file"; then
        warn "Unable to generate temporary provider statistics file: $tmp_file"
        rm -f "$tmp_file"
        return 0
    fi

    chmod 0640 "$tmp_file" || warn "Unable to chmod temporary provider statistics file: $tmp_file"
    set +e
    output="$(mv "$tmp_file" "$PROVIDER_STATS_FILE" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        warn "Unable to write provider statistics to $PROVIDER_STATS_FILE; adaptive ranking will not persist this run. output=$output"
        rm -f "$tmp_file"
        return 0
    fi
}

provider_score() {
    local id="$1"
    local order="$2"
    local ignore_cooldown="$3"
    local now_sec success fail_count consecutive_fail ewma_ms cooldown_until last_attempt
    local total success_rate_score latency_penalty fail_penalty exploration_bonus order_tie_breaker score

    now_sec="$(date +%s)"
    success="${STAT_SUCCESS[$id]:-0}"
    fail_count="${STAT_FAIL[$id]:-0}"
    consecutive_fail="${STAT_CONSECUTIVE_FAIL[$id]:-0}"
    ewma_ms="${STAT_EWMA_MS[$id]:-0}"
    cooldown_until="${STAT_COOLDOWN_UNTIL[$id]:-0}"
    last_attempt="${STAT_LAST_ATTEMPT[$id]:-0}"

    if [[ "$IP_PROVIDER_MODE" == "adaptive" && "$ignore_cooldown" != "yes" ]]; then
        if (( cooldown_until > now_sec && now_sec - last_attempt < PROVIDER_EXPLORATION_INTERVAL_SEC )); then
            printf '%s\n' ""
            return 0
        fi
    fi

    total=$(( success + fail_count + 1 ))
    success_rate_score=$(( success * 1000 / total ))
    latency_penalty=$(( ewma_ms / 10 ))
    fail_penalty=$(( consecutive_fail * 200 ))
    exploration_bonus=0
    order_tie_breaker=$(( -1 * order * 10 ))

    if (( last_attempt == 0 || now_sec - last_attempt >= PROVIDER_EXPLORATION_INTERVAL_SEC )); then
        exploration_bonus=150
    fi

    score=$(( success_rate_score + exploration_bonus + order_tie_breaker - latency_penalty - fail_penalty ))
    printf '%s\n' "$score"
}

build_ranked_provider_lines() {
    local ignore_cooldown="$1"
    local entries=()
    local index id provider_type endpoint score ranked

    for index in "${!PROVIDER_IDS[@]}"; do
        id="${PROVIDER_IDS[$index]}"
        provider_type="${PROVIDER_TYPES[$index]}"
        endpoint="${PROVIDER_ENDPOINTS[$index]}"

        case "$IP_PROVIDER_MODE" in
            static) score=$(( 1000 - index )) ;;
            adaptive)
                score="$(provider_score "$id" "$index" "$ignore_cooldown")"
                [[ -z "$score" ]] && continue
                ;;
            *) fail "Invalid IP_PROVIDER_MODE value '$IP_PROVIDER_MODE'. Expected: adaptive or static" ;;
        esac
        entries+=("${score}|${index}|${id}|${provider_type}|${endpoint}")
    done

    [[ ${#entries[@]} -gt 0 ]] || return 1
    ranked="$(printf '%s\n' "${entries[@]}" | sort -t '|' -k1,1nr -k2,2n)"
    printf '%s\n' "$ranked"
}

update_provider_success() {
    local id="$1"
    local elapsed_ms="$2"
    local now_sec old_ewma new_ewma

    now_sec="$(date +%s)"
    old_ewma="${STAT_EWMA_MS[$id]:-0}"
    if (( old_ewma <= 0 )); then
        new_ewma="$elapsed_ms"
    else
        new_ewma=$(( (old_ewma * 7 + elapsed_ms * 3) / 10 ))
    fi

    STAT_SUCCESS["$id"]=$(( ${STAT_SUCCESS[$id]:-0} + 1 ))
    STAT_CONSECUTIVE_FAIL["$id"]=0
    STAT_EWMA_MS["$id"]="$new_ewma"
    STAT_LAST_SUCCESS["$id"]="$now_sec"
    STAT_COOLDOWN_UNTIL["$id"]=0
    STAT_LAST_ATTEMPT["$id"]="$now_sec"
}

update_provider_failure() {
    local id="$1"
    local elapsed_ms="$2"
    local now_sec consecutive_fail cooldown_sec old_ewma

    now_sec="$(date +%s)"
    consecutive_fail=$(( ${STAT_CONSECUTIVE_FAIL[$id]:-0} + 1 ))
    old_ewma="${STAT_EWMA_MS[$id]:-0}"

    STAT_FAIL["$id"]=$(( ${STAT_FAIL[$id]:-0} + 1 ))
    STAT_CONSECUTIVE_FAIL["$id"]="$consecutive_fail"
    STAT_LAST_FAIL["$id"]="$now_sec"
    STAT_LAST_ATTEMPT["$id"]="$now_sec"

    if (( old_ewma <= 0 )); then
        STAT_EWMA_MS["$id"]="$elapsed_ms"
    else
        STAT_EWMA_MS["$id"]=$(( (old_ewma * 9 + elapsed_ms) / 10 ))
    fi

    if (( consecutive_fail >= PROVIDER_MAX_CONSECUTIVE_FAILS )); then
        cooldown_sec=$(( PROVIDER_COOLDOWN_BASE_SEC * consecutive_fail ))
        if (( cooldown_sec > PROVIDER_COOLDOWN_MAX_SEC )); then
            cooldown_sec="$PROVIDER_COOLDOWN_MAX_SEC"
        fi
        STAT_COOLDOWN_UNTIL["$id"]=$(( now_sec + cooldown_sec ))
        log "Provider '${STAT_ENDPOINT[$id]:-$id}' entered cooldown for ${cooldown_sec}s after ${consecutive_fail} consecutive failures."
    fi
}

public_ip_from_http() {
    local url="$1"
    local output rc ip curl_family_arg

    curl_family_arg="$(get_curl_family_args)"
    if [[ -n "$curl_family_arg" ]]; then
        output="$(run_capture curl "$curl_family_arg" --silent --show-error --fail --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" --max-time "$CURL_MAX_TIME_SEC" "$url")"
    else
        output="$(run_capture curl --silent --show-error --fail --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" --max-time "$CURL_MAX_TIME_SEC" "$url")"
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
    [[ -n "$ip" ]] || { log "OpenDNS lookup returned empty result via ${resolver}; raw_output=${output}"; return 1; }
    is_valid_ip_for_family "$ip" || { log "OpenDNS lookup returned unexpected content via ${resolver}; raw_output=${output}; parsed_ip=${ip}; ip_family=${IP_FAMILY}"; return 1; }
    printf '%s %s\n' "$ip" "opendns:${resolver}"
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
    [[ -n "$ip" ]] || { log "Google DNS lookup returned empty/parse-failed result via ${resolver}; raw_output=${output}"; return 1; }
    is_valid_ip_for_family "$ip" || { log "Google DNS lookup returned unexpected content via ${resolver}; raw_output=${output}; parsed_ip=${ip}; ip_family=${IP_FAMILY}"; return 1; }
    printf '%s %s\n' "$ip" "google:${resolver}"
}

try_provider() {
    local provider_type="$1"
    local endpoint="$2"

    case "$provider_type" in
        http) public_ip_from_http "$endpoint" ;;
        dns)
            case "$endpoint" in
                opendns) public_ip_from_opendns ;;
                google) public_ip_from_google ;;
                *) warn "Unsupported DNS provider: $endpoint"; return 1 ;;
            esac
            ;;
        *) warn "Unsupported provider type: $provider_type"; return 1 ;;
    esac
}

get_public_ip() {
    local ranked_lines score order id provider_type endpoint result start_ms elapsed_ms ranked_ok

    load_provider_stats
    build_configured_providers
    [[ ${#PROVIDER_IDS[@]} -gt 0 ]] || fail "No public IP providers configured"

    ranked_ok="yes"
    ranked_lines="$(build_ranked_provider_lines no)" || ranked_ok="no"
    if [[ "$ranked_ok" != "yes" ]]; then
        log "All adaptive providers are cooling down; retrying configured providers once without cooldown filtering."
        ranked_lines="$(build_ranked_provider_lines yes)" || return 1
    fi

    if [[ "$PROVIDER_LOG_RANKING" == "yes" ]]; then
        log "Provider ranking: $(printf '%s' "$ranked_lines" | tr '\n' ';')"
    fi

    while IFS='|' read -r score order id provider_type endpoint; do
        [[ -z "${id:-}" ]] && continue
        log "Trying public IP provider: type=${provider_type}, endpoint=${endpoint}, score=${score}."
        start_ms="$(now_ms)"
        if result="$(try_provider "$provider_type" "$endpoint")"; then
            elapsed_ms=$(( $(now_ms) - start_ms ))
            update_provider_success "$id" "$elapsed_ms"
            save_provider_stats
            log "Public IP provider succeeded: endpoint=${endpoint}, elapsed_ms=${elapsed_ms}."
            printf '%s\n' "$result"
            return 0
        fi
        elapsed_ms=$(( $(now_ms) - start_ms ))
        update_provider_failure "$id" "$elapsed_ms"
        save_provider_stats
    done <<< "$ranked_lines"

    return 1
}

build_record_id_xpath() {
    if [[ "$1" == "@" ]]; then
        printf "%s" "//namesilo/reply/resource_record[host='@' or host='$2' or host='$2.']/record_id/text()"
    else
        printf "%s" "//namesilo/reply/resource_record[host='$1' or host='$1.$2' or host='$1.$2.']/record_id/text()"
    fi
}

namesilo_api_get() {
    curl --silent --show-error --fail --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" --max-time "$CURL_MAX_TIME_SEC" "$1" > "$2"
}

extract_response_code() {
    xmllint --xpath "string(//namesilo/reply/code)" "$1" 2>/dev/null || true
}

extract_record_id() {
    xmllint --xpath "$2" "$1" 2>/dev/null || true
}

KNOWN_IP="$(read_critical_state_file_or_empty "$IP_FILE")"
LAST_LOG_TS="$(read_optional_state_file_or_empty "$TIME_FILE")"
LAST_LOG_TS="${LAST_LOG_TS:-0}"
LAST_LOG_TS="$(uint_or_zero "$LAST_LOG_TS" last_log_time "$TIME_FILE")"

read -r CUR_IP RESOLVER < <(get_public_ip) || fail "Unable to determine current public IP via configured provider pool"

# If the current public IP has not changed, skip ALL NameSilo API calls.
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
[[ "$LIST_CODE" == "300" ]] || fail "NameSilo dnsListRecords returned code '$LIST_CODE' instead of success code '300'"

RECORD_ID_XPATH="$(build_record_id_xpath "$HOST" "$DOMAIN")"
RECORD_ID="$(extract_record_id "$LIST_XML" "$RECORD_ID_XPATH")"
[[ -n "$RECORD_ID" ]] || fail "Unable to find DNS record ID for host '$HOST' under domain '$DOMAIN'"

UPDATE_URL="https://www.namesilo.com/api/dnsUpdateRecord?version=1&type=xml&key=${API_KEY}&domain=${DOMAIN}&rrid=${RECORD_ID}&rrhost=${HOST}&rrvalue=${CUR_IP}&rrttl=${TTL}"
if ! namesilo_api_get "$UPDATE_URL" "$UPDATE_XML"; then
    fail "Failed to query NameSilo dnsUpdateRecord API"
fi

UPDATE_CODE="$(extract_response_code "$UPDATE_XML")"
case "$UPDATE_CODE" in
    300)
        write_critical_state_file "$IP_FILE" "$CUR_IP"
        write_timestamp
        log "Update succeeded. DNS record '${HOST}.${DOMAIN}' now points to ${CUR_IP}."
        ;;
    280)
        write_critical_state_file "$IP_FILE" "$CUR_IP"
        write_timestamp
        log "NameSilo reported duplicate record; no update required. Current IP is ${CUR_IP}."
        ;;
    *)
        fail "NameSilo dnsUpdateRecord returned unexpected code '$UPDATE_CODE'"
        ;;
esac
