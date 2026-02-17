#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# Caddy Routes Unit Tests
# ══════════════════════════════════════════════════════════════════
#
# Tests the Caddy reverse proxy configuration for homelab routes.
# Requires: curl, jq (optional, for JSON parsing)
#
# Usage:
#   ./tests/test-caddy-routes.sh
#
# Environment variables (set these before running):
#   LAB_DOMAIN          - Lab subdomain (e.g., lab.example.com)
#   DOMAIN              - Root domain (e.g., example.com)
#   TRUENAS_HOST        - TrueNAS IP address
#   HOME_ASSISTANT_HOST - Home Assistant IP address
#
# ══════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── Test Counters ────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

# ── Helper Functions ─────────────────────────────────────────────

log_pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  ((TESTS_PASSED++))
}

log_fail() {
  echo -e "${RED}✗ FAIL${NC}: $1"
  ((TESTS_FAILED++))
}

log_info() {
  echo -e "${YELLOW}ℹ INFO${NC}: $1"
}

# Check if required env vars are set
check_env() {
  local missing=()
  [[ -z "${LAB_DOMAIN:-}" ]] && missing+=("LAB_DOMAIN")
  [[ -z "${DOMAIN:-}" ]] && missing+=("DOMAIN")
  [[ -z "${TRUENAS_HOST:-}" ]] && missing+=("TRUENAS_HOST")
  [[ -z "${HOME_ASSISTANT_HOST:-}" ]] && missing+=("HOME_ASSISTANT_HOST")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR${NC}: Missing required environment variables: ${missing[*]}"
    echo "Please set these before running tests."
    exit 1
  fi
}

# Test that a URL returns expected status code
# Usage: test_status_code "description" "url" expected_code
test_status_code() {
  local desc="$1"
  local url="$2"
  local expected="$3"

  local actual
  actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

  if [[ "$actual" == "$expected" ]]; then
    log_pass "$desc (HTTP $actual)"
  else
    log_fail "$desc (expected HTTP $expected, got HTTP $actual)"
  fi
}

# Test that response contains expected text
# Usage: test_response_contains "description" "url" "expected_text"
test_response_contains() {
  local desc="$1"
  local url="$2"
  local expected="$3"

  local response
  response=$(curl -s --max-time 10 "$url" 2>/dev/null || echo "")

  if [[ "$response" == *"$expected"* ]]; then
    log_pass "$desc"
  else
    log_fail "$desc (response did not contain: $expected)"
  fi
}

# Test that response headers contain expected header
# Usage: test_header_present "description" "url" "header_name" "expected_value"
test_header_present() {
  local desc="$1"
  local url="$2"
  local header_name="$3"
  local expected_value="$4"

  local headers
  headers=$(curl -s -I --max-time 10 "$url" 2>/dev/null || echo "")

  if echo "$headers" | grep -qi "^${header_name}:.*${expected_value}"; then
    log_pass "$desc"
  else
    log_fail "$desc (header ${header_name} not found or value mismatch)"
  fi
}

# Test TLS certificate is valid
# Usage: test_tls_valid "description" "host"
test_tls_valid() {
  local desc="$1"
  local host="$2"

  if curl -s --max-time 10 "https://${host}" -o /dev/null 2>/dev/null; then
    log_pass "$desc"
  else
    log_fail "$desc (TLS handshake failed or certificate invalid)"
  fi
}

# Test reverse proxy target (checks if upstream is reachable via Caddy)
# Usage: test_reverse_proxy "description" "caddy_url" "expected_upstream"
test_reverse_proxy() {
  local desc="$1"
  local caddy_url="$2"
  local expected_upstream="$3"

  # We test that Caddy successfully proxies by checking we get a non-502/503 response
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$caddy_url" 2>/dev/null || echo "000")

  # 502/503 typically means upstream unreachable, 000 means connection failed
  if [[ "$status" != "502" && "$status" != "503" && "$status" != "000" ]]; then
    log_pass "$desc (proxy returned HTTP $status)"
  else
    log_fail "$desc (proxy failed with HTTP $status - upstream $expected_upstream may be unreachable)"
  fi
}

# ══════════════════════════════════════════════════════════════════
# TEST CASES
# ══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Caddy Routes Unit Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

check_env

log_info "Testing with LAB_DOMAIN=${LAB_DOMAIN}, DOMAIN=${DOMAIN}"
log_info "TRUENAS_HOST=${TRUENAS_HOST}, HOME_ASSISTANT_HOST=${HOME_ASSISTANT_HOST}"
echo ""

# ── Test 1: test.${LAB_DOMAIN} responds with expected message ────
echo "── Test: test.${LAB_DOMAIN} ──"
test_response_contains \
  "test.${LAB_DOMAIN} responds with 'Caddy is working on {host}'" \
  "https://test.${LAB_DOMAIN}" \
  "Caddy is working on test.${LAB_DOMAIN}"

test_tls_valid \
  "test.${LAB_DOMAIN} has valid TLS certificate" \
  "test.${LAB_DOMAIN}"

echo ""

# ── Test 2: truenas.${LAB_DOMAIN} ────────────────────────────────
echo "── Test: truenas.${LAB_DOMAIN} ──"
test_tls_valid \
  "truenas.${LAB_DOMAIN} has valid TLS certificate" \
  "truenas.${LAB_DOMAIN}"

test_header_present \
  "truenas.${LAB_DOMAIN} returns X-Content-Type-Options: nosniff" \
  "https://truenas.${LAB_DOMAIN}" \
  "X-Content-Type-Options" \
  "nosniff"

test_header_present \
  "truenas.${LAB_DOMAIN} returns X-Frame-Options: DENY" \
  "https://truenas.${LAB_DOMAIN}" \
  "X-Frame-Options" \
  "DENY"

test_header_present \
  "truenas.${LAB_DOMAIN} returns Referrer-Policy: strict-origin-when-cross-origin" \
  "https://truenas.${LAB_DOMAIN}" \
  "Referrer-Policy" \
  "strict-origin-when-cross-origin"

test_reverse_proxy \
  "truenas.${LAB_DOMAIN} proxies to https://${TRUENAS_HOST}:443" \
  "https://truenas.${LAB_DOMAIN}" \
  "https://${TRUENAS_HOST}:443"

echo ""

# ── Test 3: n8n.${LAB_DOMAIN} ────────────────────────────────────
echo "── Test: n8n.${LAB_DOMAIN} ──"
test_tls_valid \
  "n8n.${LAB_DOMAIN} has valid TLS certificate" \
  "n8n.${LAB_DOMAIN}"

test_header_present \
  "n8n.${LAB_DOMAIN} returns X-Content-Type-Options: nosniff" \
  "https://n8n.${LAB_DOMAIN}" \
  "X-Content-Type-Options" \
  "nosniff"

test_header_present \
  "n8n.${LAB_DOMAIN} returns X-Frame-Options: DENY" \
  "https://n8n.${LAB_DOMAIN}" \
  "X-Frame-Options" \
  "DENY"

test_header_present \
  "n8n.${LAB_DOMAIN} returns Referrer-Policy: strict-origin-when-cross-origin" \
  "https://n8n.${LAB_DOMAIN}" \
  "Referrer-Policy" \
  "strict-origin-when-cross-origin"

test_reverse_proxy \
  "n8n.${LAB_DOMAIN} proxies to https://${TRUENAS_HOST}:30109" \
  "https://n8n.${LAB_DOMAIN}" \
  "https://${TRUENAS_HOST}:30109"

echo ""

# ── Test 4: nc.${DOMAIN} (Nextcloud on root domain) ──────────────
echo "── Test: nc.${DOMAIN} ──"
test_tls_valid \
  "nc.${DOMAIN} has valid TLS certificate" \
  "nc.${DOMAIN}"

test_header_present \
  "nc.${DOMAIN} returns X-Content-Type-Options: nosniff" \
  "https://nc.${DOMAIN}" \
  "X-Content-Type-Options" \
  "nosniff"

test_header_present \
  "nc.${DOMAIN} returns X-Frame-Options: DENY" \
  "https://nc.${DOMAIN}" \
  "X-Frame-Options" \
  "DENY"

test_header_present \
  "nc.${DOMAIN} returns Referrer-Policy: strict-origin-when-cross-origin" \
  "https://nc.${DOMAIN}" \
  "Referrer-Policy" \
  "strict-origin-when-cross-origin"

test_reverse_proxy \
  "nc.${DOMAIN} proxies to https://${TRUENAS_HOST}:30027" \
  "https://nc.${DOMAIN}" \
  "https://${TRUENAS_HOST}:30027"

echo ""

# ── Test 5: ha.${LAB_DOMAIN} (Home Assistant) ────────────────────
echo "── Test: ha.${LAB_DOMAIN} ──"
test_tls_valid \
  "ha.${LAB_DOMAIN} has valid TLS certificate" \
  "ha.${LAB_DOMAIN}"

test_reverse_proxy \
  "ha.${LAB_DOMAIN} proxies to http://${HOME_ASSISTANT_HOST}:8123" \
  "https://ha.${LAB_DOMAIN}" \
  "http://${HOME_ASSISTANT_HOST}:8123"

echo ""

# ══════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════"
echo " Test Summary"
echo "═══════════════════════════════════════════════════════════════"
echo -e " ${GREEN}Passed${NC}: ${TESTS_PASSED}"
echo -e " ${RED}Failed${NC}: ${TESTS_FAILED}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi

exit 0
