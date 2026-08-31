#!/usr/bin/env bash
# Test framework core library
# Provides structured test execution, result tracking, and reporting

set -Eeuo pipefail

# Test registry and results
declare -g -A TEST_REGISTRY=()        # name -> function
declare -g -a TEST_ORDER=()           # registration order for stateful suites
declare -g -a TEST_RESULTS=()         # array of result objects
declare -g CURRENT_SUITE=""
declare -g CURRENT_TEST=""
declare -g TEST_START_TIME=0
declare -g TEST_RESULT_DIR="/tmp"
declare -g TEST_OUTPUT_FORMAT="text"  # text, json, junitxml
declare -g TESTS_PASSED=0
declare -g TESTS_FAILED=0
declare -g TESTS_SKIPPED=0

# Initialize test framework
test_framework_init() {
    TEST_RESULT_DIR="${1:-.test-results}"
    mkdir -p "$TEST_RESULT_DIR"
    TEST_OUTPUT_FORMAT="${OUTPUT_FORMAT:-text}"
    
    printf '[TEST] Initialized test framework (format: %s)\n' "$TEST_OUTPUT_FORMAT" >&2
}

# Register a test function
register_test() {
    local suite="$1"
    local name="$2"
    local fn="$3"
    local key="${suite}::${name}"
    
    if [[ -z "${TEST_REGISTRY[$key]+x}" ]]; then
        TEST_ORDER+=("$key")
    fi
    TEST_REGISTRY["$key"]="$fn"
}

# Get all registered tests
list_tests() {
    local suite="${1-}"
    
    if [[ -z "$suite" ]]; then
        for key in "${TEST_ORDER[@]}"; do
            printf '%s\n' "$key"
        done
    else
        for key in "${TEST_ORDER[@]}"; do
            if [[ "$key" == "${suite}::"* ]]; then
                printf '%s\n' "${key#*::}"
            fi
        done
    fi
}

# Run a single test
run_test() {
    local suite="$1"
    local name="$2"
    local key="${suite}::${name}"
    
    [[ -n "${TEST_REGISTRY[$key]-}" ]] || {
        printf '[ERROR] Test not registered: %s\n' "$key" >&2
        return 1
    }
    
    CURRENT_SUITE="$suite"
    CURRENT_TEST="$name"
    TEST_START_TIME=$SECONDS
    
    local fn="${TEST_REGISTRY[$key]}"
    local exit_code=0
    
    if $fn; then
        # Don't count as passed if it was actually skipped
        if [[ "${TESTS_SKIPPED_LAST-0}" == "1" ]]; then
            TESTS_SKIPPED_LAST=0
        else
            test_pass "$name"
            ((++TESTS_PASSED))
        fi
    else
        exit_code=$?
        test_fail "$name" "Test function returned exit code $exit_code"
        ((++TESTS_FAILED))
    fi
    
    CURRENT_TEST=""
}

# Run all tests matching a filter
run_tests() {
    local suite_filter="${1-}"
    local test_filter="${2-}"
    
    for key in $(list_tests "$suite_filter"); do
        local full_key
        if [[ -z "$suite_filter" ]]; then
            full_key="$key"
        else
            full_key="${suite_filter}::${key}"
        fi
        
        local suite="${full_key%%::*}"
        local test_name="${full_key##*::}"
        
        if [[ -z "$test_filter" ]] || [[ "$test_name" == *"$test_filter"* ]]; then
            run_test "$suite" "$test_name" || true
        fi
    done
}

# Assert HTTP status code
assert_http_status() {
    local expected="$1"
    local description="${2-}"
    
    [[ "$HTTP_STATUS" == "$expected" ]] || {
        test_fail "HTTP status: $description" "Expected $expected, got $HTTP_STATUS"
        return 1
    }
}

# Assert HTTP status is one of several values
assert_http_status_any() {
    local description="$1"
    shift
    local expected
    
    for expected in "$@"; do
        [[ "$HTTP_STATUS" == "$expected" ]] && return 0
    done
    
    test_fail "HTTP status: $description" "Expected one of: $*, got $HTTP_STATUS"
    return 1
}

# Assert JSON field matches condition
assert_json_matches() {
    local filter="$1"
    local description="${2-}"
    shift 2
    
    if ! jq -e "$filter" "$@" <<<"$HTTP_BODY" >/dev/null 2>&1; then
        test_fail "JSON assertion: $description" "Filter '$filter' did not match response"
        return 1
    fi
}

# Assert database scalar value
assert_db_value() {
    local service="$1"
    local sql="$2"
    local expected="$3"
    local description="${4-}"
    
    local actual
    if ! actual="$(db_query "$service" "$sql")"; then
        test_fail "Database query: $description" "Query failed: $sql"
        return 1
    fi
    
    [[ "$actual" == "$expected" ]] || {
        test_fail "Database value: $description" "Expected '$expected', got '$actual'"
        return 1
    }
}

# Skip a test
skip_test() {
    local reason="${1-No reason provided}"
    test_skip "$reason"
    export TESTS_SKIPPED_LAST=1
    return 0
}

# Record test result
test_pass() {
    local name="$1"
    local elapsed=$((SECONDS - TEST_START_TIME))
    
    printf '[PASS] %s::%s (%ds)\n' "$CURRENT_SUITE" "$name" "$elapsed"
    
    TEST_RESULTS+=("{\"status\":\"pass\",\"suite\":\"$CURRENT_SUITE\",\"name\":\"$name\",\"elapsed\":$elapsed}")
}

test_fail() {
    local name="$1"
    local reason="$2"
    local elapsed=$((SECONDS - TEST_START_TIME))
    
    printf '[FAIL] %s::%s (%ds): %s\n' "$CURRENT_SUITE" "$name" "$elapsed" "$reason" >&2
    
    # Escape reason for JSON
    local escaped_reason
    escaped_reason=$(printf '%s' "$reason" | sed 's/"/\\"/g')
    TEST_RESULTS+=("{\"status\":\"fail\",\"suite\":\"$CURRENT_SUITE\",\"name\":\"$name\",\"elapsed\":$elapsed,\"reason\":\"$escaped_reason\"}")
}

test_skip() {
    local reason="$1"
    
    printf '[SKIP] %s::%s: %s\n' "$CURRENT_SUITE" "$CURRENT_TEST" "$reason"
    
    ((++TESTS_SKIPPED))
    TEST_RESULTS+=("{\"status\":\"skip\",\"suite\":\"$CURRENT_SUITE\",\"name\":\"$CURRENT_TEST\",\"reason\":\"$reason\"}")
}

# Print test summary
print_test_summary() {
    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    
    printf '\n========================================\n'
    printf 'Test Summary\n'
    printf '========================================\n'
    printf 'Total:   %d\n' "$total"
    printf 'Passed:  %d\n' "$TESTS_PASSED"
    printf 'Failed:  %d\n' "$TESTS_FAILED"
    printf 'Skipped: %d\n' "$TESTS_SKIPPED"
    printf '========================================\n'
    
    if ((TESTS_FAILED > 0)); then
        return 1
    fi
}

# Export results in JSON format
export_results_json() {
    local output_file="$1"
    
    {
        printf '{\n'
        printf '  "framework": "bash-test-framework",\n'
        printf '  "timestamp": "%s",\n' "$(date -Iseconds)"
        printf '  "summary": {\n'
        printf '    "total": %d,\n' "$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"
        printf '    "passed": %d,\n' "$TESTS_PASSED"
        printf '    "failed": %d,\n' "$TESTS_FAILED"
        printf '    "skipped": %d\n' "$TESTS_SKIPPED"
        printf '  },\n'
        printf '  "results": [\n'
        
        local first=1
        for result in "${TEST_RESULTS[@]}"; do
            if ((first)); then
                first=0
            else
                printf ',\n'
            fi
            printf '    %s' "$result"
        done
        
        printf '\n  ]\n'
        printf '}\n'
    } > "$output_file"
    
    printf '[TEST] Results exported to %s\n' "$output_file" >&2
}

# Export results in JUnit XML format (for CI/CD integration)
export_results_junit() {
    local output_file="$1"
    
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites>\n'
        printf '  <testsuite name="verify-compose" tests="%d" failures="%d" skipped="%d" time="0">\n' \
            "$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))" "$TESTS_FAILED" "$TESTS_SKIPPED"
        
        for result in "${TEST_RESULTS[@]}"; do
            local status elapsed suite name reason
            status=$(jq -r '.status' <<<"$result")
            suite=$(jq -r '.suite' <<<"$result")
            name=$(jq -r '.name' <<<"$result")
            reason=$(jq -r '.reason // ""' <<<"$result")
            elapsed=$(jq -r '.elapsed // 0' <<<"$result")
            
            printf '    <testcase classname="%s" name="%s" time="%d">\n' "$suite" "$name" "$elapsed"
            
            case "$status" in
                fail)
                    printf '      <failure message="%s"></failure>\n' "$(printf '%s' "$reason" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
                    ;;
                skip)
                    printf '      <skipped message="%s"></skipped>\n' "$(printf '%s' "$reason" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
                    ;;
            esac
            
            printf '    </testcase>\n'
        done
        
        printf '  </testsuite>\n'
        printf '</testsuites>\n'
    } > "$output_file"
    
    printf '[TEST] JUnit XML exported to %s\n' "$output_file" >&2
}

# Retry a command with backoff
retry_with_backoff() {
    local max_attempts="${1:-3}"
    local initial_delay="${2:-1}"
    local cmd=("${@:3}")
    
    local attempt=0
    local delay="$initial_delay"
    
    while ((attempt < max_attempts)); do
        if "${cmd[@]}"; then
            return 0
        fi
        
        ((++attempt))
        if ((attempt < max_attempts)); then
            printf '[RETRY] Attempt %d/%d failed, waiting %ds before retry\n' "$attempt" "$max_attempts" "$delay" >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    
    printf '[ERROR] Command failed after %d attempts\n' "$max_attempts" >&2
    return 1
}

# Export all framework functions for sourcing
export -f test_framework_init register_test list_tests run_test run_tests
export -f assert_http_status assert_http_status_any assert_json_matches assert_db_value
export -f skip_test test_pass test_fail test_skip
export -f print_test_summary export_results_json export_results_junit
export -f retry_with_backoff
