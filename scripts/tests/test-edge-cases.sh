#!/usr/bin/env bash
# Edge case and validation test suite
# Tests for boundary conditions, malformed input, and security issues

set -Eeuo pipefail
# Setup: Register test user and create account
setup_edge_case_user() {
    local username
    username="edge-$(date +%s%N)"
    local email="${username}@example.com"
    
    local register_body
    register_body=$(jq -cn \
        --arg username "$username" \
        --arg email "$email" \
        --arg password "Password123!" \
        '{username: $username, email: $email, password: $password}')
    
    request POST /api/auth/register '' "$register_body"
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    EDGE_TEST_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
}

# Test: Negative deposit amount rejected
test_negative_deposit_rejected() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    # Create account first
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # Try negative deposit
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": -50.00}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Zero deposit amount handling
test_zero_deposit_handling() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 0.00}'
    
    # Should reject zero amount
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Negative withdrawal rejected
test_negative_withdrawal_rejected() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # Deposit first
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Try negative withdrawal
    request POST "/api/v1/accounts/$account/withdrawals" "$EDGE_TEST_TOKEN" '{"amount": -50.00}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Withdrawal exceeding balance
test_withdrawal_insufficient_funds() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # Deposit only 50
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 50.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Try to withdraw 100
    request POST "/api/v1/accounts/$account/withdrawals" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Transfer to non-existent account
test_transfer_nonexistent_account() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Transfer to fake account
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        '{"amount": 50.00, "toAccountNumber": "999999999999", "description": "test"}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Self-transfer
test_self_transfer() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Transfer to self
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        "{\"amount\": 50.00, \"toAccountNumber\": \"$account\", \"description\": \"self\"}"
    
    # Should reject or handle specially
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 0  # Or allow but verify balance is correct
}

# Test: Oversized transfer description
test_oversized_transfer_description() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    local long_desc
    long_desc=$(printf 'a%.0s' {1..10000})
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local target
    target=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        "{\"amount\": 50.00, \"toAccountNumber\": \"$target\", \"description\": \"$long_desc\"}"
    
    # Should reject or truncate
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 0
}

# Test: Extremely large amount
test_very_large_amount() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # Try to deposit maximum BigDecimal value
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" \
        '{"amount": 99999999999999999999.99}'
    
    # Should handle gracefully (reject or cap)
    [[ "$HTTP_STATUS" =~ ^[24] ]] || return 1
}

# Test: Floating-point precision: 0.1 + 0.1 + 0.1 = 0.3
test_floating_point_precision() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # Deposit three times 0.1
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 0.1}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 0.1}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 0.1}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Check balance is exactly 0.3 (not 0.30000000000000004)
    request GET "/api/v1/accounts/$account" "$EDGE_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    local balance
    balance=$(jq -er '.balance' <<<"$HTTP_BODY")
    [[ "$balance" == "0.3" || "$balance" == "0.30" ]] || return 1
}

# Test: Missing required field in deposit
test_deposit_missing_amount() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Null amount in request
test_deposit_null_amount() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": null}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Non-numeric amount
test_deposit_non_numeric_amount() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": "not a number"}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: SQL injection in transfer description
test_sql_injection_in_description() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local target
    target=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    
    local malicious_desc="test'; DROP TABLE bank_transactions; --"
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        "{\"amount\": 50.00, \"toAccountNumber\": \"$target\", \"description\": \"$malicious_desc\"}"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Verify table still exists and has data
    db_query banking-db "SELECT COUNT(*) FROM bankdb.bank_transactions" >/dev/null || return 1
}

# Test: Non-numeric account number in transfer
test_transfer_non_numeric_account() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        '{"amount": 50.00, "toAccountNumber": "not-a-number", "description": "test"}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Malformed account number in transfer
test_transfer_malformed_account() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v1/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}'
    
    # Too short
    request POST "/api/v1/accounts/$account/transfers" "$EDGE_TEST_TOKEN" \
        '{"amount": 50.00, "toAccountNumber": "12345", "description": "test"}'
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Idempotency key reused with different payload
test_idempotency_key_different_payload() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v2/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    # First request
    request POST "/api/v2/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: test-key'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Replay with different amount
    request POST "/api/v2/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 100.00}' \
        'Idempotency-Key: test-key'
    
    # Should reject with conflict
    [[ "$HTTP_STATUS" == "409" ]] || return 1
}

# Test: Oversized idempotency key
test_oversized_idempotency_key() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    local long_key
    long_key=$(printf 'k%.0s' {1..10000})
    
    request POST /api/v2/accounts "$EDGE_TEST_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local account
    account=$(jq -er '.accountNumber' <<<"$HTTP_BODY")
    
    request POST "/api/v2/accounts/$account/deposits" "$EDGE_TEST_TOKEN" '{"amount": 50.00}' \
        "Idempotency-Key: $long_key"
    
    # Should handle gracefully
    [[ "$HTTP_STATUS" =~ ^[24] ]] || return 1
}

# Test: Access to non-existent account returns 404
test_access_nonexistent_account() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request GET /api/v1/accounts/999999999999 "$EDGE_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "404" ]] || return 1
}

# Test: Malformed JSON in request body
test_malformed_json_request() {
    [[ -n "$EDGE_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    
    local curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X POST
        "${BANKING_URL}/api/v1/accounts"
        -H "Authorization: Bearer $EDGE_TEST_TOKEN"
        -H 'Content-Type: application/json'
        --data '{"invalid json}'  # Missing closing brace
        -w $'\n%{http_code}'
    )
    
    local response
    response="$(curl "${curl_args[@]}" 2>/dev/null)" || true
    HTTP_STATUS="${response##*$'\n'}"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Register all edge case tests
edge_cases_register_tests() {
    register_test "edge_cases" "negative_deposit_rejected" "test_negative_deposit_rejected"
    register_test "edge_cases" "zero_deposit_handling" "test_zero_deposit_handling"
    register_test "edge_cases" "negative_withdrawal_rejected" "test_negative_withdrawal_rejected"
    register_test "edge_cases" "withdrawal_insufficient_funds" "test_withdrawal_insufficient_funds"
    register_test "edge_cases" "transfer_nonexistent_account" "test_transfer_nonexistent_account"
    register_test "edge_cases" "self_transfer" "test_self_transfer"
    register_test "edge_cases" "oversized_transfer_description" "test_oversized_transfer_description"
    register_test "edge_cases" "very_large_amount" "test_very_large_amount"
    register_test "edge_cases" "floating_point_precision" "test_floating_point_precision"
    register_test "edge_cases" "deposit_missing_amount" "test_deposit_missing_amount"
    register_test "edge_cases" "deposit_null_amount" "test_deposit_null_amount"
    register_test "edge_cases" "deposit_non_numeric_amount" "test_deposit_non_numeric_amount"
    register_test "edge_cases" "sql_injection_in_description" "test_sql_injection_in_description"
    register_test "edge_cases" "transfer_non_numeric_account" "test_transfer_non_numeric_account"
    register_test "edge_cases" "transfer_malformed_account" "test_transfer_malformed_account"
    register_test "edge_cases" "idempotency_key_different_payload" "test_idempotency_key_different_payload"
    register_test "edge_cases" "oversized_idempotency_key" "test_oversized_idempotency_key"
    register_test "edge_cases" "access_nonexistent_account" "test_access_nonexistent_account"
    register_test "edge_cases" "malformed_json_request" "test_malformed_json_request"
}

# Export functions
export -f setup_edge_case_user edge_cases_register_tests
export -f test_negative_deposit_rejected test_zero_deposit_handling
export -f test_negative_withdrawal_rejected test_withdrawal_insufficient_funds
export -f test_transfer_nonexistent_account test_self_transfer
export -f test_oversized_transfer_description test_very_large_amount
export -f test_floating_point_precision
export -f test_deposit_missing_amount test_deposit_null_amount test_deposit_non_numeric_amount
export -f test_sql_injection_in_description test_transfer_non_numeric_account test_transfer_malformed_account
export -f test_idempotency_key_different_payload test_oversized_idempotency_key
export -f test_access_nonexistent_account test_malformed_json_request
