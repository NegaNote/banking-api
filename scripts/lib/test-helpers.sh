#!/usr/bin/env bash
# Test helpers library
# Common utilities for HTTP requests, database operations, Kafka, etc.

set -Eeuo pipefail

# Global variables for HTTP interactions
export HTTP_BODY=""
export HTTP_STATUS=""

# Base URLs - overrideable via environment
declare -g AUTH_URL="${AUTH_URL:-http://localhost:8081}"
declare -g BANKING_URL="${BANKING_URL:-http://localhost:8080}"
declare -g ADMINER_URL="${ADMINER_URL:-http://localhost:8090}"
declare -g NOTIFICATION_URL="${NOTIFICATION_URL:-http://localhost:8082}"

# Docker compose helper
declare -g DOCKER=(docker)
declare -g ROOT_DIR="${ROOT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
declare -g COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"

compose() {
    "${DOCKER[@]}" compose \
        --project-directory "$ROOT_DIR" \
        --file "$COMPOSE_FILE" \
        "$@"
}

# HTTP request helper
request() {
    local method="$1"
    local path="$2"
    local token="${3-}"
    local payload="${4-}"
    local base_url="${BASE_URL:-}"
    local -a curl_args
    local response

    if [[ -z "$base_url" ]]; then
        case "$path" in
            /api/auth*|/.well-known*)
                base_url="$AUTH_URL"
                ;;
            *)
                base_url="$BANKING_URL"
                ;;
        esac
    fi

    curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X "$method"
        "${base_url}${path}"
        -H 'Accept: application/json'
    )
    
    if [[ -n "$token" ]]; then
        curl_args+=(-H "Authorization: Bearer $token")
    fi
    if [[ -n "$payload" ]]; then
        curl_args+=(-H 'Content-Type: application/json' --data "$payload")
    fi
    for header in "${@:5}"; do
        curl_args+=(-H "$header")
    done
    
    if ! response="$(curl "${curl_args[@]}" -w $'\n%{http_code}')"; then
        HTTP_STATUS="000"
        HTTP_BODY="Request failed"
        return 1
    fi
    
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}

# Redact sensitive data from response for logging
redact_response() {
    local body="$1"
    
    # Remove tokens from JSON response
    if jq -e . <<<"$body" >/dev/null 2>&1; then
        jq -c 'if type == "object" then del(.token, .access_token, .refresh_token) else . end' <<<"$body"
    else
        printf '%s' "$body"
    fi
}

# Log HTTP interaction (redacted)
log_http() {
    local method="$1"
    local path="$2"
    local status="$3"
    
    printf '[HTTP] %s %s -> %s\n' "$method" "$path" "$status" >&2
    if [[ "$status" != "200" && "$status" != "201" ]]; then
        printf '[HTTP] Response: %s\n' "$(redact_response "$HTTP_BODY")" >&2
    fi
}

# Database query helper
db_query() {
    local service="$1"
    local sql="$2"
    local database
    
    case "$service" in
        auth-db)
            database="authdb"
            ;;
        banking-db)
            database="bankdb"
            ;;
        notification-db)
            database="notificationdb"
            ;;
        reporting-db)
            database="reportingdb"
            ;;
        *)
            printf '[ERROR] Unknown database service: %s\n' "$service" >&2
            return 1
            ;;
    esac
    
    compose exec -T "$service" sh -c \
        "mysql --protocol=socket -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -D \"\$1\" -N -B -e \"\$2\"" \
        sh "$database" "$sql"
}

# Kafka message consumption
kafka_topic_messages() {
    local topic="${1:-banking.money-movements}"
    
    compose exec -T kafka sh -ec '
        /opt/kafka/bin/kafka-console-consumer.sh \
            --bootstrap-server localhost:9092 \
            --topic '"$topic"' \
            --from-beginning \
            --timeout-ms 15000 \
            --property value.deserializer.use.type.headers=false \
            --property print.key=true \
            --property key.separator="|" \
            --property print.value=true \
            --property print.headers=false \
            --property print.partition=false \
            --property print.offset=false \
            --property value.deserializer=org.apache.kafka.common.serialization.StringDeserializer || true
    '
}

# JWT utilities
decode_jwt_segment() {
    local segment="$1"
    local normalized="${segment//-/+}"
    local remainder
    
    normalized="${normalized//_//}"
    remainder=$((${#normalized} % 4))
    while ((remainder != 0)); do
        normalized+='='
        remainder=$(((remainder + 1) % 4))
    done
    printf '%s' "$normalized" | base64 --decode 2>/dev/null
}

extract_jwt_payload() {
    local token="$1"
    local payload_segment
    
    IFS='.' read -r _ payload_segment _ <<<"$token"
    decode_jwt_segment "$payload_segment"
}

tamper_jwt() {
    local token="$1"
    local header
    local payload
    local signature
    local replacement
    
    IFS='.' read -r header payload signature <<<"$token"
    if [[ "${signature:0:1}" == A ]]; then
        replacement=B
    else
        replacement=A
    fi
    printf '%s.%s.%s' "$header" "$payload" "${replacement}${signature:1}"
}

# JSON utilities
canonical_json() {
    jq -cS . <<<"$1"
}

# Assertions for JSON content
assert_json_contains() {
    local filter="$1"
    local description="$2"
    shift 2

    if ! jq -e "$filter" "$@" <<<"$HTTP_BODY" >/dev/null 2>&1; then
        printf '[ASSERT] %s\n' "$description" >&2
        return 1
    fi
}

assert_balance() {
    local expected="$1"

    assert_json_contains \
        ".balance == (\$expected | tonumber)" \
        "Balance assertion" \
        --arg expected "$expected"
}

# Kafka event utilities
kafka_message_matches() {
    local message="$1"
    local event_type="$2"
    local user_id="$3"
    local account_number="$4"
    local amount="$5"
    local result="$6"
    local counterparty="${7-}"
    
    if [[ -z "$counterparty" ]]; then
        jq -e \
            --arg eventType "$event_type" \
            --arg userId "$user_id" \
            --arg accountNumber "$account_number" \
            --arg amount "$amount" \
            --arg result "$result" \
            '.eventType == $eventType and
             (.userId | tostring) == $userId and
             .accountNumber == $accountNumber and
             (.amount | tonumber) == ($amount | tonumber) and
             .result == $result and
             .counterpartyAccountNumber == null' \
            <<<"$message" >/dev/null 2>&1
    else
        jq -e \
            --arg eventType "$event_type" \
            --arg userId "$user_id" \
            --arg accountNumber "$account_number" \
            --arg amount "$amount" \
            --arg result "$result" \
            --arg counterparty "$counterparty" \
            '.eventType == $eventType and
             (.userId | tostring) == $userId and
             .accountNumber == $accountNumber and
             (.amount | tonumber) == ($amount | tonumber) and
             .result == $result and
             .counterpartyAccountNumber == $counterparty' \
            <<<"$message" >/dev/null 2>&1
    fi
}

assert_kafka_event_present() {
    local messages="$1"
    local event_type="$2"
    local user_id="$3"
    local account_number="$4"
    local amount="$5"
    local result="$6"
    local counterparty="${7-}"
    local line
    local value
    
    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        value="${line#*|}"
        if kafka_message_matches "$value" "$event_type" "$user_id" "$account_number" "$amount" "$result" "$counterparty"; then
            return 0
        fi
    done <<<"$messages"
    
    return 1
}

assert_kafka_event_absent() {
    local messages="$1"
    local event_type="$2"
    local user_id="$3"
    local account_number="$4"
    local amount="$5"
    local result="$6"
    local counterparty="${7-}"
    local line
    local value
    
    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        value="${line#*|}"
        if kafka_message_matches "$value" "$event_type" "$user_id" "$account_number" "$amount" "$result" "$counterparty"; then
            return 1
        fi
    done <<<"$messages"
    
    return 0
}

# HTTP status code check
http_status_code() {
    local url="$1"
    
    curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "$url" \
        2>/dev/null || printf '000'
}

# Service status from compose
service_status_line() {
    local service="$1"
    
    compose ps --all --format $'{{.Service}}\t{{.State}}\t{{.Health}}' 2>/dev/null | \
        awk -F $'\t' -v wanted="$service" '$1 == wanted { print; exit }'
}

# Wait for stack to be healthy
wait_for_stack_ready() {
    local timeout="${HEALTH_TIMEOUT:-180}"
    local deadline=$((SECONDS + timeout))
    
    while ((SECONDS < deadline)); do
        local all_healthy=1
        local service row state health
        
        for service in auth-db banking-db notification-db reporting-db auth-service banking-service kafka; do
            row="$(service_status_line "$service")"
            if [[ -z "$row" ]]; then
                all_healthy=0
                break
            fi
            
            IFS=$'\t' read -r _ state health <<<"$row"
            if [[ "$state" != running || "$health" != healthy ]]; then
                all_healthy=0
                break
            fi
        done
        
        if ((all_healthy)); then
            # Also check HTTP endpoints
            local auth_status banking_status adminer_status
            auth_status="$(http_status_code "$AUTH_URL/actuator/health")"
            banking_status="$(http_status_code "$BANKING_URL/actuator/health")"
            adminer_status="$(http_status_code "$ADMINER_URL/")"
            
            if [[ "$auth_status" == 200 && "$banking_status" == 200 && "$adminer_status" == 200 ]]; then
                return 0
            fi
        fi
        
        sleep 2
    done
    
    return 1
}

# Wait for Kafka broker readiness
wait_for_kafka_broker() {
    local timeout="${HEALTH_TIMEOUT:-180}"
    local deadline=$((SECONDS + timeout))
    
    while ((SECONDS < deadline)); do
        local output
        output="$(compose exec -T kafka sh -ec '
            /opt/kafka/bin/kafka-broker-api-versions.sh \
                --bootstrap-server localhost:9092 2>&1 || echo "FAILED"
        ' 2>&1)"
        
        if [[ "$output" != *"FAILED"* ]] && [[ "$output" != *"ERROR"* ]]; then
            return 0
        fi
        
        sleep 2
    done
    
    return 1
}

# Wait for Kafka topic
wait_for_kafka_topic() {
    local topic="${1:-banking.money-movements}"
    local timeout="${HEALTH_TIMEOUT:-180}"
    local deadline=$((SECONDS + timeout))
    
    while ((SECONDS < deadline)); do
        local output
        output="$(compose exec -T kafka sh -ec '
            /opt/kafka/bin/kafka-topics.sh \
                --bootstrap-server localhost:9092 \
                --list 2>&1 | grep -F "'"$topic"'" || echo "NOT_FOUND"
        ' 2>&1)"
        
        if [[ "$output" == *"$topic"* ]]; then
            return 0
        fi
        
        sleep 2
    done
    
    return 1
}

# Export helper functions
export -f compose request redact_response log_http db_query
export -f kafka_topic_messages
export -f decode_jwt_segment extract_jwt_payload tamper_jwt
export -f canonical_json assert_json_contains assert_balance
export -f kafka_message_matches assert_kafka_event_present assert_kafka_event_absent
export -f http_status_code service_status_line
export -f wait_for_stack_ready wait_for_kafka_broker wait_for_kafka_topic
