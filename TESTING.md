# Banking API Test Framework v2 - Architecture & Migration Guide

## Overview

The refactored test framework addresses critical gaps in test coverage and maintainability by:

1. **Modular Architecture**: Breaking down the monolithic 1000-line script into:
   - `lib/test-framework.sh` - Core test harness
   - `lib/test-helpers.sh` - HTTP, DB, Kafka utilities
   - `tests/test-auth.sh` - Authentication & JWT tests
   - `tests/test-edge-cases.sh` - Validation & boundary tests
   - `tests/test-integration.sh` - Authorization & concurrent request tests
   - `scripts/verify-compose-v2.sh` - Main test runner

2. **Enhanced Coverage**: Adding 40+ new test cases for:
   - Cross-user authorization (security)
   - Negative/zero amount validation
   - Concurrent request handling
   - Malformed input handling
   - SQL injection prevention
   - JWT edge cases
   - Oversized input handling

3. **Structured Output**: Support for:
   - JSON results for CI/CD parsing
   - JUnit XML for GitHub Actions, Jenkins integration
   - Test discovery and selective execution
   - Timing information and result tracking

4. **Better Error Reporting**: 
   - Centralized error handling with context
   - Response redaction (no token leaks in logs)
   - HTTP interaction logging
   - Clear failure reasons

## Directory Structure

```
scripts/
├── lib/
│   ├── test-framework.sh    # Core framework (test registry, assertions, reporting)
│   └── test-helpers.sh      # Common utilities (HTTP, DB, Kafka, JWT)
├── tests/
│   ├── test-auth.sh         # Authentication tests (21 tests)
│   ├── test-edge-cases.sh   # Validation & boundary tests (19 tests)
│   └── test-integration.sh  # Authorization & concurrency tests (12 tests)
├── verify-compose.sh        # Original script (preserved)
└── verify-compose-v2.sh     # New refactored runner
```

## Test Suites

### 1. Authentication Tests (`test-auth.sh`)

**Coverage:**
- JWKS endpoint validation
- User registration (success, invalid email, weak password, duplicate username)
- User login (success, invalid password, non-existent user)
- JWT validation (tampered, malformed, invalid encoding)
- Authorization header handling (Bearer prefix, case sensitivity, extra spaces)
- Edge cases (null password, oversized username)

**Key Assertions:**
- RS256 JWT with correct key ID
- No private key material in JWKS
- Tampered tokens rejected with 401/403
- Malformed tokens rejected

### 2. Edge Case Tests (`test-edge-cases.sh`)

**Coverage:**
- Amount validation (negative, zero, non-numeric, oversized)
- Transfer validation (non-existent account, self-transfer, malformed account)
- Floating-point precision (0.1 + 0.1 + 0.1 = 0.3)
- Input validation (null fields, missing fields, oversized descriptions)
- Security (SQL injection in description, malformed JSON)
- Idempotency (key reused with different payload, oversized key)

**Key Assertions:**
- Negative/zero amounts rejected
- Insufficient funds prevented
- Oversized inputs handled gracefully
- SQL injection attempts neutralized
- Floating-point precision maintained

### 3. Integration Tests (`test-integration.sh`)

**Coverage:**
- Cross-user authorization (user cannot access other's accounts, transactions, transfers)
- Inter-user transfers (valid transfers between users)
- Concurrent requests (concurrent deposits, race conditions)
- Kafka event integrity (correct user ID in events)
- Idempotency scope (per-user)
- Notification service (multi-user events)

**Key Assertions:**
- User A cannot view User B's accounts (404/403)
- User A cannot modify User B's accounts (404/403)
- Concurrent operations maintain consistency
- Kafka events include correct user ID and account numbers
- Idempotency keys are scoped per user

## Usage Examples

### Run all tests
```bash
scripts/verify-compose-v2.sh
```

### Run specific suite
```bash
scripts/verify-compose-v2.sh --suite auth
scripts/verify-compose-v2.sh --suite edge_cases
scripts/verify-compose-v2.sh --suite integration
```

### Run specific test
```bash
# Run tests matching "jwt" in auth suite
scripts/verify-compose-v2.sh --suite auth --test jwt

# Run all tests matching "transfer" across all suites
scripts/verify-compose-v2.sh --test transfer
```

### Generate CI/CD output formats
```bash
# JSON results
scripts/verify-compose-v2.sh --output-format json

# JUnit XML for GitHub Actions, Jenkins
scripts/verify-compose-v2.sh --output-format junitxml
```

### Fresh start (clean volumes)
```bash
scripts/verify-compose-v2.sh --fresh
```

### Without sudo
```bash
scripts/verify-compose-v2.sh --no-sudo
```

## Architecture: Test Framework Layers

```
┌─────────────────────────────────────────────────────┐
│ Test Suites                                         │
│ (test-auth.sh, test-edge-cases.sh, etc.)           │
└──────────────────┬──────────────────────────────────┘
                   │ register_test(), run_test()
┌──────────────────▼──────────────────────────────────┐
│ Test Framework Core (test-framework.sh)             │
│ - Test registry (store/lookup functions)           │
│ - Result tracking (pass/fail/skip)                │
│ - Assertions (HTTP status, JSON, DB)              │
│ - Output formats (JSON, JUnit XML)                │
└──────────────────┬──────────────────────────────────┘
                   │ request(), db_query(), etc.
┌──────────────────▼──────────────────────────────────┐
│ Test Helpers (test-helpers.sh)                      │
│ - HTTP operations (curl wrapper, redaction)         │
│ - Database operations (MySQL queries)               │
│ - Kafka operations (message consumption)            │
│ - JWT utilities (decode, extract, tamper)          │
└──────────────────────────────────────────────────────┘
```

## Key Improvements Over Original

| Issue | Original | v2 |
|-------|----------|-----|
| **Lines of code** | 1023 | Modularized into 4 files |
| **Test discovery** | Hardcoded sequence | Registry-based, filterable, registration-ordered |
| **Error reporting** | Plain text | JSON, JUnit XML support |
| **Test isolation** | Order-dependent | Suite setup with explicit registration order |
| **Authorization tests** | None | 6 tests for cross-user access |
| **Validation tests** | Limited | 19 edge case tests |
| **Concurrent tests** | None | 2 race condition tests |
| **SQL injection tests** | None | Included in edge cases |
| **Code reuse** | Minimal | Helper library, test utilities |
| **CI/CD integration** | Not structured | JUnit XML for pipelines |

## Security Gaps Addressed

1. ✅ Cross-user authorization (users cannot access other's accounts)
2. ✅ Negative amount validation
3. ✅ Zero amount handling
4. ✅ SQL injection in transaction descriptions
5. ✅ Oversized input handling (DoS prevention)
6. ✅ JWT tampering detection
7. ✅ Malformed JWT rejection
8. ✅ Bearer token format validation

## Validation Gaps Addressed

1. ✅ Missing required fields (null amounts, null descriptions)
2. ✅ Non-numeric amounts
3. ✅ Non-numeric account numbers
4. ✅ Malformed account numbers (too short, invalid format)
5. ✅ Floating-point precision (0.1 + 0.1 + 0.1)
6. ✅ Transfer to non-existent account
7. ✅ Self-transfer edge case
8. ✅ Insufficient funds prevention

## Concurrency Gaps Addressed

1. ✅ Concurrent deposits (race conditions)
2. ✅ Concurrent withdrawals with insufficient funds
3. ✅ Race conditions on account balance updates
4. ✅ Idempotency under retry scenarios

## Migration from Original Script

The original `scripts/verify-compose.sh` is preserved. To migrate:

1. **Replace in CI/CD pipelines:**
   ```bash
   # Old
   scripts/verify-compose.sh
   
   # New
   scripts/verify-compose-v2.sh
   ```

2. **For GitHub Actions with test reporting:**
   ```bash
   scripts/verify-compose-v2.sh --output-format junitxml
   # Results in .test-results/results.xml
   ```

3. **For local testing by suite:**
   ```bash
   # Run only auth tests first
   scripts/verify-compose-v2.sh --suite auth
   
   # Then edge cases
   scripts/verify-compose-v2.sh --suite edge_cases
   ```

## Extending the Framework

### Add a new test:

```bash
# 1. Add test function in appropriate suite file
test_my_new_feature() {
    BASE_URL="$BANKING_URL"
    request POST /api/v1/accounts "$TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
}

# 2. Register in suite's register_tests function
register_test "my_suite" "my_new_feature" "test_my_new_feature"
```

### Add a new assertion:

```bash
# In test-framework.sh
assert_my_condition() {
    local expected="$1"
    [[ "$HTTP_STATUS" == "$expected" ]] || {
        test_fail "My condition" "Expected $expected"
        return 1
    }
}
```

### Create a new test suite:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Test functions...
test_feature_one() { ... }
test_feature_two() { ... }

# Registration
my_suite_register_tests() {
    register_test "my_suite" "feature_one" "test_feature_one"
    register_test "my_suite" "feature_two" "test_feature_two"
}

export -f my_suite_register_tests test_feature_one test_feature_two
```

Then in `verify-compose-v2.sh`:
```bash
source "$TESTS_DIR/test-my-suite.sh"
my_suite_register_tests
```

## Test Results Interpretation

### Text output (default)
```
[PASS] auth::jwks_endpoint_valid (2s)
[PASS] auth::user_registration_success (1s)
[FAIL] auth::tampered_jwt_rejected (3s): Expected 401, got 200
```

### JSON output
```json
{
  "framework": "bash-test-framework",
  "timestamp": "2026-08-29T19:46:44-04:00",
  "summary": {
    "total": 52,
    "passed": 50,
    "failed": 2,
    "skipped": 0
  },
  "results": [...]
}
```

### JUnit XML
Parseable by GitHub Actions, Jenkins, etc. Results in `.test-results/results.xml`.

## Performance Considerations

- **Serial execution** (default): ~60-120 seconds for all suites
- **Parallel execution** (experimental): Use `--parallel` flag
- **Suite filtering**: Run only needed suites for faster feedback
- **Test filtering**: Use `--test pattern` to run specific tests

## Troubleshooting

### Tests failing after fresh start
```bash
# Ensure containers are fully healthy
scripts/verify-compose-v2.sh --fresh
```

### Specific test debugging
```bash
# Run just one test with verbose output
scripts/verify-compose-v2.sh --suite auth --test registration
```

### Container logs
```bash
docker compose -f docker-compose.yml logs -f auth-service
docker compose -f docker-compose.yml logs -f banking-service
```

### Database state inspection
```bash
docker compose -f docker-compose.yml exec auth-db mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -D authdb -e "SELECT * FROM users;"
```

## Future Enhancements

- [ ] Parallel test execution with proper synchronization
- [ ] Test retry logic for flaky tests
- [ ] Performance profiling (slow test detection)
- [ ] Coverage reporting (which code paths tested)
- [ ] Visual HTML report generation
- [ ] Mutation testing integration
- [ ] Chaos engineering (random failures simulation)
- [ ] Load testing scenarios
