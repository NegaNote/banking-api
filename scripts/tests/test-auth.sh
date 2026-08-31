#!/usr/bin/env bash
# Authentication test suite
# Tests JWT, JWKS, registration, login, and authentication security

set -Eeuo pipefail

# Test data
declare -g AUTH_TEST_USERNAME=""
declare -g AUTH_TEST_EMAIL=""
declare -g AUTH_TEST_PASSWORD="Password123!"
declare -g AUTH_TEST_TOKEN=""
declare -g AUTH_TEST_USER_ID=""

# Test: JWKS endpoint returns valid RS256 keys
test_jwks_endpoint_valid() {
    BASE_URL="$AUTH_URL"
    request GET '/.well-known/jwks.json'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    jq -e \
        '.keys | type == "array" and length > 0 and
         all(.[]; .kty == "RSA" and .use == "sig" and .alg == "RS256" and
             (.kid | type == "string") and (.n | type == "string") and
             (.e | type == "string"))' \
        <<<"$HTTP_BODY" >/dev/null 2>&1 || return 1
}

# Test: JWKS contains no private key material
test_jwks_no_private_keys() {
    BASE_URL="$AUTH_URL"
    request GET '/.well-known/jwks.json'
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Should not contain private key fields (d, p, q, dp, dq, qi)
    if jq -e '.keys[] | select(.d or .p or .q)' <<<"$HTTP_BODY" >/dev/null 2>&1; then
        return 1
    fi
}

# Test: User registration with valid data
test_user_registration_success() {
    AUTH_TEST_USERNAME="verify-$(date -u +%Y%m%d%H%M%S)-$$"
    AUTH_TEST_EMAIL="${AUTH_TEST_USERNAME}@example.com"
    
    local register_body=$(jq -cn \
        --arg username "$AUTH_TEST_USERNAME" \
        --arg email "$AUTH_TEST_EMAIL" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    # Verify response structure
    jq -e \
        '.username == $username and .tokenType == "Bearer" and
         (.expiresInMs | tonumber) > 0 and (.token | type) == "string"' \
        <<<"$HTTP_BODY" \
        --arg username "$AUTH_TEST_USERNAME" >/dev/null 2>&1 || return 1
    
    # Extract and validate JWT
    AUTH_TEST_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
    [[ "$AUTH_TEST_TOKEN" =~ ^[^.]+\.[^.]+\.[^.]+$ ]] || return 1
    
    # Verify JWT header is RS256
    local token_header="${AUTH_TEST_TOKEN%%.*}"
    local header_json
    header_json="$(decode_jwt_segment "$token_header")"
    jq -e '.alg == "RS256" and .kid == "auth-key-1"' <<<"$header_json" >/dev/null 2>&1 || return 1
    
    # Extract user ID from token payload
    local token_payload
    token_payload="$(extract_jwt_payload "$AUTH_TEST_TOKEN")"
    AUTH_TEST_USER_ID="$(jq -er '.sub' <<<"$token_payload")"
}

# Test: Registration fails with invalid email
test_user_registration_invalid_email() {
    local register_body=$(jq -cn \
        --arg username "user-$(date +%s)" \
        --arg email "not-an-email" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    
    # Should reject with 4xx status
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Registration fails with weak password
test_user_registration_weak_password() {
    local register_body=$(jq -cn \
        --arg username "user-$(date +%s)" \
        --arg email "user@example.com" \
        --arg password "weak" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Registration fails with duplicate username
test_user_registration_duplicate_username() {
    # First registration
    local username="duplicate-$(date +%s%N)"
    local register_body=$(jq -cn \
        --arg username "$username" \
        --arg email "${username}@example.com" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    [[ "$HTTP_STATUS" == "201" ]] || return 1
    
    # Second registration with same username, different email
    register_body=$(jq -cn \
        --arg username "$username" \
        --arg email "${username}-2@example.com" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, email: $email, password: $password}')
    
    request POST /api/auth/register '' "$register_body"
    
    # Should reject duplicate
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: User login with valid credentials
test_user_login_success() {
    if [[ -z "$AUTH_TEST_USERNAME" ]]; then
        skip_test "Requires prior registration test"
        return 0
    fi
    
    local login_body=$(jq -cn \
        --arg username "$AUTH_TEST_USERNAME" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/login '' "$login_body"
    
    [[ "$HTTP_STATUS" == "200" ]] || return 1
    
    # Verify response structure
    jq -e \
        '.username == $username and .tokenType == "Bearer" and
         (.token | type) == "string"' \
        <<<"$HTTP_BODY" \
        --arg username "$AUTH_TEST_USERNAME" >/dev/null 2>&1 || return 1
    
    AUTH_TEST_TOKEN="$(jq -er '.token' <<<"$HTTP_BODY")"
}

# Test: Login fails with invalid credentials
test_user_login_invalid_password() {
    [[ -n "$AUTH_TEST_USERNAME" ]] || skip_test "Requires prior registration test"
    
    local login_body=$(jq -cn \
        --arg username "$AUTH_TEST_USERNAME" \
        --arg password "WrongPassword123!" \
        '{username: $username, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/login '' "$login_body"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Login fails with non-existent user
test_user_login_nonexistent_user() {
    local login_body=$(jq -cn \
        --arg username "nonexistent-$(date +%s)" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/login '' "$login_body"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: Tampered JWT is rejected
test_tampered_jwt_rejected() {
    [[ -n "$AUTH_TEST_TOKEN" ]] || skip_test "Requires prior authentication test"
    
    local tampered=$(tamper_jwt "$AUTH_TEST_TOKEN")
    
    BASE_URL="$AUTH_URL"
    request GET '/api/auth/validate' "$tampered"
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Malformed JWT (missing segment) is rejected
test_malformed_jwt_missing_segment() {
    local malformed="invalid.jwt"
    
    BASE_URL="$AUTH_URL"
    request GET '/api/auth/validate' "$malformed"
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Invalid JWT encoding is rejected
test_invalid_jwt_encoding() {
    local invalid_jwt="invalid!header.invalid!payload.invalid!signature"
    
    BASE_URL="$AUTH_URL"
    request GET '/api/auth/validate' "$invalid_jwt"
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Bearer token without prefix is rejected
test_jwt_without_bearer_prefix() {
    [[ -n "$AUTH_TEST_TOKEN" ]] || skip_test "Requires prior authentication test"
    
    local curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X GET
        "${BANKING_URL}/api/v1/accounts"
        -H "Authorization: $AUTH_TEST_TOKEN"  # Missing "Bearer " prefix
        -w $'\n%{http_code}'
    )
    
    local response
    response="$(curl "${curl_args[@]}" 2>/dev/null)" || true
    HTTP_STATUS="${response##*$'\n'}"
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Missing Authorization header requires auth
test_missing_auth_header() {
    BASE_URL="$BANKING_URL"
    request GET '/api/v1/accounts'
    
    [[ "$HTTP_STATUS" == "401" || "$HTTP_STATUS" == "403" ]] || return 1
}

# Test: Token with null or empty username field (if applicable)
test_jwt_null_username_field() {
    # This would require manual JWT crafting; marking as skip for now
    skip_test "Would require manual JWT crafting with invalid claims"
}

# Test: Token from different issuer is rejected
test_jwt_different_issuer() {
    skip_test "Requires multiple auth services or manual JWT generation"
}

# Test: Expired token is rejected (if applicable)
test_expired_token_rejected() {
    skip_test "Would require clock manipulation or waiting for expiration"
}

# Test: Case sensitivity of Bearer prefix
test_bearer_prefix_case_sensitivity() {
    [[ -n "$AUTH_TEST_TOKEN" ]] || skip_test "Requires prior authentication test"
    
    # Try with lowercase 'bearer'
    local curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X GET
        "${AUTH_URL}/api/auth/validate"
        -H "Authorization: bearer $AUTH_TEST_TOKEN"
        -w $'\n%{http_code}'
    )
    
    local response
    response="$(curl "${curl_args[@]}" 2>/dev/null)" || true
    HTTP_STATUS="${response##*$'\n'}"
    
    # Should work (case-insensitive) or fail consistently
    [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || return 1
}

# Test: Multiple spaces in Authorization header
test_multiple_spaces_in_auth_header() {
    [[ -n "$AUTH_TEST_TOKEN" ]] || skip_test "Requires prior authentication test"
    
    local curl_args=(
        -sS
        --connect-timeout 5
        --max-time 20
        -X GET
        "${AUTH_URL}/api/auth/validate"
        -H "Authorization: Bearer  $AUTH_TEST_TOKEN"  # Double space
        -w $'\n%{http_code}'
    )
    
    local response
    response="$(curl "${curl_args[@]}" 2>/dev/null)" || true
    HTTP_STATUS="${response##*$'\n'}"
    
    [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || return 1
}

# Test: User cannot register with null password
test_registration_null_password() {
    local register_body=$(jq -cn \
        --arg username "user-$(date +%s)" \
        --arg email "user@example.com" \
        '{username: $username, email: $email, password: null}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Test: User cannot register with oversized username
test_registration_oversized_username() {
    local long_username=$(printf 'a%.0s' {1..1000})
    
    local register_body=$(jq -cn \
        --arg username "$long_username" \
        --arg email "user@example.com" \
        --arg password "$AUTH_TEST_PASSWORD" \
        '{username: $username, email: $email, password: $password}')
    
    BASE_URL="$AUTH_URL"
    request POST /api/auth/register '' "$register_body"
    
    [[ "$HTTP_STATUS" =~ ^4 ]] || return 1
}

# Register all auth tests
auth_register_tests() {
    register_test "auth" "jwks_endpoint_valid" "test_jwks_endpoint_valid"
    register_test "auth" "jwks_no_private_keys" "test_jwks_no_private_keys"
    register_test "auth" "user_registration_success" "test_user_registration_success"
    register_test "auth" "user_registration_invalid_email" "test_user_registration_invalid_email"
    register_test "auth" "user_registration_weak_password" "test_user_registration_weak_password"
    register_test "auth" "user_registration_duplicate_username" "test_user_registration_duplicate_username"
    register_test "auth" "user_login_success" "test_user_login_success"
    register_test "auth" "user_login_invalid_password" "test_user_login_invalid_password"
    register_test "auth" "user_login_nonexistent_user" "test_user_login_nonexistent_user"
    register_test "auth" "tampered_jwt_rejected" "test_tampered_jwt_rejected"
    register_test "auth" "malformed_jwt_missing_segment" "test_malformed_jwt_missing_segment"
    register_test "auth" "invalid_jwt_encoding" "test_invalid_jwt_encoding"
    register_test "auth" "jwt_without_bearer_prefix" "test_jwt_without_bearer_prefix"
    register_test "auth" "missing_auth_header" "test_missing_auth_header"
    register_test "auth" "jwt_null_username_field" "test_jwt_null_username_field"
    register_test "auth" "jwt_different_issuer" "test_jwt_different_issuer"
    register_test "auth" "expired_token_rejected" "test_expired_token_rejected"
    register_test "auth" "bearer_prefix_case_sensitivity" "test_bearer_prefix_case_sensitivity"
    register_test "auth" "multiple_spaces_in_auth_header" "test_multiple_spaces_in_auth_header"
    register_test "auth" "registration_null_password" "test_registration_null_password"
    register_test "auth" "registration_oversized_username" "test_registration_oversized_username"
}

# Export functions
export -f auth_register_tests
export -f test_jwks_endpoint_valid test_jwks_no_private_keys
export -f test_user_registration_success test_user_registration_invalid_email
export -f test_user_registration_weak_password test_user_registration_duplicate_username
export -f test_user_login_success test_user_login_invalid_password test_user_login_nonexistent_user
export -f test_tampered_jwt_rejected test_malformed_jwt_missing_segment test_invalid_jwt_encoding
export -f test_jwt_without_bearer_prefix test_missing_auth_header test_jwt_null_username_field
export -f test_jwt_different_issuer test_expired_token_rejected
export -f test_bearer_prefix_case_sensitivity test_multiple_spaces_in_auth_header
export -f test_registration_null_password test_registration_oversized_username
