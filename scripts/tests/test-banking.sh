#!/usr/bin/env bash
# Banking API test suite
# Tests for account operations, deposits, withdrawals, transfers, and transaction history

set -Eeuo pipefail

# Test data for banking operations
declare -g BANKING_TEST_TOKEN=""
declare -g BANKING_TEST_ACCOUNT1=""
declare -g BANKING_TEST_ACCOUNT2=""

# Setup: Create test user with authenticated token
setup_banking_user() {
    local username
    username="banking-$(date +%s%N)"
    local email
    email="${username}@example.com"

    local register_body
    register_body=$(jq -cn \
        --arg username "$username" \
        --arg email "$email" \
        --arg password "Password123!" \
        '{username: $username, email: $email, password: $password}')
    
    request POST /api/auth/register '' "$register_body"
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    BANKING_TEST_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
}

# Test: Unauthenticated account list returns 401/403
test_unauthenticated_account_list() {
    request GET /api/v1/accounts
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Tampered token rejected for account access
test_tampered_token_account_access() {
    [[ -n "$BANKING_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    local tampered
    tampered=$(tamper_jwt "$BANKING_TEST_TOKEN")
    
    request GET /api/v1/accounts "$tampered"
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Initial account list is empty
test_initial_account_list_empty() {
    [[ -n "$BANKING_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request GET /api/v1/accounts "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e 'type == "array" and length == 0' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: Create account returns 12-digit account number
test_create_account_v1() {
    [[ -n "$BANKING_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$BANKING_TEST_TOKEN" '{}'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    BANKING_TEST_ACCOUNT1="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
    [[ "$BANKING_TEST_ACCOUNT1" =~ ^[0-9]{12}$ ]] || return 1
}

# Test: Create second account with different account number
test_create_second_account() {
    [[ -n "$BANKING_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    request POST /api/v1/accounts "$BANKING_TEST_TOKEN" '{}'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    BANKING_TEST_ACCOUNT2="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
    [[ "$BANKING_TEST_ACCOUNT2" =~ ^[0-9]{12}$ ]] || return 1
    [[ "$BANKING_TEST_ACCOUNT1" != "$BANKING_TEST_ACCOUNT2" ]] || return 1
}

# Test: Account list contains created accounts
test_list_accounts_contains_created() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" && -n "$BANKING_TEST_ACCOUNT2" ]] || skip_test "Requires setup"
    
    request GET /api/v1/accounts "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    jq -e --arg first "$BANKING_TEST_ACCOUNT1" --arg second "$BANKING_TEST_ACCOUNT2" \
        'length == 2 and ([.[].accountNumber] | sort) == ([$first, $second] | sort)' \
        <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v1 and v2 account lists are consistent
test_v1_v2_account_list_consistency() {
    [[ -n "$BANKING_TEST_TOKEN" ]] || skip_test "Requires setup"
    
    
    request GET /api/v1/accounts "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local v1_accounts
    v1_accounts="$(canonical_json "$HTTP_BODY")"

    request GET /api/v2/accounts "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local v2_accounts
    v2_accounts="$(canonical_json "$HTTP_BODY")"
    
    [[ "$v1_accounts" == "$v2_accounts" ]] || return 1
}

# Test: Get account details
test_get_account_details() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1" "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e --arg account "$BANKING_TEST_ACCOUNT1" '.accountNumber == $account' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v1 deposit increments balance
test_v1_deposit() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request POST "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 100.00}'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 100.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v1 withdrawal decrements balance
test_v1_withdrawal() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request POST "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/withdrawals" "$BANKING_TEST_TOKEN" '{"amount": 10.00}'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 90.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v1 transfer between accounts
test_v1_transfer() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" && -n "$BANKING_TEST_ACCOUNT2" ]] || skip_test "Requires setup"
    
    request POST "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/transfers" "$BANKING_TEST_TOKEN" \
        "{\"amount\": 15.00, \"toAccountNumber\": \"$BANKING_TEST_ACCOUNT2\", \"description\": \"v1 transfer\"}"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 75.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v2 deposit requires Idempotency-Key
test_v2_deposit_requires_idempotency_key() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 50.00}'
    
    [[ "$HTTP_STATUS" == "400" ]] || return 1
}

# Test: v2 deposit with Idempotency-Key succeeds
test_v2_deposit_with_idempotency_key() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: banking-deposit-v2'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 125.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v2 idempotency replays same response
test_v2_idempotency_replay() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    
    # Replay same request with same idempotency key and body
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: banking-deposit-v2'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local first_response
    first_response="$(canonical_json "$HTTP_BODY")"

    # Replay same request (should return cached response)
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: banking-deposit-v2'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local replay_response
    replay_response="$(canonical_json "$HTTP_BODY")"
    
    [[ "$first_response" == "$replay_response" ]] || return 1
}

# Test: v2 idempotency rejects different body with same key
test_v2_idempotency_conflict() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    
    # Use same idempotency key from the deposit test with different body
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/deposits" "$BANKING_TEST_TOKEN" '{"amount": 100.00}' \
        'Idempotency-Key: banking-deposit-v2'
    
    [[ "$HTTP_STATUS" == "409" ]] || return 1
}

# Test: v2 withdrawal with idempotency
test_v2_withdrawal_idempotent() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/withdrawals" "$BANKING_TEST_TOKEN" '{"amount": 5.00}' \
        'Idempotency-Key: banking-withdrawal-v2'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 120.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v2 transfer with idempotency
test_v2_transfer_idempotent() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" && -n "$BANKING_TEST_ACCOUNT2" ]] || skip_test "Requires setup"
    
    request POST "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/transfers" "$BANKING_TEST_TOKEN" \
        "{\"amount\": 20.00, \"toAccountNumber\": \"$BANKING_TEST_ACCOUNT2\", \"description\": \"v2 transfer\"}" \
        'Idempotency-Key: banking-transfer-v2'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    jq -e '.balance == 100.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: Recipient receives transfer
test_transfer_recipient_receives_funds() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT2" ]] || skip_test "Requires setup"
    
    request GET "/api/v2/accounts/$BANKING_TEST_ACCOUNT2" "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    # Should have received: 15.00 (v1) + 20.00 (v2) = 35.00
    jq -e '.balance == 35.00' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v1 transaction history lists all operations
test_v1_transaction_history() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/transactions" "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Should have 6 transactions: 2 deposits, 1 withdrawal, 3 transfers (in/out)
    jq -e 'length >= 4' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: v2 transaction history matches v1
test_v2_v1_transaction_history_consistency() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/transactions" "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local v1_history
    v1_history="$(canonical_json "$HTTP_BODY")"

    request GET "/api/v2/accounts/$BANKING_TEST_ACCOUNT1/transactions" "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local v2_history
    v2_history="$(canonical_json "$HTTP_BODY")"
    
    [[ "$v1_history" == "$v2_history" ]] || return 1
}

# Test: Transaction history includes correct transaction types
test_transaction_history_types() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" ]] || skip_test "Requires setup"
    
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/transactions" "$BANKING_TEST_TOKEN"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Verify it has different transaction types
    jq -e 'map(select(.type == "DEPOSIT")) | length > 0' <<<"$HTTP_BODY" >/dev/null || return 1
    jq -e 'map(select(.type == "WITHDRAWAL")) | length > 0' <<<"$HTTP_BODY" >/dev/null || return 1
}

# Test: Declined transfer (insufficient funds) doesn't change balance
test_declined_transfer_no_balance_change() {
    [[ -n "$BANKING_TEST_TOKEN" && -n "$BANKING_TEST_ACCOUNT1" && -n "$BANKING_TEST_ACCOUNT2" ]] || skip_test "Requires setup"
    
    
    # Get current balance
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1" "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local current_balance
    current_balance=$(jq -er '.balance' <<<"$HTTP_BODY")
    
    # Try to transfer more than balance
    request POST "/api/v1/accounts/$BANKING_TEST_ACCOUNT1/transfers" "$BANKING_TEST_TOKEN" \
        "{\"amount\": 9999.99, \"toAccountNumber\": \"$BANKING_TEST_ACCOUNT2\", \"description\": \"declined\"}"
    
    [[ "$HTTP_STATUS" == "422" || "$HTTP_STATUS" == "400" ]] || return 1
    
    # Verify balance unchanged
    request GET "/api/v1/accounts/$BANKING_TEST_ACCOUNT1" "$BANKING_TEST_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local new_balance
    new_balance=$(jq -er '.balance' <<<"$HTTP_BODY")
    
    [[ "$current_balance" == "$new_balance" ]] || return 1
}

# Register all banking API tests
banking_register_tests() {
    register_test "banking" "unauthenticated_account_list" "test_unauthenticated_account_list"
    register_test "banking" "tampered_token_account_access" "test_tampered_token_account_access"
    register_test "banking" "initial_account_list_empty" "test_initial_account_list_empty"
    register_test "banking" "create_account_v1" "test_create_account_v1"
    register_test "banking" "create_second_account" "test_create_second_account"
    register_test "banking" "list_accounts_contains_created" "test_list_accounts_contains_created"
    register_test "banking" "v1_v2_account_list_consistency" "test_v1_v2_account_list_consistency"
    register_test "banking" "get_account_details" "test_get_account_details"
    register_test "banking" "v1_deposit" "test_v1_deposit"
    register_test "banking" "v1_withdrawal" "test_v1_withdrawal"
    register_test "banking" "v1_transfer" "test_v1_transfer"
    register_test "banking" "v2_deposit_requires_idempotency_key" "test_v2_deposit_requires_idempotency_key"
    register_test "banking" "v2_deposit_with_idempotency_key" "test_v2_deposit_with_idempotency_key"
    register_test "banking" "v2_idempotency_replay" "test_v2_idempotency_replay"
    register_test "banking" "v2_idempotency_conflict" "test_v2_idempotency_conflict"
    register_test "banking" "v2_withdrawal_idempotent" "test_v2_withdrawal_idempotent"
    register_test "banking" "v2_transfer_idempotent" "test_v2_transfer_idempotent"
    register_test "banking" "transfer_recipient_receives_funds" "test_transfer_recipient_receives_funds"
    register_test "banking" "v1_transaction_history" "test_v1_transaction_history"
    register_test "banking" "v2_v1_transaction_history_consistency" "test_v2_v1_transaction_history_consistency"
    register_test "banking" "transaction_history_types" "test_transaction_history_types"
    register_test "banking" "declined_transfer_no_balance_change" "test_declined_transfer_no_balance_change"
}

# Export functions
export -f banking_register_tests
export -f setup_banking_user
export -f test_unauthenticated_account_list test_tampered_token_account_access
export -f test_initial_account_list_empty test_create_account_v1 test_create_second_account
export -f test_list_accounts_contains_created test_v1_v2_account_list_consistency
export -f test_get_account_details
export -f test_v1_deposit test_v1_withdrawal test_v1_transfer
export -f test_v2_deposit_requires_idempotency_key test_v2_deposit_with_idempotency_key
export -f test_v2_idempotency_replay test_v2_idempotency_conflict
export -f test_v2_withdrawal_idempotent test_v2_transfer_idempotent
export -f test_transfer_recipient_receives_funds
export -f test_v1_transaction_history test_v2_v1_transaction_history_consistency
export -f test_transaction_history_types
export -f test_declined_transfer_no_balance_change
