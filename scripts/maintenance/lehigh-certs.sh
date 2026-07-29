#!/usr/bin/env bash

set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

ERROR_MESSAGE="unexpected error"
STAGED_CERT=""
STAGED_KEY=""

send_slack_message() {
  local payload

  [[ -n "${SLACK_WEBHOOK:-}" ]] || return 1
  payload="$(jq -cn --arg text "$*" '{text: $text}')"

  curl --fail --silent --show-error --output /dev/null \
    --connect-timeout 5 --max-time 15 \
    --header 'Content-Type: application/json' \
    --request POST --data-binary "${payload}" "${SLACK_WEBHOOK}"
}

cleanup() {
  [[ -z "${STAGED_CERT}" ]] || rm -f -- "${STAGED_CERT}"
  [[ -z "${STAGED_KEY}" ]] || rm -f -- "${STAGED_KEY}"
}

handle_error() {
  local exit_code="$1"
  local host
  local message

  trap - ERR
  set +e
  host="$(hostname --fqdn 2>/dev/null || hostname)"
  message="🚨 ${ALERT_CONTEXT:-TLS certificate rollout} failed on ${host}: ${ERROR_MESSAGE} 🚨"

  printf '%s\n' "${message}" >&2
  logger --priority daemon.err --tag local-cert-hook -- "${message}" || true
  send_slack_message "${message}" || \
    printf '%s\n' 'Slack alert could not be sent; check SLACK_WEBHOOK, curl, and jq.' >&2

  exit "${exit_code}"
}

fail() {
  ERROR_MESSAGE="$*"
  return 1
}

trap 'handle_error "$?"' ERR
trap cleanup EXIT

HOOK_CONFIG="${LOCAL_CERT_HOOK_CONFIG:-/etc/default/local-cert-hook}"
if [[ -r "${HOOK_CONFIG}" ]]; then
  # shellcheck disable=SC1090
  source "${HOOK_CONFIG}"
fi

SOURCE_CERT="${SOURCE_CERT:-/etc/ssl/certs/le/lib.lehigh.edu.pem}"
SOURCE_KEY="${SOURCE_KEY:-/etc/ssl/private/le/lib.lehigh.edu.key}"
STACK_DIR="${STACK_DIR:-/opt/linderman}"
CERT_DIR="${CERT_DIR:-${STACK_DIR}/certs}"
TARGET_CERT="${CERT_DIR}/cert.pem"
TARGET_KEY="${CERT_DIR}/privkey.pem"
RESTART_REQUIRED="${CERT_DIR}/.traefik-restart-required"
EXPECTED_HOST="${EXPECTED_HOST:-}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-60}"
ALERT_CONTEXT="${ALERT_CONTEXT:-Linderman TLS certificate rollout}"
COMPOSE_HOST="${COMPOSE_HOST:-$(hostname --short)}"
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-${STACK_DIR}/docker-compose.${COMPOSE_HOST}.yaml}"

COMPOSE=(
  docker compose
  --project-directory "${STACK_DIR}"
  -f "${STACK_DIR}/docker-compose.yaml"
  -f "${COMPOSE_OVERRIDE}"
)
[[ ! -f "${STACK_DIR}/.env" ]] || COMPOSE+=(--env-file "${STACK_DIR}/.env")

compose() {
  "${COMPOSE[@]}" "$@"
}

sha256_file() {
  sha256sum < "$1"
}

validate_certificate() {
  local cert_public_key
  local key_public_key

  [[ "${SLACK_WEBHOOK:-}" == https://* ]] || fail 'SLACK_WEBHOOK is not configured'
  [[ -n "${EXPECTED_HOST}" ]] || fail 'EXPECTED_HOST is not configured'
  [[ -r "${STACK_DIR}/docker-compose.yaml" ]] || \
    fail "Compose file is not readable: ${STACK_DIR}/docker-compose.yaml"
  [[ -r "${COMPOSE_OVERRIDE}" ]] || \
    fail "Compose override is not readable: ${COMPOSE_OVERRIDE}"
  [[ -r "${SOURCE_CERT}" ]] || fail "certificate is not readable: ${SOURCE_CERT}"
  [[ -r "${SOURCE_KEY}" ]] || fail "private key is not readable: ${SOURCE_KEY}"
  [[ "$(grep -cF -- '-----BEGIN CERTIFICATE-----' "${SOURCE_CERT}" || true)" -ge 2 ]] || \
    fail 'certificate does not contain a full chain'

  openssl x509 -in "${SOURCE_CERT}" -noout -checkend 86400 >/dev/null 2>&1 || \
    fail 'certificate is expired or expires within 24 hours'
  openssl x509 -in "${SOURCE_CERT}" -noout -checkhost "${EXPECTED_HOST}" >/dev/null 2>&1 || \
    fail "certificate does not cover ${EXPECTED_HOST}"
  openssl verify -purpose sslserver -untrusted "${SOURCE_CERT}" "${SOURCE_CERT}" >/dev/null 2>&1 || \
    fail 'certificate chain is not trusted for TLS server use'
  openssl pkey -in "${SOURCE_KEY}" -check -noout </dev/null >/dev/null 2>&1 || \
    fail 'private key is invalid or encrypted'

  cert_public_key="$(openssl x509 -in "${SOURCE_CERT}" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)"
  key_public_key="$(openssl pkey -in "${SOURCE_KEY}" -pubout -outform DER </dev/null 2>/dev/null |
    sha256sum)"
  [[ "${cert_public_key}" == "${key_public_key}" ]] || fail 'certificate and private key do not match'
}

secrets_are_current() {
  [[ -f "${TARGET_CERT}" && -f "${TARGET_KEY}" ]] || return 1
  [[ "$(sha256_file "${SOURCE_CERT}")" == "$(sha256_file "${TARGET_CERT}")" ]] || return 1
  [[ "$(sha256_file "${SOURCE_KEY}")" == "$(sha256_file "${TARGET_KEY}")" ]]
}

main() {
  validate_certificate
  install -d -o root -g root -m 0755 "${CERT_DIR}"

  if secrets_are_current && [[ ! -e "${RESTART_REQUIRED}" ]]; then
    printf '%s\n' 'TLS certificate is already current; Traefik was not recreated.'
    return
  fi

  ERROR_MESSAGE='Compose configuration validation failed'
  compose config --quiet

  if ! secrets_are_current; then
    ERROR_MESSAGE='could not copy the renewed TLS certificate'
    install -o root -g root -m 0600 /dev/null "${RESTART_REQUIRED}"
    STAGED_CERT="${TARGET_CERT}.new"
    STAGED_KEY="${TARGET_KEY}.new"
    install -o root -g root -m 0644 "${SOURCE_CERT}" "${STAGED_CERT}"
    install -o root -g root -m 0600 "${SOURCE_KEY}" "${STAGED_KEY}"
    mv -f "${STAGED_KEY}" "${TARGET_KEY}"
    STAGED_KEY=""
    mv -f "${STAGED_CERT}" "${TARGET_CERT}"
    STAGED_CERT=""
  fi

  ERROR_MESSAGE='Traefik failed to restart or become healthy'
  compose up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout "${HEALTHCHECK_TIMEOUT}" traefik

  rm -f -- "${RESTART_REQUIRED}"
  printf '%s\n' 'TLS certificate copied; Traefik is healthy.'
}

main "$@"
