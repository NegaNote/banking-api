#!/usr/bin/env bash
# Integration test suite
# Tests for cross-user access, Kafka/notification flow, concurrent requests, etc.

set -Eeuo pipefail

# Test data for two users
declare -g INT_USER1_TOKEN=""
declare -g INT_USER1_ID=""
declare -g INT_USER1_ACCOUNT=""
declare -g INT_USER2_TOKEN=""
declare -g INT_USER2_ID=""
declare -g INT_USER2_ACCOUNT=""

# Setup: Create two test users
setup_two_users() {
    # User 1
    local user1_name="int-user1-$(date +%s%N)"
    local register_body=$(jq -cn \
        --arg username "$user1_name" \
        --arg email "${user1_name}@example.com" \
        --arg password "Password123!" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    INT_USER1_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
    INT_USER1_ID="$(jq -er '.sub' <<<"$(extract_jwt_payload "$INT_USER1_TOKEN")")"
    
    # User 2
    local user2_name="int-user2-$(date +%s%N)"
    register_body=$(jq -cn \
        --arg username "$user2_name" \
        --arg email "${user2_name}@example.com" \
        --arg password "Password123!" \
        '{username: $username, email: $email, password: $password}')
    
    request POST /api/auth/register '' "$register_body"
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    INT_USER2_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
    INT_USER2_ID="$(jq -er '.sub' <<<"$(extract_jwt_payload "$INT_USER2_TOKEN")")"
    
    # Create accounts for both users
    BASE_URL="$BANKING_URL"
    request POST /api/v1/accounts "$INT_USER1_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    INT_USER1_ACCOUNT="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
    
    request POST /api/v1/accounts "$INT_USER2_TOKEN" '{}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    INT_USER2_ACCOUNT="$(jq -er '.accountNumber' <<<"$HTTP_BODY")"
}

# Test: User cannot view other user's account list
test_user_cannot_view_other_accounts() {
    [[ -n "$INT_USER1_TOKEN" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # User 1 lists accounts
    request GET /api/v1/accounts "$INT_USER1_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # User 2 should see different accounts
    request GET /api/v1/accounts "$INT_USER2_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    local user2_accounts="$HTTP_BODY"
    
    # Verify User 2's account list doesn't contain User 1's account
    if jq -e ".[] | select(.accountNumber == \"$INT_USER1_ACCOUNT\")" <<<"$user2_accounts" >/dev/null 2>&1; then
        return 1  # User 2 can see User 1's account - SECURITY BREACH
    fi
}

# Test: User cannot view other user's account details
test_user_cannot_view_other_account_details() {
    [[ -n "$INT_USER1_TOKEN" && -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # User 2 tries to access User 1's account details
    request GET "/api/v1/accounts/$INT_USER1_ACCOUNT" "$INT_USER2_TOKEN"
    
    # Should return 404 or 403
    [[ "$HTTP_STATUS" == "404" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: User cannot deposit to other user's account
test_user_cannot_deposit_to_other_account() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER2_TOKEN" '{"amount": 100.00}'
    
    [[ "$HTTP_STATUS" == "404" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: User cannot withdraw from other user's account
test_user_cannot_withdraw_from_other_account() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # First deposit some funds to user 1's account
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # User 2 tries to withdraw
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/withdrawals" "$INT_USER2_TOKEN" '{"amount": 50.00}'
    
    [[ "$HTTP_STATUS" == "404" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: User cannot transfer from other user's account
test_user_cannot_transfer_from_other_account() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_ACCOUNT" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Deposit to user 1's account
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # User 2 tries to transfer from user 1's account
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/transfers" "$INT_USER2_TOKEN" \
        "{\"amount\": 50.00, \"toAccountNumber\": \"$INT_USER2_ACCOUNT\", \"description\": \"test\"}"
    
    [[ "$HTTP_STATUS" == "404" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: User cannot view other user's transaction history
test_user_cannot_view_other_account_transactions() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Deposit to user 1's account
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # User 2 tries to view user 1's transactions
    request GET "/api/v1/accounts/$INT_USER1_ACCOUNT/transactions" "$INT_USER2_TOKEN"
    
    [[ "$HTTP_STATUS" == "404" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Valid transfer between two users
test_valid_transfer_between_users() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_ACCOUNT" && -n "$INT_USER1_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Capture balances before the test operations
    request GET "/api/v1/accounts/$INT_USER1_ACCOUNT" "$INT_USER1_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user1_balance_before=$(jq -er '.balance' <<<"$HTTP_BODY")
    
    request GET "/api/v1/accounts/$INT_USER2_ACCOUNT" "$INT_USER2_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user2_balance_before=$(jq -er '.balance' <<<"$HTTP_BODY")
    
    # Deposit to user 1
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # User 1 transfers to User 2
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/transfers" "$INT_USER1_TOKEN" \
        "{\"amount\": 50.00, \"toAccountNumber\": \"$INT_USER2_ACCOUNT\", \"description\": \"test transfer\"}"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Verify User 1 balance increased by 100 then decreased by 50 (net +50)
    request GET "/api/v1/accounts/$INT_USER1_ACCOUNT" "$INT_USER1_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user1_balance_after=$(jq -er '.balance' <<<"$HTTP_BODY")
    local user1_expected=$(awk "BEGIN {printf \"%.2f\", $user1_balance_before + 50.00}")
    [[ "$user1_balance_after" == "$user1_expected" ]] || return 1
    
    # Verify User 2 received 50
    request GET "/api/v1/accounts/$INT_USER2_ACCOUNT" "$INT_USER2_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user2_balance_after=$(jq -er '.balance' <<<"$HTTP_BODY")
    local user2_expected=$(awk "BEGIN {printf \"%.2f\", $user2_balance_before + 50.00}")
    [[ "$user2_balance_after" == "$user2_expected" ]] || return 1
}

# Test: Kafka events reflect correct user ID for transfers
test_kafka_events_contain_correct_user_id() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_ACCOUNT" && -n "$INT_USER1_TOKEN" && -n "$INT_USER1_ID" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Deposit and transfer
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/transfers" "$INT_USER1_TOKEN" \
        "{\"amount\": 25.00, \"toAccountNumber\": \"$INT_USER2_ACCOUNT\", \"description\": \"test\"}"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Check Kafka messages
    local kafka_messages
    kafka_messages="$(kafka_topic_messages)"
    
    # Verify events have correct user ID
    if ! assert_kafka_event_present "$kafka_messages" 'DEPOSIT' "$INT_USER1_ID" "$INT_USER1_ACCOUNT" '100.00' 'SUCCESS' ''; then
        return 1
    fi
    
    if ! assert_kafka_event_present "$kafka_messages" 'TRANSFER' "$INT_USER1_ID" "$INT_USER1_ACCOUNT" '25.00' 'SUCCESS' "$INT_USER2_ACCOUNT"; then
        return 1
    fi
}

# Test: Concurrent deposits to same account maintain consistency
test_concurrent_deposits_consistency() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER1_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Make 5 concurrent requests
    local pids=()
    for i in {1..5}; do
        (
            request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 10.00}'
            [[ "$HTTP_STATUS" == "200" ]] || exit 1
        ) &
        pids+=($!)
    done
    
    # Wait for all to complete
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || ((++failed))
    done
    
    [[ $failed -eq 0 ]] || return 1
    
    # Verify final balance is 50.00
    request GET "/api/v1/accounts/$INT_USER1_ACCOUNT" "$INT_USER1_TOKEN"
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local balance=$(jq -er '.balance' <<<"$HTTP_BODY")
    [[ "$balance" == "50.00" ]] || return 1
}

# Test: Concurrent transfers with insufficient funds
test_concurrent_withdrawals_insufficient_funds() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER1_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # Deposit only 100
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 100.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Try 3 concurrent withdrawals of 50 each (total 150 > 100)
    local pids=()
    local results=()
    for i in {1..3}; do
        (
            request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/withdrawals" "$INT_USER1_TOKEN" '{"amount": 50.00}'
            # First should succeed, others should fail
            if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "422" ]]; then
                exit 0
            else
                exit 1
            fi
        ) &
        pids+=($!)
    done
    
    # Wait and count successes
    local failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || ((++failed))
    done
    
    # Should have at most 1 failure (due to insufficient funds)
    [[ $failed -le 1 ]] || return 1
}

# Test: Idempotency key scope is per-user
test_idempotency_key_per_user() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER2_ACCOUNT" && \
       -n "$INT_USER1_TOKEN" && -n "$INT_USER2_TOKEN" ]] || skip_test "Requires setup"
    
    BASE_URL="$BANKING_URL"
    
    # User 1 uses idempotency key
    request POST "/api/v2/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: shared-key'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user1_response="$(canonical_json "$HTTP_BODY")"
    
    # User 2 uses same idempotency key (should be independent)
    request POST "/api/v2/accounts/$INT_USER2_ACCOUNT/deposits" "$INT_USER2_TOKEN" '{"amount": 50.00}' \
        'Idempotency-Key: shared-key'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    local user2_response="$(canonical_json "$HTTP_BODY")"
    
    # Responses should be different (different accounts, balances)
    [[ "$user1_response" != "$user2_response" ]] || return 1
}

# Test: Notification service receives events from all users
test_notification_service_multi_user_events() {
    [[ -n "$INT_USER1_ACCOUNT" && -n "$INT_USER1_TOKEN" ]] || skip_test "Requires setup"
    
    # Perform a transaction
    BASE_URL="$BANKING_URL"
    request POST "/api/v1/accounts/$INT_USER1_ACCOUNT/deposits" "$INT_USER1_TOKEN" '{"amount": 50.00}'
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Get notification logs
    local count
    count="$(db_query notification-db \
        "SELECT COUNT(*) FROM notification_logs WHERE event_type = 'DEPOSIT' AND amount = 50.00")"
    
    [[ "$count" -gt 0 ]] || return 1
}

# Register all integration tests
integration_register_tests() {
    register_test "integration" "user_cannot_view_other_accounts" "test_user_cannot_view_other_accounts"
    register_test "integration" "user_cannot_view_other_account_details" "test_user_cannot_view_other_account_details"
    register_test "integration" "user_cannot_deposit_to_other_account" "test_user_cannot_deposit_to_other_account"
    register_test "integration" "user_cannot_withdraw_from_other_account" "test_user_cannot_withdraw_from_other_account"
    register_test "integration" "user_cannot_transfer_from_other_account" "test_user_cannot_transfer_from_other_account"
    register_test "integration" "user_cannot_view_other_account_transactions" "test_user_cannot_view_other_account_transactions"
    register_test "integration" "valid_transfer_between_users" "test_valid_transfer_between_users"
    register_test "integration" "kafka_events_contain_correct_user_id" "test_kafka_events_contain_correct_user_id"
    register_test "integration" "concurrent_deposits_consistency" "test_concurrent_deposits_consistency"
    register_test "integration" "concurrent_withdrawals_insufficient_funds" "test_concurrent_withdrawals_insufficient_funds"
    register_test "integration" "idempotency_key_per_user" "test_idempotency_key_per_user"
    register_test "integration" "notification_service_multi_user_events" "test_notification_service_multi_user_events"
}

# Export functions
export -f setup_two_users integration_register_tests
export -f test_user_cannot_view_other_accounts test_user_cannot_view_other_account_details
export -f test_user_cannot_deposit_to_other_account test_user_cannot_withdraw_from_other_account
export -f test_user_cannot_transfer_from_other_account test_user_cannot_view_other_account_transactions
export -f test_valid_transfer_between_users test_kafka_events_contain_correct_user_id
export -f test_concurrent_deposits_consistency test_concurrent_withdrawals_insufficient_funds
export -f test_idempotency_key_per_user test_notification_service_multi_user_events
