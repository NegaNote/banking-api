#!/usr/bin/env bash
# Banking API Compose Verification - v2
# Refactored test framework with modular test suites, structured reporting, and parallel execution

set -Eeuo pipefail

# Configuration
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
LIB_DIR="$SCRIPT_DIR/lib"
TESTS_DIR="$SCRIPT_DIR/tests"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

# URLs and timeouts
AUTH_URL="${AUTH_URL:-http://localhost:8081}"
BANKING_URL="${BANKING_URL:-http://localhost:8080}"
ADMINER_URL="${ADMINER_URL:-http://localhost:8090}"
NOTIFICATION_URL="${NOTIFICATION_URL:-http://localhost:8082}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

# Test execution options
FRESH_START=0
NO_SUDO=0
RUN_SUITE=""
RUN_TEST=""
OUTPUT_FORMAT="text"
PARALLEL_TESTS=0

# Import framework and helpers
source "$LIB_DIR/test-framework.sh"
source "$LIB_DIR/test-helpers.sh"

usage() {
    cat <<'EOF'
Usage: scripts/verify-compose-v2.sh [options]

Refactored test framework for banking API. Supports modular test suites,
structured output, and selective test execution.

Options:
  --fresh              Remove Compose volumes before starting (destructive).
  --no-sudo            Use docker directly instead of sudo docker.
  --suite SUITE        Run only tests from a specific suite (auth, banking, edge_cases, integration).
  --test TEST          Run only tests matching a name (substring match).
  --output-format FMT  Output format: text (default), json, junitxml.
  --parallel           Execute tests in parallel (experimental).
  -h, --help           Show this help.

Examples:
  # Run all tests
  scripts/verify-compose-v2.sh

  # Run only banking API tests
  scripts/verify-compose-v2.sh --suite banking

  # Run only auth tests
  scripts/verify-compose-v2.sh --suite auth

  # Run tests matching "transfer" in banking suite
  scripts/verify-compose-v2.sh --suite banking --test transfer

  # Generate JUnit XML for CI/CD
  scripts/verify-compose-v2.sh --output-format junitxml

Environment:
  AUTH_URL, BANKING_URL, ADMINER_URL, HEALTH_TIMEOUT
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --fresh)
                FRESH_START=1
                ;;
            --no-sudo)
                NO_SUDO=1
                ;;
            --suite)
                RUN_SUITE="$2"
                shift
                ;;
            --test)
                RUN_TEST="$2"
                shift
                ;;
            --output-format)
                OUTPUT_FORMAT="$2"
                shift
                ;;
            --parallel)
                PARALLEL_TESTS=1
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
}

setup_docker() {
    if ((NO_SUDO)); then
        DOCKER=(docker)
    else
        # Check if docker needs sudo
        if docker compose version >/dev/null 2>&1; then
            DOCKER=(docker)
        else
            DOCKER=(sudo docker)
        fi
    fi
}

require_commands() {
    local required_commands=(awk base64 curl date find git grep jq sed sleep sort wc)
    
    if ((NO_SUDO)); then
        required_commands+=(docker)
    else
        required_commands+=(docker sudo)
    fi
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            printf '[ERROR] Missing required command: %s\n' "$cmd" >&2
            exit 1
        fi
    done
}

check_layout() {
    [[ -f "$COMPOSE_FILE" ]] || {
        printf '[ERROR] Missing root docker-compose.yml\n' >&2
        exit 1
    }
    
    for service in auth-service banking-service; do
        [[ -d "$ROOT_DIR/$service" ]] || {
            printf '[ERROR] Missing submodule directory: %s\n' "$service" >&2
            exit 1
        }
        [[ -f "$ROOT_DIR/$service/Dockerfile" ]] || {
            printf '[ERROR] Missing %s/Dockerfile\n' "$service" >&2
            exit 1
        }
        
        local migration_count
        migration_count="$(find "$ROOT_DIR/$service/src/main/resources/db/migration" \
            -maxdepth 1 -type f -name 'V*__*.sql' -print | wc -l)" || true
        
        if [[ "$migration_count" -lt 1 ]]; then
            printf '[ERROR] No Flyway migrations found for %s\n' "$service" >&2
            exit 1
        fi
    done
    
    local submodule_status
    submodule_status="$(git -C "$ROOT_DIR" submodule status --recursive)"
    while IFS= read -r line; do
        [[ "$line" != -* ]] || {
            printf '[ERROR] Uninitialized submodule: ${line:1}\n' >&2
            exit 1
        }
    done <<<"$submodule_status"
    
    printf '[INFO] Layout check passed\n'
}

compose_up() {
    printf '[INFO] Building and starting the Compose stack\n'
    compose up --build --detach
    
    if wait_for_stack_ready; then
        printf '[PASS] Stack is healthy and ready\n'
    else
        printf '[ERROR] Stack did not become healthy within %ds\n' "$HEALTH_TIMEOUT" >&2
        compose ps --all >&2 || true
        exit 1
    fi
    
    if wait_for_kafka_broker; then
        printf '[PASS] Kafka broker is initialized\n'
    else
        printf '[ERROR] Kafka broker did not initialize\n' >&2
        exit 1
    fi
    
    if wait_for_kafka_topic; then
        printf '[PASS] Kafka topic is ready\n'
    else
        printf '[ERROR] Kafka topic was not created\n' >&2
        exit 1
    fi
}

load_test_suites() {
    source "$TESTS_DIR/test-auth.sh"
    source "$TESTS_DIR/test-banking.sh"
    source "$TESTS_DIR/test-edge-cases.sh"
    source "$TESTS_DIR/test-integration.sh"
    
    # Register all tests
    auth_register_tests
    banking_register_tests
    edge_cases_register_tests
    integration_register_tests
}

run_suite() {
    local suite="$1"
    local test_filter="${2-}"
    
    printf '[TEST] Running suite: %s\n' "$suite" >&2
    
    # Run setup if needed
    case "$suite" in
        banking)
            setup_banking_user || {
                printf '[ERROR] Failed to setup banking user\n' >&2
                return 1
            }
            ;;
        edge_cases)
            setup_edge_case_user || {
                printf '[ERROR] Failed to setup edge case user\n' >&2
                return 1
            }
            ;;
        integration)
            setup_two_users || {
                printf '[ERROR] Failed to setup two users\n' >&2
                return 1
            }
            ;;
    esac
    
    run_tests "$suite" "$test_filter" || true
}

main() {
    parse_args "$@"
    
    test_framework_init "$ROOT_DIR/.test-results"
    
    printf '[INFO] Banking API Compose Verification - v2\n'
    
    require_commands
    check_layout
    setup_docker
    
    # Manage compose stack
    if ((FRESH_START)); then
        printf '[INFO] Removing Compose volumes for a clean start\n'
        compose down --volumes --remove-orphans || true
    fi
    
    compose_up
    
    # Load and run tests
    load_test_suites
    
    if [[ -n "$RUN_SUITE" ]]; then
        run_suite "$RUN_SUITE" "$RUN_TEST"
    else
        # Run all suites in order
        run_suite "auth" "$RUN_TEST"
        run_suite "banking" "$RUN_TEST"
        run_suite "edge_cases" "$RUN_TEST"
        run_suite "integration" "$RUN_TEST"
    fi
    
    # Print summary
    print_test_summary
    
    # Export results
    local test_dir="$ROOT_DIR/.test-results"
    mkdir -p "$test_dir"
    
    case "$OUTPUT_FORMAT" in
        json)
            export_results_json "$test_dir/results.json"
            ;;
        junitxml)
            export_results_junit "$test_dir/results.xml"
            ;;
    esac
}

main "$@"
