# Test Framework Quick Reference

## What Was Built

A production-grade test framework for the banking API with:
- ✅ **52+ tests** covering auth, validation, authorization, and concurrency
- ✅ **Modular architecture** (5 reusable files instead of 1000-line monolith)
- ✅ **Structured reporting** (JSON, JUnit XML for CI/CD)
- ✅ **Security testing** (cross-user access, SQL injection, JWT tampering)
- ✅ **Edge case coverage** (negative amounts, oversized input, floating-point precision)
- ✅ **Concurrent request testing** (race conditions, consistency)

## Directory Map

```
scripts/lib/
├── test-framework.sh       250 lines  - Core test harness
└── test-helpers.sh         350 lines  - HTTP, DB, Kafka utilities

scripts/tests/
├── test-auth.sh            400 lines  - 21 authentication tests
├── test-edge-cases.sh      450 lines  - 19 validation tests
└── test-integration.sh     400 lines  - 12 authorization & concurrency tests

scripts/
└── verify-compose-v2.sh    200 lines  - Main test runner
```

## Quick Start

```bash
# Run all tests
scripts/verify-compose-v2.sh

# Run one suite
scripts/verify-compose-v2.sh --suite auth

# Run specific test
scripts/verify-compose-v2.sh --suite auth --test jwt

# Generate report for CI/CD
scripts/verify-compose-v2.sh --output-format junitxml
```

## Key Files

| File | Purpose | Size |
|------|---------|------|
| `test-framework.sh` | Test registry, assertions, result tracking | 250 lines |
| `test-helpers.sh` | HTTP, DB, Kafka, JWT utilities | 350 lines |
| `test-auth.sh` | JWT, JWKS, registration, login, auth edge cases | 400 lines |
| `test-edge-cases.sh` | Input validation, boundary conditions, security | 450 lines |
| `test-integration.sh` | Cross-user access, concurrency, Kafka events | 400 lines |
| `verify-compose-v2.sh` | Test runner with CLI, reporting | 200 lines |
| `TESTING.md` | Complete architecture & migration guide | 300+ lines |

## Test Coverage Summary

### Authentication (21 tests)
- JWKS validation (public key format, no private keys)
- User registration (success, duplicate, weak password, invalid email, oversized username, null password)
- User login (success, invalid password, non-existent user)
- JWT validation (tampered, malformed, invalid encoding, expired, wrong issuer)
- Authorization header (Bearer prefix, case sensitivity, extra spaces, missing header)

### Edge Cases & Validation (19 tests)
- Amount validation (negative, zero, non-numeric, oversized)
- Account validation (non-existent, non-numeric, malformed format)
- Transfer validation (self-transfer, non-existent recipient)
- Input validation (null fields, missing fields, oversized descriptions)
- Security (SQL injection, malformed JSON)
- Floating-point precision (0.1 + 0.1 + 0.1 = 0.3)
- Idempotency (key reuse with different payload, oversized key)

### Integration & Authorization (12 tests)
- Cross-user access control (cannot view, deposit, withdraw, transfer, list transactions)
- Valid inter-user transfers
- Concurrent requests (deposits, withdrawals with insufficient funds)
- Kafka event integrity (correct user ID, account number)
- Notification service (multi-user events)
- Idempotency scoping (per-user)

## Framework Features

### Test Registry
- Declarative test registration
- Filterable by suite and name
- Automatic discovery

### Assertions
- `assert_http_status` - Verify HTTP response code
- `assert_http_status_any` - Allow multiple valid codes
- `assert_json_matches` - Validate JSON response
- `assert_db_value` - Verify database state
- `assert_kafka_event_present/absent` - Event stream validation

### Helpers
- `request()` - HTTP operations with token handling
- `db_query()` - Database queries with parameterization
- `kafka_topic_messages()` - Consume Kafka messages
- `extract_jwt_payload()` - JWT parsing
- `tamper_jwt()` - JWT tampering for negative tests
- `canonical_json()` - JSON canonicalization for comparison
- `redact_response()` - Remove sensitive data from logs

### Reporting
- Text output (default) with timing info
- JSON output (parseable by CI/CD)
- JUnit XML (GitHub Actions, Jenkins compatible)
- Per-test timing and failure reasons

## Security Gaps Closed

| Gap | Test | File |
|-----|------|------|
| Cross-user access | `user_cannot_view_other_accounts` | integration |
| Negative amounts | `negative_deposit_rejected` | edge_cases |
| SQL injection | `sql_injection_in_description` | edge_cases |
| JWT tampering | `tampered_jwt_rejected` | auth |
| Oversized input | `registration_oversized_username` | auth |
| Non-existent account | `transfer_nonexistent_account` | edge_cases |
| Race conditions | `concurrent_deposits_consistency` | integration |

## Common Patterns

### Add a test function
```bash
test_my_feature() {
    BASE_URL="$BANKING_URL"
    request POST /api/v1/accounts "$TOKEN" '{"amount": 100}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    jq -e '.balance == 100' <<<"$HTTP_BODY" >/dev/null || return 1
}
```

### Register test
```bash
register_test "my_suite" "my_feature" "test_my_feature"
```

### Assertion pattern
```bash
assert_http_status "201" "User registration"
assert_json_matches '.token | length > 0' "JWT was returned"
assert_db_value "auth-db" "SELECT COUNT(*) FROM users" "1" "User created"
```

## CI/CD Integration

### GitHub Actions
```yaml
- name: Run banking API tests
  run: scripts/verify-compose-v2.sh --output-format junitxml

- name: Publish test results
  uses: dorny/test-reporter@v1
  with:
    name: Banking API Tests
    path: '.test-results/results.xml'
    reporter: 'java-junit'
```

### Jenkins
```groovy
stage('Test') {
    steps {
        sh 'scripts/verify-compose-v2.sh --output-format junitxml'
        junit '.test-results/results.xml'
    }
}
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Tests fail randomly | Run `--fresh` to reset volumes |
| Specific test fails | Use `--suite auth --test jwt` to debug |
| Docker permission denied | Add `--no-sudo` flag |
| Slow tests | Check logs: `docker compose logs -f service-name` |
| JSON parsing errors | Verify jq is installed: `jq --version` |

## Backward Compatibility

The original `scripts/verify-compose.sh` is preserved. Both work in parallel:

```bash
# Original (still works)
scripts/verify-compose.sh

# New (recommended)
scripts/verify-compose-v2.sh
```

## What's New vs Original

| Aspect | Original | v2 |
|--------|----------|-----|
| Test count | 15 implicit | 52 explicit |
| Modularity | Monolithic | 5 files |
| Reporting | Plain text | JSON, JUnit XML |
| Authorization testing | None | 6 tests |
| SQL injection testing | None | 1 test |
| Concurrency testing | None | 2 tests |
| Code reuse | Minimal | Helpers library |
| Test discovery | Hardcoded | Registry-based |
| CI/CD integration | Manual parsing | Structured output |

## Files to Know

- **`lib/test-framework.sh`** - Modify here to add assertion types
- **`lib/test-helpers.sh`** - Modify here to add utility functions
- **`tests/test-*.sh`** - Add new tests here
- **`verify-compose-v2.sh`** - Main entry point, orchestrates all tests
- **`TESTING.md`** - Complete architecture guide (you're reading the summary)

---

**For detailed information, see:** `TESTING.md`
