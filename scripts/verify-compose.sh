#!/usr/bin/env bash
# shellcheck disable=SC2016

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
AUTH_URL="${AUTH_URL:-http://localhost:8081}"
BANKING_URL="${BANKING_URL:-http://localhost:8080}"
ADMINER_URL="${ADMINER_URL:-http://localhost:8090}"
NOTIFICATION_URL="${NOTIFICATION_URL:-http://localhost:8082}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
FRESH_START=0
NO_SUDO=0

usage() {
    cat <<'EOF'
Usage: scripts/verify-compose.sh [options]

Starts the stack, verifies the authenticated auth and banking APIs, and
leaves the stack running when finished.

Options:
  --fresh       Remove Compose volumes before starting (destructive).
  --no-sudo     Use docker directly instead of sudo docker.
  -h, --help    Show this help.

Environment:
  AUTH_URL, BANKING_URL, ADMINER_URL, HEALTH_TIMEOUT
EOF
}

while (($# > 0)); do
    case "$1" in
        --fresh)
            FRESH_START=1
            ;;
        --no-sudo)
            NO_SUDO=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if ((NO_SUDO)); then
    DOCKER=(docker)
else
    # Check if docker needs sudo by trying without first
    if docker compose version >/dev/null 2>&1; then
        DOCKER=(docker)
    else
        DOCKER=(sudo docker)
    fi
fi

HTTP_BODY=
HTTP_STATUS=

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    if [[ -n "$HTTP_BODY" ]]; then
        if jq -e . <<<"$HTTP_BODY" >/dev/null 2>&1; then
            jq -c 'if type == "object" then del(.token) else . end' <<<"$HTTP_BODY" >&2
        else
            printf '%s\n' "$HTTP_BODY" >&2
        fi
    fi
    exit 1
}

pass() {
    printf '[PASS] %s\n' "$1"
}

require_commands() {
    local command_name
    local required_commands=(awk base64 curl date find git grep jq sed sleep sort wc)

    if ((NO_SUDO)); then
        required_commands+=(docker)
    else
        required_commands+=(docker sudo)
    fi

    for command_name in "${required_commands[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            fail "Missing required command: $command_name"
        fi
    done
}

compose() {
    "${DOCKER[@]}" compose \
        --project-directory "$ROOT_DIR" \
        --file "$COMPOSE_FILE" \
        "$@"
}

check_layout() {
    local service
    local migration_count
    local -a expected_services=(auth-db banking-db notification-db auth-service banking-service notification-service adminer jaeger kafka kafka-ui)
    local -a configured_services
    local configured_service_output
    local submodule_status

    [[ -f "$COMPOSE_FILE" ]] || fail "Missing root docker-compose.yml"

    for service in auth-service banking-service; do
        [[ -d "$ROOT_DIR/$service" ]] || fail "Missing submodule directory: $service"
        [[ -f "$ROOT_DIR/$service/Dockerfile" ]] || fail "Missing $service/Dockerfile"
        migration_count="$(
            find "$ROOT_DIR/$service/src/main/resources/db/migration" \
                -maxdepth 1 -type f -name 'V*__*.sql' -print | wc -l
        )"
        if [[ "$migration_count" -lt 1 ]]; then
            fail "No Flyway migrations found for $service"
        fi
    done

    submodule_status="$(git -C "$ROOT_DIR" submodule status --recursive)"
    while IFS= read -r line; do
        [[ "$line" != -* ]] || fail "Uninitialized submodule: ${line:1}"
    done <<<"$submodule_status"
    pass 'Sibling submodules, Dockerfiles, and Flyway migrations are present'

    if ! configured_service_output="$(compose config --services)"; then
        fail 'Unable to render docker-compose.yml'
    fi
    mapfile -t configured_services <<<"$configured_service_output"
    if [[ "${#configured_services[@]}" -ne "${#expected_services[@]}" ]]; then
        fail "Expected ${#expected_services[@]} Compose services, found ${#configured_services[@]}"
    fi

    for service in "${expected_services[@]}"; do
        if ! printf '%s\n' "${configured_services[@]}" | grep -Fxq "$service"; then
            fail "Compose is missing service: $service"
        fi
    done
    pass 'Compose defines the two databases, two services, and Adminer'
}

compose_status() {
    compose ps --all --format $'{{.Service}}\t{{.State}}\t{{.Health}}'
}

service_status_line() {
    local service="$1"
    local status

    status="$(compose_status 2>/dev/null || true)"
    awk -F $'\t' -v wanted="$service" '$1 == wanted { print; exit }' <<<"$status"
}

http_status() {
    local url="$1"

    curl -sS --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "$url" \
        2>/dev/null || printf '000'
}

wait_for_stack() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local service
    local row
    local state
    local health
    local adminer_status
    local auth_status
    local banking_status
    local notification_status
    local ready

    while ((SECONDS < deadline)); do
        ready=1
        for service in auth-db banking-db notification-db auth-service banking-service kafka; do
            row="$(service_status_line "$service")"
            if [[ -z "$row" ]]; then
                ready=0
                continue
            fi
            IFS=$'\t' read -r _ state health <<<"$row"
            if [[ "$state" == running &&
                ( -z "$health" || "$health" == "<no value>" ) ]]; then
                fail "$service does not report a Compose health status"
            fi
            if [[ "$state" != running || "$health" != healthy ]]; then
                ready=0
            fi
        done

        row="$(service_status_line adminer)"
        if [[ -z "$row" ]]; then
            ready=0
        else
            IFS=$'\t' read -r _ state health <<<"$row"
            [[ "$state" == running ]] || ready=0
        fi

        auth_status="$(http_status "$AUTH_URL/actuator/health")"
        banking_status="$(http_status "$BANKING_URL/actuator/health")"
        adminer_status="$(http_status "$ADMINER_URL/")"
        if [[ "$auth_status" != 200 || "$banking_status" != 200 || "$adminer_status" != 200 ]]; then
            ready=0
        fi

        if ((ready)); then
            pass 'All required containers are running and healthy'
            pass 'Auth, banking, and Adminer respond over HTTP'
            return
        fi
        sleep 5
    done

    compose ps --all >&2 || true
    fail "Stack did not become healthy within ${HEALTH_TIMEOUT}s"
}

wait_for_kafka_broker() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local output

    while ((SECONDS < deadline)); do
        output="$(compose exec -T kafka sh -ec '
            /opt/kafka/bin/kafka-broker-api-versions.sh \
                --bootstrap-server localhost:9092 2>&1 || echo "FAILED"
        ' 2>&1)"

        if [[ "$output" != *"FAILED"* ]] && [[ "$output" != *"ERROR"* ]]; then
            pass 'Kafka broker is initialized and accepting connections'
            return
        fi

        sleep 2
    done

    fail "Kafka broker did not initialize within ${HEALTH_TIMEOUT}s"
}

wait_for_kafka_topic() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local topic_name='banking.money-movements'
    local output

    while ((SECONDS < deadline)); do
        output="$(compose exec -T kafka sh -ec '
            /opt/kafka/bin/kafka-topics.sh \
                --bootstrap-server localhost:9092 \
                --list 2>&1 | grep -F "banking.money-movements" || echo "NOT_FOUND"
        ' 2>&1)"

        if [[ "$output" == *"banking.money-movements"* ]]; then
            pass "Kafka topic '$topic_name' is ready"
            return
        fi

        sleep 2
    done

    fail "Kafka topic '$topic_name' was not created within ${HEALTH_TIMEOUT}s"
}

wait_for_kafka_group_coordination() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT))
    local output

    while ((SECONDS < deadline)); do
        output="$(compose exec -T kafka sh -ec '
            /opt/kafka/bin/kafka-consumer-groups.sh \
                --bootstrap-server localhost:9092 \
                --list 2>&1 || echo "FAILED"
        ' 2>&1)"

        if [[ "$output" != *"FAILED"* ]] && [[ "$output" != *"error"* ]]; then
            pass 'Kafka group coordinator is ready'
            return
        fi

        sleep 2
    done

    fail "Kafka group coordinator did not initialize within ${HEALTH_TIMEOUT}s"
}

request() {
    local method="$1"
    local path="$2"
    local token="${3-}"
    local payload="${4-}"
    local response
    local -a curl_args
    local header

    curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X "$method"
        "$BASE_URL$path"
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
        fail "Request failed: $method $path"
    fi
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}

expect_status() {
    local expected="$1"
    local description="$2"

    [[ "$HTTP_STATUS" == "$expected" ]] ||
        fail "$description: expected HTTP $expected, got HTTP $HTTP_STATUS"
}

expect_status_any() {
    local description="$1"
    shift
    local expected

    for expected in "$@"; do
        [[ "$HTTP_STATUS" == "$expected" ]] && return
    done
    fail "$description: expected HTTP $*, got HTTP $HTTP_STATUS"
}

assert_json() {
    local filter="$1"
    local description="$2"
    shift 2

    if ! jq -e "$@" "$filter" <<<"$HTTP_BODY" >/dev/null 2>&1; then
        fail "$description"
    fi
}

canonical_json() {
    jq -cS . <<<"$1"
}

assert_balance() {
    local expected="$1"
    local description="$2"

    assert_json \
        '.balance == ($expected | tonumber)' \
        "$description" \
        --arg expected "$expected"
}

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

assert_rs256_token() {
    local token="$1"
    local description="$2"
    local token_header
    local header_json

    if [[ ! "$token" =~ ^[^.]+\.[^.]+\.[^.]+$ ]]; then
        fail "$description did not return a three-part JWT"
    fi
    token_header="${token%%.*}"
    if ! header_json="$(decode_jwt_segment "$token_header")"; then
        fail "$description returned an undecodable JWT header"
    fi
    if ! jq -e '.alg == "RS256" and .kid == "auth-key-1"' <<<"$header_json" >/dev/null; then
        fail "$description was not an RS256 JWT with key id auth-key-1"
    fi
}

tamper_token() {
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
        *)
            printf '[FAIL] Unknown database service: %s\n' "$service" >&2
            return 1
            ;;
    esac

    compose exec -T "$service" sh -c \
        'mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" -D "$1" -N -B -e "$2"' \
        sh "$database" "$sql"
}

kafka_topic_messages() {
    compose exec -T kafka sh -ec '
        /opt/kafka/bin/kafka-console-consumer.sh \
            --bootstrap-server localhost:9092 \
            --topic banking.money-movements \
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

kafka_message_matches() {
    local message="$1"
    local event_type="$2"
    local user_id="$3"
    local account_number="$4"
    local amount="$5"
    local result="$6"
    local counterparty="$7"

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
    local counterparty="$7"
    local description="$8"
    local line
    local value

    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        value="${line#*|}"
        if kafka_message_matches "$value" "$event_type" "$user_id" "$account_number" "$amount" "$result" "$counterparty"; then
            return
        fi
    done <<<"$messages"

    fail "$description"
}

assert_kafka_event_absent() {
    local messages="$1"
    local event_type="$2"
    local user_id="$3"
    local account_number="$4"
    local amount="$5"
    local result="$6"
    local counterparty="$7"
    local description="$8"
    local line
    local value

    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        value="${line#*|}"
        if kafka_message_matches "$value" "$event_type" "$user_id" "$account_number" "$amount" "$result" "$counterparty"; then
            fail "$description"
        fi
    done <<<"$messages"
}

assert_db_scalar() {
    local service="$1"
    local sql="$2"
    local expected="$3"
    local description="$4"
    local actual

    if ! actual="$(db_query "$service" "$sql")"; then
        fail "$description: database query failed"
    fi
    [[ "$actual" == "$expected" ]] ||
        fail "$description: expected $expected, got $actual"
}

verify_auth_and_jwks() {
    local token
    local jwks

    RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$"
    USERNAME="verify-${RUN_ID}"
    EMAIL="${USERNAME}@example.com"
    PASSWORD='Password123!'
    REGISTER_BODY="$(
        jq -cn \
            --arg username "$USERNAME" \
            --arg email "$EMAIL" \
            --arg password "$PASSWORD" \
            '{username: $username, email: $email, password: $password}'
    )"
    LOGIN_BODY="$(
        jq -cn \
            --arg username "$USERNAME" \
            --arg password "$PASSWORD" \
            '{username: $username, password: $password}'
    )"

    BASE_URL="$AUTH_URL"
    request GET '/.well-known/jwks.json'
    expect_status 200 'JWKS endpoint'
    jwks="$HTTP_BODY"
    if ! jq -e \
        '.keys | type == "array" and length > 0 and
         all(.[]; .kty == "RSA" and .use == "sig" and .alg == "RS256" and
             (.kid | type == "string") and (.n | type == "string") and
             (.e | type == "string"))' <<<"$jwks" >/dev/null; then
        fail 'JWKS response did not contain a valid RSA RS256 public key'
    fi
    pass 'Auth service exposes a valid RS256 JWKS'

    request POST /api/auth/register '' "$REGISTER_BODY"
    expect_status 201 'User registration'
    assert_json \
        '.username == $username and .tokenType == "Bearer" and
         (.expiresInMs | tonumber) > 0 and (.token | type) == "string"' \
        'Registration response was missing authentication fields' \
        --arg username "$USERNAME"
    token="$(jq -er '.token' <<<"$HTTP_BODY")"
    assert_rs256_token "$token" 'Registration response'
    pass 'User registration returns an RS256 JWT'

    request POST /api/auth/login '' "$LOGIN_BODY"
    expect_status 200 'User login'
    assert_json \
        '.username == $username and .tokenType == "Bearer" and
         (.token | type) == "string"' \
        'Login response was missing authentication fields' \
        --arg username "$USERNAME"
    TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
    assert_rs256_token "$TOKEN" 'Login response'
    IFS='.' read -r _ TOKEN_PAYLOAD _ <<<"$TOKEN"
    TOKEN_PAYLOAD="$(decode_jwt_segment "$TOKEN_PAYLOAD")"
    USER_ID="$(jq -er '.sub' <<<"$TOKEN_PAYLOAD")"
    pass 'User login returns an RS256 JWT'
}

verify_banking_api() {
    local first_account
    local second_account
    local tampered
    local v1_accounts
    local v2_accounts
    local v1_history
    local v2_history
    local deposit_body='{"amount":50.00}'
    local withdrawal_body='{"amount":5.00}'
    local transfer_body
    local deposit_response
    local withdrawal_response
    local transfer_response
    local retry

    BASE_URL="$BANKING_URL"

    request GET /api/v1/accounts
    expect_status_any 'Unauthenticated account list' 401 403
    pass 'Banking account endpoints require authentication'

    tampered="$(tamper_token "$TOKEN")"
    request GET /api/v1/accounts "$tampered"
    expect_status 401 'Tampered JWT'
    pass 'Tampering with one JWT byte returns HTTP 401'

    request GET /api/v1/accounts "$TOKEN"
    expect_status 200 'Initial v1 account list'
    assert_json 'type == "array" and length == 0' 'Initial v1 account list was not empty'

    request POST /api/v1/accounts "$TOKEN" '{}'
    expect_status 200 'Create v1 account'
    first_account="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
    [[ "$first_account" =~ ^[0-9]{12}$ ]] ||
        fail "v1 account number was not a 12-digit value"

    request POST /api/v2/accounts "$TOKEN" '{}'
    expect_status 200 'Create v2 account'
    second_account="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
    [[ "$second_account" =~ ^[0-9]{12}$ ]] ||
        fail "v2 account number was not a 12-digit value"
    [[ "$first_account" != "$second_account" ]] ||
        fail 'The two account creation calls returned the same account'
    pass 'Authenticated v1 and v2 account creation works'

    request GET /api/v1/accounts "$TOKEN"
    expect_status 200 'v1 account list'
    assert_json \
        'length == 2 and ([.[].accountNumber] | sort) == ([$first, $second] | sort)' \
        'v1 account list did not contain both accounts' \
        --arg first "$first_account" \
        --arg second "$second_account"
    v1_accounts="$(canonical_json "$HTTP_BODY")"

    request GET /api/v2/accounts "$TOKEN"
    expect_status 200 'v2 account list'
    assert_json \
        'length == 2 and ([.[].accountNumber] | sort) == ([$first, $second] | sort)' \
        'v2 account list did not contain both accounts' \
        --arg first "$first_account" \
        --arg second "$second_account"
    v2_accounts="$(canonical_json "$HTTP_BODY")"
    [[ "$v1_accounts" == "$v2_accounts" ]] ||
        fail 'v1 and v2 account-list response bodies differ'
    pass 'Authenticated v1 and v2 account listing is consistent'

    request GET "/api/v1/accounts/$first_account" "$TOKEN"
    expect_status 200 'v1 account details'
    assert_json '.accountNumber == $account' 'v1 account details returned the wrong account' \
        --arg account "$first_account"

    request GET "/api/v2/accounts/$first_account" "$TOKEN"
    expect_status 200 'v2 account details'
    assert_json '.accountNumber == $account' 'v2 account details returned the wrong account' \
        --arg account "$first_account"
    pass 'Authenticated v1 and v2 account details work'

    request POST "/api/v1/accounts/$first_account/deposits" "$TOKEN" '{"amount":100.00}'
    expect_status 200 'v1 deposit'
    assert_balance 100.00 'v1 deposit returned the wrong balance'

    request POST "/api/v1/accounts/$first_account/withdrawals" "$TOKEN" '{"amount":10.00}'
    expect_status 200 'v1 withdrawal'
    assert_balance 90.00 'v1 withdrawal returned the wrong balance'

    request POST "/api/v1/accounts/$first_account/transfers" "$TOKEN" \
        "{\"amount\":15.00,\"toAccountNumber\":\"$second_account\",\"description\":\"v1 transfer\"}"
    expect_status 200 'v1 transfer'
    assert_balance 75.00 'v1 transfer returned the wrong balance'
    pass 'Authenticated v1 deposit, withdrawal, and transfer work'

    request POST "/api/v2/accounts/$first_account/deposits" "$TOKEN" "$deposit_body"
    expect_status 400 'v2 deposit without an Idempotency-Key'
    pass 'v2 write endpoints require an Idempotency-Key'

    request POST "/api/v2/accounts/$first_account/deposits" "$TOKEN" "$deposit_body" \
        'Idempotency-Key: verify-deposit'
    expect_status 200 'v2 idempotent deposit'
    assert_balance 125.00 'v2 deposit returned the wrong balance'
    deposit_response="$(canonical_json "$HTTP_BODY")"

    for retry in 1 2 3; do
        request POST "/api/v2/accounts/$first_account/deposits" "$TOKEN" "$deposit_body" \
            'Idempotency-Key: verify-deposit'
        expect_status 200 "v2 deposit replay $retry"
        [[ "$(canonical_json "$HTTP_BODY")" == "$deposit_response" ]] ||
            fail "v2 deposit replay $retry returned a different response"
    done

    request POST "/api/v2/accounts/$first_account/deposits" "$TOKEN" '{"amount":51.00}' \
        'Idempotency-Key: verify-deposit'
    expect_status 409 'Idempotency key reused with a different body'
    pass 'Deposit idempotency replays the same response and rejects a different body'

    request POST "/api/v2/accounts/$first_account/withdrawals" "$TOKEN" "$withdrawal_body" \
        'Idempotency-Key: verify-withdrawal'
    expect_status 200 'v2 idempotent withdrawal'
    assert_balance 120.00 'v2 withdrawal returned the wrong balance'
    withdrawal_response="$(canonical_json "$HTTP_BODY")"

    request POST "/api/v2/accounts/$first_account/withdrawals" "$TOKEN" "$withdrawal_body" \
        'Idempotency-Key: verify-withdrawal'
    expect_status 200 'v2 withdrawal replay'
    [[ "$(canonical_json "$HTTP_BODY")" == "$withdrawal_response" ]] ||
        fail 'v2 withdrawal replay returned a different response'

    transfer_body="{\"amount\":20.00,\"toAccountNumber\":\"$second_account\",\"description\":\"v2 transfer\"}"
    request POST "/api/v2/accounts/$first_account/transfers" "$TOKEN" "$transfer_body" \
        'Idempotency-Key: verify-transfer'
    expect_status 200 'v2 idempotent transfer'
    assert_balance 100.00 'v2 transfer returned the wrong balance'
    transfer_response="$(canonical_json "$HTTP_BODY")"

    request POST "/api/v2/accounts/$first_account/transfers" "$TOKEN" "$transfer_body" \
        'Idempotency-Key: verify-transfer'
    expect_status 200 'v2 transfer replay'
    [[ "$(canonical_json "$HTTP_BODY")" == "$transfer_response" ]] ||
        fail 'v2 transfer replay returned a different response'
    pass 'Authenticated v2 deposit, withdrawal, transfer, and idempotency work'

    request GET "/api/v2/accounts/$second_account" "$TOKEN"
    expect_status 200 'Destination account details'
    assert_balance 35.00 'Destination account did not receive both transfers'

    request GET "/api/v1/accounts/$first_account/transactions" "$TOKEN"
    expect_status 200 'v1 transaction history'
    assert_json \
        'length == 6 and
         (map(select(.type == "DEPOSIT" and .amount == 100)) | length) == 1 and
         (map(select(.type == "WITHDRAWAL" and .amount == 10)) | length) == 1 and
         (map(select(.type == "DEPOSIT" and .amount == 50)) | length) == 1 and
         (map(select(.type == "WITHDRAWAL" and .amount == 5)) | length) == 1 and
         (map(select(.type == "TRANSFER" and .amount == 15)) | length) == 1 and
         (map(select(.type == "TRANSFER" and .amount == 20)) | length) == 1' \
        'v1 transaction history did not contain exactly six real operations'
    v1_history="$(canonical_json "$HTTP_BODY")"

    request GET "/api/v2/accounts/$first_account/transactions" "$TOKEN"
    expect_status 200 'v2 transaction history'
    v2_history="$(canonical_json "$HTTP_BODY")"
    [[ "$v1_history" == "$v2_history" ]] ||
        fail 'v1 and v2 transaction-history response bodies differ'
    pass 'Authenticated v1 and v2 transaction history is consistent'

    FIRST_ACCOUNT="$first_account"
    SECOND_ACCOUNT="$second_account"
}

verify_kafka_and_notifications() {
    local kafka_messages
    local notification_logs
    local declined_transfer_amount='999999.99'

    request POST "/api/v2/accounts/$FIRST_ACCOUNT/transfers" "$TOKEN" \
        "{\"amount\":$declined_transfer_amount,\"toAccountNumber\":\"$SECOND_ACCOUNT\",\"description\":\"declined transfer\"}" \
        'Idempotency-Key: verify-declined-transfer'
    expect_status 422 'v2 declined transfer'

    request GET "/api/v2/accounts/$FIRST_ACCOUNT" "$TOKEN"
    expect_status 200 'Source account after declined transfer'
    assert_balance 100.00 'Declined transfer changed the source balance'

    kafka_messages="$(kafka_topic_messages)"
    notification_logs="$(compose logs --no-color --no-log-prefix notification-service)"

    assert_kafka_event_present \
        "$kafka_messages" \
        'DEPOSIT' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '100.00' \
        'SUCCESS' \
        '' \
        'Kafka topic did not contain the successful v1 deposit event'
    assert_kafka_event_present \
        "$kafka_messages" \
        'WITHDRAWAL' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '10.00' \
        'SUCCESS' \
        '' \
        'Kafka topic did not contain the successful v1 withdrawal event'
    assert_kafka_event_present \
        "$kafka_messages" \
        'TRANSFER' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '15.00' \
        'SUCCESS' \
        "$SECOND_ACCOUNT" \
        'Kafka topic did not contain the successful v1 transfer event'
    assert_kafka_event_present \
        "$kafka_messages" \
        'DEPOSIT' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '50.00' \
        'SUCCESS' \
        '' \
        'Kafka topic did not contain the successful v2 deposit event'
    assert_kafka_event_present \
        "$kafka_messages" \
        'WITHDRAWAL' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '5.00' \
        'SUCCESS' \
        '' \
        'Kafka topic did not contain the successful v2 withdrawal event'
    assert_kafka_event_present \
        "$kafka_messages" \
        'TRANSFER' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        '20.00' \
        'SUCCESS' \
        "$SECOND_ACCOUNT" \
        'Kafka topic did not contain the successful v2 transfer event'

    assert_kafka_event_absent \
        "$kafka_messages" \
        'TRANSFER' \
        "$USER_ID" \
        "$FIRST_ACCOUNT" \
        "$declined_transfer_amount" \
        'DECLINED' \
        "$SECOND_ACCOUNT" \
        'Kafka topic unexpectedly contained the declined transfer event'

    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'DEPOSIT' AND amount = 100.00" \
        1 \
        'Notification log missing successful v1 deposit'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'WITHDRAWAL' AND amount = 10.00" \
        1 \
        'Notification log missing successful v1 withdrawal'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'TRANSFER' AND amount = 15.00" \
        1 \
        'Notification log missing successful v1 transfer'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'DEPOSIT' AND amount = 50.00" \
        1 \
        'Notification log missing successful v2 deposit'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'WITHDRAWAL' AND amount = 5.00" \
        1 \
        'Notification log missing successful v2 withdrawal'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'TRANSFER' AND amount = 20.00" \
        1 \
        'Notification log missing successful v2 transfer'
    assert_db_scalar \
        notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'TRANSFER' AND amount = $declined_transfer_amount" \
        0 \
        'Notification log unexpectedly recorded the declined transfer'

    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=100.00 eventType=DEPOSIT"* ]] ||
        fail 'notification-service did not log the successful v1 deposit'
    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=10.00 eventType=WITHDRAWAL"* ]] ||
        fail 'notification-service did not log the successful v1 withdrawal'
    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=15.00 eventType=TRANSFER"* ]] ||
        fail 'notification-service did not log the successful v1 transfer'
    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=50.00 eventType=DEPOSIT"* ]] ||
        fail 'notification-service did not log the successful v2 deposit'
    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=5.00 eventType=WITHDRAWAL"* ]] ||
        fail 'notification-service did not log the successful v2 withdrawal'
    [[ "$notification_logs" == *"NOTIFICATION: user=$USER_ID amount=20.00 eventType=TRANSFER"* ]] ||
        fail 'notification-service did not log the successful v2 transfer'
    [[ "$notification_logs" != *"amount=$declined_transfer_amount"* ]] ||
        fail 'notification-service logged the declined transfer'

    pass 'Kafka topic and notification-service logs reflect successful money-movement events'
}

verify_schema_split() {
    local adminer_status

    adminer_status="$(http_status "$ADMINER_URL/")"
    [[ "$adminer_status" == 200 ]] ||
        fail "Adminer did not respond with HTTP 200 (got $adminer_status)"

    assert_db_scalar \
        auth-db \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'authdb' AND table_name = 'users'" \
        1 \
        'auth-db.users table'
    assert_db_scalar \
        banking-db \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'bankdb' AND table_name = 'accounts'" \
        1 \
        'banking-db.accounts table'
    assert_db_scalar \
        auth-db \
        "SELECT COUNT(*) FROM authdb.users WHERE username = '$USERNAME'" \
        1 \
        'Registered user persisted in auth-db.users'
    assert_db_scalar \
        banking-db \
        "SELECT COUNT(*) FROM bankdb.accounts WHERE account_number IN ('$FIRST_ACCOUNT', '$SECOND_ACCOUNT')" \
        2 \
        'Created accounts persisted in banking-db.accounts'
    assert_db_scalar \
        banking-db \
        "SELECT COUNT(*) FROM bankdb.bank_transactions t JOIN bankdb.accounts a ON a.id = t.from_account_id WHERE a.account_number = '$FIRST_ACCOUNT'" \
        6 \
        'Idempotent requests created exactly six source transactions'
    assert_db_scalar \
        banking-db \
        "SELECT COUNT(*) FROM bankdb.idempotency_records WHERE user_id = (SELECT owner_id FROM bankdb.accounts WHERE account_number = '$FIRST_ACCOUNT')" \
        3 \
        'Exactly three v2 idempotency records were persisted'
    pass 'Adminer is reachable and the auth/banking schemas are split'
}

verify_persistence() {
    local persisted_token

    printf '[INFO] Restarting Compose without removing volumes to verify persistence\n'
    compose down --remove-orphans
    compose up --detach
    wait_for_stack
    wait_for_kafka_broker
    wait_for_kafka_topic
    wait_for_kafka_group_coordination

    BASE_URL="$AUTH_URL"
    request POST /api/auth/login '' "$LOGIN_BODY"
    expect_status 200 'Login after a non-destructive restart'
    persisted_token="$(jq -er '.token' <<<"$HTTP_BODY")"

    BASE_URL="$BANKING_URL"
    request GET "/api/v2/accounts/$FIRST_ACCOUNT" "$persisted_token"
    expect_status 200 'Read account after a non-destructive restart'
    assert_balance 100.00 'Account balance did not persist after a non-destructive restart'

    request GET /api/v2/accounts "$persisted_token"
    expect_status 200 'List accounts after a non-destructive restart'
    assert_json \
        'length == 2 and any(.[]; .accountNumber == $first) and
         any(.[]; .accountNumber == $second)' \
        'Accounts did not persist after a non-destructive restart' \
        --arg first "$FIRST_ACCOUNT" \
        --arg second "$SECOND_ACCOUNT"
    pass 'Users, accounts, balances, and authentication persist across restart'
}

require_commands
check_layout

if ((FRESH_START)); then
    printf '[INFO] Removing Compose volumes for a clean Flyway start\n'
    compose down --volumes --remove-orphans
fi

printf '[INFO] Building and starting the Compose stack\n'
compose up --build --detach
wait_for_stack
wait_for_kafka_broker
wait_for_kafka_topic
wait_for_kafka_group_coordination

verify_auth_and_jwks
verify_banking_api
verify_kafka_and_notifications
verify_schema_split
verify_persistence

printf 'All Compose, authentication, API, idempotency, schema, and persistence checks passed.\n'
