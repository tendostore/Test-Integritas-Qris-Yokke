#!/usr/bin/env bash
###############################################################################
# install.sh - QRIS SNAP MPM Integration Test Toolkit Installer
#
# Script ini menginstall DUA cara pakai untuk pengujian integrasi API QRIS
# SNAP MPM (Access Token, QR Generate, QR Query, QR Cancel) sesuai Postman
# Collection "Sandbox QRIS MPM":
#
#   1. qris-test.sh   -> tool CLI interaktif (terminal), seperti sebelumnya.
#   2. Web Panel       -> dashboard berbasis browser (Node.js/Express),
#                         bisa diakses lewat http://<IP-VPS>:<PORT>.
#
# Konfigurasi (client key, partner id, merchant id, signature, dst) BISA
# DIISI lewat menu CLI "Ubah Konfigurasi" ATAU lewat tab "Konfigurasi" di
# Web Panel - CLI dan Web Panel saling menyinkronkan config.env <-> config.json
# secara otomatis setiap kali salah satu sisi menyimpan konfigurasi.
#
# Cara pakai:
#   chmod +x install.sh
#   ./install.sh
#   CLI   : cd ~/qris-snap-test && ./qris-test.sh
#   Web   : buka http://<IP-VPS-ANDA>:<PORT> (default PORT 7080)
###############################################################################

set -euo pipefail

INSTALL_DIR="${QRIS_TEST_DIR:-$HOME/qris-snap-test}"
LOG_DIR="$INSTALL_DIR/logs"
KEYS_DIR="$INSTALL_DIR/keys"
WEB_DIR="$INSTALL_DIR/web"
CONFIG_FILE="$INSTALL_DIR/config.env"
CONFIG_JSON="$INSTALL_DIR/config.json"
AUTH_JSON="$INSTALL_DIR/auth.json"
MAIN_SCRIPT="$INSTALL_DIR/qris-test.sh"

echo "=============================================="
echo " Installer: QRIS SNAP MPM Integration Test Toolkit"
echo " (CLI + Web Panel)"
echo "=============================================="
echo "Target instalasi : $INSTALL_DIR"
echo

# -----------------------------------------------------------------------------
# 1. Cek & install dependency (curl, jq, openssl, node, npm)
# -----------------------------------------------------------------------------
check_deps() {
  local missing=()
  for bin in curl jq openssl; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "Dependency belum lengkap: ${missing[*]}"
    if command -v apt-get >/dev/null 2>&1; then
      echo "Mencoba install otomatis lewat apt-get..."
      apt-get update -y
      apt-get install -y "${missing[@]}"
    else
      echo "Mohon install manual paket berikut sebelum lanjut: ${missing[*]}"
      exit 1
    fi
  fi
  echo "Dependency OK: curl, jq, openssl tersedia."

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Node.js/npm belum terpasang (dibutuhkan untuk Web Panel)."
    if command -v apt-get >/dev/null 2>&1; then
      echo "Mencoba install Node.js + npm otomatis lewat apt-get..."
      apt-get update -y
      apt-get install -y nodejs npm
    else
      echo "Mohon install Node.js (>=14) dan npm secara manual, lalu jalankan ulang script ini."
      exit 1
    fi
  fi
  echo "Node.js: $(node -v 2>/dev/null || echo 'tidak terdeteksi'), npm: $(npm -v 2>/dev/null || echo 'tidak terdeteksi')"
}
check_deps

# -----------------------------------------------------------------------------
# 2. Siapkan direktori
# -----------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$KEYS_DIR" "$WEB_DIR/public"

# -----------------------------------------------------------------------------
# 3. Tulis config.env (untuk CLI - tetap dipertahankan, hanya dibuat jika
#    BELUM ada supaya re-run tidak menimpa konfigurasi yang sudah diisi).
# -----------------------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<'CONFIG_EOF'
# =============================================================
# Konfigurasi QRIS SNAP MPM Test CLI
# Silakan isi/ubah nilai di bawah ini, atau lewat menu
# "Ubah Konfigurasi" pada qris-test.sh
# =============================================================
BASE_URL="https://tst.yokke.co.id:8280"
API_VERSION="1.0.11"

# --- Kredensial / identitas client ---
CLIENT_KEY=""
CLIENT_SECRET=""
PRIVATE_KEY_PATH=""
PARTNER_ID=""
CHANNEL_ID="02"
EXTERNAL_ID="866330434635474"
PLATFORM="PORTAL"

# --- Data merchant default (bisa diubah tiap request) ---
MERCHANT_ID="00007100010926"
TERMINAL_ID="72001126"

# --- Token ---
AUTH_BEARER=""
ACCESS_TOKEN=""

# --- Mode signature: manual (paste sendiri) atau auto (generate via openssl) ---
SIGNATURE_MODE="manual"

# --- Data hasil transaksi terakhir (otomatis terisi setelah Generate) ---
LAST_PARTNER_REF=""
LAST_REFERENCE_NO=""
LAST_EXTERNAL_ID_GEN=""
LAST_TRX_DATE=""
LAST_APPROVAL_CODE=""
LAST_AMOUNT=""
CONFIG_EOF
  echo "Membuat config.env default di: $CONFIG_FILE"
else
  echo "config.env sudah ada, tidak ditimpa: $CONFIG_FILE"
fi

# -----------------------------------------------------------------------------
# 4. Tulis qris-test.sh (tool CLI utama) - tidak berubah dari versi sebelumnya
# -----------------------------------------------------------------------------
cat > "$MAIN_SCRIPT" << 'SCRIPT_EOF'
#!/usr/bin/env bash
###############################################################################
# qris-test.sh - QRIS SNAP MPM Integration Test CLI
# Menu interaktif untuk testing: Access Token, QR-MPM-Generate,
# QR-MPM-Query, QR-MPM-Cancel.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
LOG_DIR="$SCRIPT_DIR/logs"
KEYS_DIR="$SCRIPT_DIR/keys"
mkdir -p "$LOG_DIR" "$KEYS_DIR"

# ---------------- Warna ----------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'

# ---------------- Config ----------------
# FIX: CLI (config.env) dan Web Panel (config.json) dulu hanya disinkronkan
# SEKALI saat install, lalu masing-masing berjalan sendiri-sendiri sehingga
# perubahan di salah satu sisi tidak pernah terlihat di sisi lain. Sekarang
# load_config()/save_config() saling sinkron dua arah berdasarkan file mana
# yang paling baru diubah (mtime).
CONFIG_JSON_FILE="$SCRIPT_DIR/config.json"

load_config() {
  # shellcheck disable=SC1090
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
  sync_from_json_if_newer
}

# Jika config.json (ditulis Web Panel) lebih baru daripada config.env (atau
# config.env belum ada), tarik nilainya ke variabel CLI lalu tulis ulang
# config.env supaya konsisten.
sync_from_json_if_newer() {
  [ -f "$CONFIG_JSON_FILE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  if [ -f "$CONFIG_FILE" ] && [ "$CONFIG_FILE" -nt "$CONFIG_JSON_FILE" ]; then
    return 0
  fi

  local j
  j=$(cat "$CONFIG_JSON_FILE" 2>/dev/null) || return 0
  jq -e . >/dev/null 2>&1 <<<"$j" || return 0

  BASE_URL=$(jq -r '.baseUrl // ""' <<<"$j")
  API_VERSION=$(jq -r '.apiVersion // "1.0.11"' <<<"$j")
  CLIENT_KEY=$(jq -r '.clientKey // ""' <<<"$j")
  CLIENT_SECRET=$(jq -r '.clientSecret // ""' <<<"$j")
  PRIVATE_KEY_PATH=$(jq -r '.privateKeyPath // ""' <<<"$j")
  PARTNER_ID=$(jq -r '.partnerId // ""' <<<"$j")
  CHANNEL_ID=$(jq -r '.channelId // "02"' <<<"$j")
  EXTERNAL_ID=$(jq -r '.externalId // ""' <<<"$j")
  PLATFORM=$(jq -r '.platform // "PORTAL"' <<<"$j")
  MERCHANT_ID=$(jq -r '.merchantId // ""' <<<"$j")
  TERMINAL_ID=$(jq -r '.terminalId // ""' <<<"$j")
  AUTH_BEARER=$(jq -r '.authBearer // ""' <<<"$j")
  ACCESS_TOKEN=$(jq -r '.accessToken // ""' <<<"$j")
  SIGNATURE_MODE=$(jq -r '.signatureMode // "manual"' <<<"$j")
  LAST_PARTNER_REF=$(jq -r '.lastPartnerRef // ""' <<<"$j")
  LAST_REFERENCE_NO=$(jq -r '.lastReferenceNo // ""' <<<"$j")
  LAST_EXTERNAL_ID_GEN=$(jq -r '.lastExternalIdGen // ""' <<<"$j")
  LAST_TRX_DATE=$(jq -r '.lastTrxDate // ""' <<<"$j")
  LAST_APPROVAL_CODE=$(jq -r '.lastApprovalCode // ""' <<<"$j")
  LAST_AMOUNT=$(jq -r '.lastAmount // ""' <<<"$j")

  write_config_env
  echo -e "${C_YELLOW}[INFO]${C_RESET} Konfigurasi disinkronkan dari config.json (Web Panel)."
}

# Menulis config.env dari variabel saat ini (tanpa ikut menyinkronkan ke json).
write_config_env() {
  cat > "$CONFIG_FILE" <<EOF
BASE_URL="${BASE_URL:-}"
API_VERSION="${API_VERSION:-}"
CLIENT_KEY="${CLIENT_KEY:-}"
CLIENT_SECRET="${CLIENT_SECRET:-}"
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-}"
PARTNER_ID="${PARTNER_ID:-}"
CHANNEL_ID="${CHANNEL_ID:-}"
EXTERNAL_ID="${EXTERNAL_ID:-}"
PLATFORM="${PLATFORM:-}"
MERCHANT_ID="${MERCHANT_ID:-}"
TERMINAL_ID="${TERMINAL_ID:-}"
AUTH_BEARER="${AUTH_BEARER:-}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
SIGNATURE_MODE="${SIGNATURE_MODE:-manual}"
LAST_PARTNER_REF="${LAST_PARTNER_REF:-}"
LAST_REFERENCE_NO="${LAST_REFERENCE_NO:-}"
LAST_EXTERNAL_ID_GEN="${LAST_EXTERNAL_ID_GEN:-}"
LAST_TRX_DATE="${LAST_TRX_DATE:-}"
LAST_APPROVAL_CODE="${LAST_APPROVAL_CODE:-}"
LAST_AMOUNT="${LAST_AMOUNT:-}"
EOF
}

# Menulis config.env, lalu menulis balik ke config.json supaya Web Panel
# ikut melihat perubahan yang dibuat lewat CLI.
save_config() {
  write_config_env
  sync_to_json
}

sync_to_json() {
  command -v jq >/dev/null 2>&1 || return 0
  local base='{}'
  if [ -f "$CONFIG_JSON_FILE" ]; then
    base=$(cat "$CONFIG_JSON_FILE" 2>/dev/null)
    jq -e . >/dev/null 2>&1 <<<"$base" || base='{}'
  fi
  jq \
    --arg baseUrl "${BASE_URL:-}" \
    --arg apiVersion "${API_VERSION:-}" \
    --arg clientKey "${CLIENT_KEY:-}" \
    --arg clientSecret "${CLIENT_SECRET:-}" \
    --arg privateKeyPath "${PRIVATE_KEY_PATH:-}" \
    --arg partnerId "${PARTNER_ID:-}" \
    --arg channelId "${CHANNEL_ID:-}" \
    --arg externalId "${EXTERNAL_ID:-}" \
    --arg platform "${PLATFORM:-}" \
    --arg merchantId "${MERCHANT_ID:-}" \
    --arg terminalId "${TERMINAL_ID:-}" \
    --arg authBearer "${AUTH_BEARER:-}" \
    --arg accessToken "${ACCESS_TOKEN:-}" \
    --arg signatureMode "${SIGNATURE_MODE:-manual}" \
    --arg lastPartnerRef "${LAST_PARTNER_REF:-}" \
    --arg lastReferenceNo "${LAST_REFERENCE_NO:-}" \
    --arg lastExternalIdGen "${LAST_EXTERNAL_ID_GEN:-}" \
    --arg lastTrxDate "${LAST_TRX_DATE:-}" \
    --arg lastApprovalCode "${LAST_APPROVAL_CODE:-}" \
    --arg lastAmount "${LAST_AMOUNT:-}" \
    '. as $base | $base
      | .baseUrl=$baseUrl | .apiVersion=$apiVersion | .clientKey=$clientKey | .clientSecret=$clientSecret
      | .privateKeyPath=$privateKeyPath | .partnerId=$partnerId | .channelId=$channelId | .externalId=$externalId
      | .platform=$platform | .merchantId=$merchantId | .terminalId=$terminalId | .authBearer=$authBearer
      | .accessToken=$accessToken | .signatureMode=$signatureMode | .lastPartnerRef=$lastPartnerRef
      | .lastReferenceNo=$lastReferenceNo | .lastExternalIdGen=$lastExternalIdGen | .lastTrxDate=$lastTrxDate
      | .lastApprovalCode=$lastApprovalCode | .lastAmount=$lastAmount' \
    <<<"$base" > "$CONFIG_JSON_FILE.tmp" 2>/dev/null && mv "$CONFIG_JSON_FILE.tmp" "$CONFIG_JSON_FILE"
}

# ---------------- Helper ----------------
ask() {
  local prompt="$1" default="$2" varname="$3" input
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " input
  else
    read -r -p "$prompt: " input
  fi
  if [ -z "$input" ]; then
    printf -v "$varname" '%s' "$default"
  else
    printf -v "$varname" '%s' "$input"
  fi
}

pause() { read -r -p "Tekan ENTER untuk lanjut..." _; }

print_header() { echo -e "\n${C_BOLD}${C_CYAN}== $1 ==${C_RESET}\n"; }

print_banner() {
  echo -e "${C_BOLD}${C_CYAN}========================================"
  echo "   QRIS SNAP MPM - INTEGRATION TEST CLI"
  echo -e "========================================${C_RESET}"
  echo "Base URL      : ${BASE_URL:-belum diset}"
  echo "Partner ID    : ${PARTNER_ID:-belum diset}"
  echo "Merchant ID   : ${MERCHANT_ID:-belum diset}"
  echo "Access Token  : $( [ -n "${ACCESS_TOKEN:-}" ] && echo 'tersimpan' || echo 'belum ada' )"
  echo "Signature Mode: ${SIGNATURE_MODE:-manual}"
  echo
}

timestamp_now() { TZ=Asia/Jakarta date +"%Y-%m-%dT%H:%M:%S%:z"; }

# ---------------- Signature ----------------
# Asymmetric (untuk Access Token): SHA256withRSA atas "CLIENT_KEY|TIMESTAMP"
sig_asymmetric() {
  local client_key="$1" ts="$2" string_to_sign
  string_to_sign="${client_key}|${ts}"
  if [ -z "${PRIVATE_KEY_PATH:-}" ] || [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo ""; return 1
  fi
  printf '%s' "$string_to_sign" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" 2>/dev/null | base64 -w0
}

# Symmetric (untuk service API): HMAC-SHA512 atas
# "METHOD:RELATIVE_URL:ACCESS_TOKEN:lowerhex(sha256(minify(body))):TIMESTAMP"
sig_symmetric() {
  local method="$1" relative_url="$2" access_token="$3" body="$4" ts="$5"
  local minified body_hash string_to_sign
  if [ -z "${CLIENT_SECRET:-}" ]; then
    echo ""; return 1
  fi
  minified=$(printf '%s' "$body" | jq -c '.' 2>/dev/null)
  [ -z "$minified" ] && minified="$body"
  body_hash=$(printf '%s' "$minified" | openssl dgst -sha256 | awk '{print $2}')
  string_to_sign="${method}:${relative_url}:${access_token}:${body_hash}:${ts}"
  printf '%s' "$string_to_sign" | openssl dgst -sha512 -hmac "$CLIENT_SECRET" -binary | base64 -w0
}

# Wrapper: pakai mode auto (openssl) atau manual (paste sendiri)
get_signature() {
  local kind="$1"; shift
  local computed=""
  if [ "${SIGNATURE_MODE:-manual}" = "auto" ]; then
    case "$kind" in
      asymmetric) computed=$(sig_asymmetric "$@") ;;
      symmetric)  computed=$(sig_symmetric "$@") ;;
    esac
  fi
  if [ -n "$computed" ]; then
    echo "$computed"
    return
  fi
  local manual DEFAULT_SIG="C94w/a2rvKcJn2EZ6wkuWaEc9SGiQLWYcUjqp70lWGTP4jNQ3bUw4FkdHyCGJwlPVvcLNShkGPr/AjHVJpQAHQ=="
  read -r -p "Masukkan X-Signature secara manual [$DEFAULT_SIG]: " manual >&2
  [ -z "$manual" ] && manual="$DEFAULT_SIG"
  echo "$manual"
}

# ---------------- Logging ----------------
log_result() {
  local name="$1" http_code="$2" req="$3" resp="$4" file
  file="$LOG_DIR/$(date +%Y%m%d-%H%M%S)_$(echo "$name" | tr ' ' '_').log"
  {
    echo "==== $name ===="
    echo "Waktu       : $(date -Iseconds)"
    echo "HTTP Code   : $http_code"
    echo "---- Request Body ----"
    echo "$req"
    echo "---- Response Body ----"
    echo "$resp"
  } > "$file"
  echo "$file"
}

print_status() {
  local http_code="$1" resp="$2" resp_code
  resp_code=$(echo "$resp" | jq -r '.responseCode // empty' 2>/dev/null)
  if [[ "$http_code" =~ ^2 ]]; then
    echo -e "${C_GREEN}[PASS]${C_RESET} HTTP $http_code  responseCode=${resp_code:-N/A}"
  else
    echo -e "${C_RED}[FAIL]${C_RESET} HTTP $http_code  responseCode=${resp_code:-N/A}"
  fi
}

# ---------------- Endpoint: GET ACCESS TOKEN ----------------
do_access_token() {
  print_header "GET ACCESS TOKEN"
  ask "Base URL" "${BASE_URL:-}" BASE_URL
  ask "API Version" "${API_VERSION:-}" API_VERSION
  ask "X-Client-Key" "${CLIENT_KEY:-}" CLIENT_KEY
  ask "Authorization Bearer (token/secret)" "${AUTH_BEARER:-}" AUTH_BEARER
  ask "X-Platform (kosongkan jika tidak dipakai)" "${PLATFORM:-PORTAL}" PLATFORM

  local relative_url="/qrissnapmpm/${API_VERSION}/qr/v2.0/access-token/b2b"
  local url="${BASE_URL}${relative_url}"
  local ts body sig
  ts=$(timestamp_now)
  body='{"grantType":"client_credentials"}'

  echo -e "${C_CYAN}Timestamp:${C_RESET} $ts"
  sig=$(get_signature asymmetric "$CLIENT_KEY" "$ts")

  local -a headers=(
    -H "Authorization: Bearer ${AUTH_BEARER}"
    -H "Content-Type: application/json"
    -H "X-Client-Key: ${CLIENT_KEY}"
    -H "X-Signature: ${sig}"
    -H "X-Timestamp: ${ts}"
  )
  [ -n "${PLATFORM:-}" ] && headers+=(-H "X-Platform: ${PLATFORM}")

  echo -e "${C_YELLOW}Mengirim request ke${C_RESET} $url"
  local response http_code body_resp
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" "${headers[@]}" -d "$body")
  http_code=$(echo "$response" | tail -n1)
  body_resp=$(echo "$response" | sed '$d')

  echo "$body_resp" | jq '.' 2>/dev/null || echo "$body_resp"
  print_status "$http_code" "$body_resp"

  local token
  token=$(echo "$body_resp" | jq -r '.accessToken // empty' 2>/dev/null)
  if [ -n "$token" ]; then
    ACCESS_TOKEN="$token"
    echo -e "${C_GREEN}Access token tersimpan untuk request berikutnya.${C_RESET}"
  fi

  log_result "GET_ACCESS_TOKEN" "$http_code" "$body" "$body_resp" >/dev/null
  save_config
  pause
}

# ---------------- Endpoint: QR-MPM-GENERATE ----------------
do_generate() {
  print_header "QR-MPM-GENERATE"
  ask "Base URL" "${BASE_URL:-}" BASE_URL
  ask "API Version" "${API_VERSION:-}" API_VERSION
  ask "Access Token" "${ACCESS_TOKEN:-}" ACCESS_TOKEN
  ask "Channel-Id" "${CHANNEL_ID:-02}" CHANNEL_ID
  ask "X-External-Id" "${EXTERNAL_ID:-}" EXTERNAL_ID
  ask "X-Partner-Id" "${PARTNER_ID:-}" PARTNER_ID
  ask "Merchant ID" "${MERCHANT_ID:-}" MERCHANT_ID
  ask "Terminal ID" "${TERMINAL_ID:-}" TERMINAL_ID
  ask "Partner Reference No" "230218123798000" PARTNER_REF_NO
  ask "Amount value" "10000.00" AMOUNT_VALUE
  ask "Fee Amount value" "10000.00" FEE_VALUE
  ask "Currency" "IDR" CURRENCY

  local relative_url="/qrissnapmpm/${API_VERSION}/v2.0/qr/qr-mpm-generate"
  local url="${BASE_URL}${relative_url}"
  local ts body sig
  ts=$(timestamp_now)
  body=$(jq -n \
    --arg mid "$MERCHANT_ID" --arg tid "$TERMINAL_ID" --arg pref "$PARTNER_REF_NO" \
    --arg amt "$AMOUNT_VALUE" --arg fee "$FEE_VALUE" --arg cur "$CURRENCY" \
    '{merchantId:$mid, terminalId:$tid, partnerReferenceNo:$pref,
      amount:{value:$amt, currency:$cur}, feeAmount:{value:$fee, currency:$cur}}')

  echo -e "${C_CYAN}Timestamp:${C_RESET} $ts"
  sig=$(get_signature symmetric POST "$relative_url" "$ACCESS_TOKEN" "$body" "$ts")

  local -a headers=(
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Channel-Id: ${CHANNEL_ID}"
    -H "Content-Type: application/json"
    -H "X-External-Id: ${EXTERNAL_ID}"
    -H "X-Partner-Id: ${PARTNER_ID}"
    -H "X-Signature: ${sig}"
    -H "X-Timestamp: ${ts}"
  )
  [ -n "${PLATFORM:-}" ] && headers+=(-H "X-Platform: ${PLATFORM}")

  echo -e "${C_YELLOW}Mengirim request ke${C_RESET} $url"
  echo -e "${C_CYAN}Request Body:${C_RESET}"; echo "$body" | jq '.'

  local response http_code body_resp
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" "${headers[@]}" -d "$body")
  http_code=$(echo "$response" | tail -n1)
  body_resp=$(echo "$response" | sed '$d')

  echo "$body_resp" | jq '.' 2>/dev/null || echo "$body_resp"
  print_status "$http_code" "$body_resp"

  LAST_PARTNER_REF="$PARTNER_REF_NO"
  LAST_REFERENCE_NO=$(echo "$body_resp" | jq -r '.referenceNo // empty' 2>/dev/null)
  # FIX: originalExternalId untuk Query/Cancel harus = X-External-Id yang dipakai
  # saat Generate (nilai header), BUKAN referenceNo dari response Generate.
  # Sandbox Yokke memvalidasi originalExternalId = externalId header saat Generate.
  LAST_EXTERNAL_ID_GEN="$EXTERNAL_ID"
  LAST_TRX_DATE=$(date +%Y%m%d)
  LAST_AMOUNT="$AMOUNT_VALUE"

  if [ -n "$LAST_REFERENCE_NO" ]; then
    echo -e "${C_GREEN}referenceNo disimpan untuk Query/Cancel: $LAST_REFERENCE_NO${C_RESET}"
    echo -e "${C_GREEN}originalExternalId (Query/Cancel) : $LAST_EXTERNAL_ID_GEN${C_RESET}"
  fi

  log_result "QR_MPM_GENERATE" "$http_code" "$body" "$body_resp" >/dev/null
  save_config
  pause
}

# ---------------- Endpoint: QR-MPM-QUERY ----------------
do_query() {
  print_header "QR-MPM-QUERY"
  ask "Base URL" "${BASE_URL:-}" BASE_URL
  ask "API Version" "${API_VERSION:-}" API_VERSION
  ask "Access Token" "${ACCESS_TOKEN:-}" ACCESS_TOKEN
  ask "Channel-Id" "${CHANNEL_ID:-02}" CHANNEL_ID
  ask "X-External-Id" "${EXTERNAL_ID:-}" EXTERNAL_ID
  ask "X-Partner-Id" "${PARTNER_ID:-}" PARTNER_ID
  ask "Merchant ID" "${MERCHANT_ID:-}" MERCHANT_ID
  ask "Terminal ID" "${TERMINAL_ID:-}" TERMINAL_ID
  ask "Original Reference No" "${LAST_REFERENCE_NO:-908718002198}" ORIG_REF_NO
  ask "Original External Id" "${LAST_EXTERNAL_ID_GEN:-}" ORIG_EXTERNAL_ID
  ask "Service Code" "51" SERVICE_CODE
  ask "Original Transaction Date (YYYYMMDD)" "${LAST_TRX_DATE:-}" ORIG_TRX_DATE

  local relative_url="/qrissnapmpm/${API_VERSION}/v2.0/qr/qr-mpm-query"
  local url="${BASE_URL}${relative_url}"
  local ts body sig
  ts=$(timestamp_now)
  body=$(jq -n \
    --arg ref "$ORIG_REF_NO" --arg extid "$ORIG_EXTERNAL_ID" --arg svc "$SERVICE_CODE" \
    --arg mid "$MERCHANT_ID" --arg trxdate "$ORIG_TRX_DATE" --arg tid "$TERMINAL_ID" \
    '{originalReferenceNo:$ref, originalExternalId:$extid, serviceCode:$svc, merchantId:$mid,
      additionalInfo:{originalTransactionDate:$trxdate, terminalId:$tid}}')

  echo -e "${C_CYAN}Timestamp:${C_RESET} $ts"
  sig=$(get_signature symmetric POST "$relative_url" "$ACCESS_TOKEN" "$body" "$ts")

  local -a headers=(
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Channel-Id: ${CHANNEL_ID}"
    -H "Content-Type: application/json"
    -H "X-External-Id: ${EXTERNAL_ID}"
    -H "X-Partner-Id: ${PARTNER_ID}"
    -H "X-Signature: ${sig}"
    -H "X-Timestamp: ${ts}"
  )
  [ -n "${PLATFORM:-}" ] && headers+=(-H "X-Platform: ${PLATFORM}")

  echo -e "${C_YELLOW}Mengirim request ke${C_RESET} $url"
  echo -e "${C_CYAN}Request Body:${C_RESET}"; echo "$body" | jq '.'

  local response http_code body_resp
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" "${headers[@]}" -d "$body")
  http_code=$(echo "$response" | tail -n1)
  body_resp=$(echo "$response" | sed '$d')

  echo "$body_resp" | jq '.' 2>/dev/null || echo "$body_resp"
  print_status "$http_code" "$body_resp"

  log_result "QR_MPM_QUERY" "$http_code" "$body" "$body_resp" >/dev/null
  save_config
  pause
}

# ---------------- Endpoint: QR-MPM-CANCEL ----------------
do_cancel() {
  print_header "QR-MPM-CANCEL"
  ask "Base URL" "${BASE_URL:-}" BASE_URL
  ask "API Version" "${API_VERSION:-}" API_VERSION
  ask "Access Token" "${ACCESS_TOKEN:-}" ACCESS_TOKEN
  ask "Channel-Id" "${CHANNEL_ID:-02}" CHANNEL_ID
  ask "X-External-Id" "${EXTERNAL_ID:-}" EXTERNAL_ID
  ask "X-Partner-Id" "${PARTNER_ID:-}" PARTNER_ID
  ask "Merchant ID" "${MERCHANT_ID:-}" MERCHANT_ID
  ask "Terminal ID" "${TERMINAL_ID:-}" TERMINAL_ID
  ask "Original Reference No" "${LAST_REFERENCE_NO:-955975998009}" ORIG_REF_NO
  ask "Original Partner Reference No" "${LAST_PARTNER_REF:-230218123798000}" ORIG_PARTNER_REF
  ask "Original External Id" "${LAST_EXTERNAL_ID_GEN:-955975998009001}" ORIG_EXTERNAL_ID
  ask "Reason" "Customer" REASON
  ask "Refund Amount value" "${LAST_AMOUNT:-10000.00}" REFUND_VALUE
  ask "Currency" "IDR" CURRENCY
  ask "Original Transaction Date (YYYYMMDD)" "${LAST_TRX_DATE:-}" ORIG_TRX_DATE
  ask "Original Approval Code" "${LAST_APPROVAL_CODE:-142403}" ORIG_APPROVAL_CODE

  local relative_url="/qrissnapmpm/${API_VERSION}/v2.0/qr/qr-mpm-cancel"
  local url="${BASE_URL}${relative_url}"
  local ts body sig
  ts=$(timestamp_now)
  body=$(jq -n \
    --arg ref "$ORIG_REF_NO" --arg pref "$ORIG_PARTNER_REF" --arg extid "$ORIG_EXTERNAL_ID" \
    --arg mid "$MERCHANT_ID" --arg reason "$REASON" --arg val "$REFUND_VALUE" --arg cur "$CURRENCY" \
    --arg trxdate "$ORIG_TRX_DATE" --arg tid "$TERMINAL_ID" --arg appr "$ORIG_APPROVAL_CODE" \
    '{originalReferenceNo:$ref, originalPartnerReferenceNo:$pref, originalExternalId:$extid,
      merchantId:$mid, reason:$reason, refundAmount:{value:$val, currency:$cur},
      additionalInfo:{originalTransactionDate:$trxdate, terminalId:$tid, originalApprovalCode:$appr}}')

  echo -e "${C_CYAN}Timestamp:${C_RESET} $ts"
  sig=$(get_signature symmetric POST "$relative_url" "$ACCESS_TOKEN" "$body" "$ts")

  local -a headers=(
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
    -H "Channel-Id: ${CHANNEL_ID}"
    -H "Content-Type: application/json"
    -H "X-External-Id: ${EXTERNAL_ID}"
    -H "X-Partner-Id: ${PARTNER_ID}"
    -H "X-Signature: ${sig}"
    -H "X-Timestamp: ${ts}"
  )
  [ -n "${PLATFORM:-}" ] && headers+=(-H "X-Platform: ${PLATFORM}")

  echo -e "${C_YELLOW}Mengirim request ke${C_RESET} $url"
  echo -e "${C_CYAN}Request Body:${C_RESET}"; echo "$body" | jq '.'

  local response http_code body_resp
  response=$(curl -s -w "\n%{http_code}" -X POST "$url" "${headers[@]}" -d "$body")
  http_code=$(echo "$response" | tail -n1)
  body_resp=$(echo "$response" | sed '$d')

  echo "$body_resp" | jq '.' 2>/dev/null || echo "$body_resp"
  print_status "$http_code" "$body_resp"

  LAST_APPROVAL_CODE="$ORIG_APPROVAL_CODE"

  log_result "QR_MPM_CANCEL" "$http_code" "$body" "$body_resp" >/dev/null
  save_config
  pause
}

# ---------------- Full Flow ----------------
do_full_flow() {
  print_header "FULL FLOW TEST: GENERATE -> QUERY -> CANCEL"
  # FIX: X-External-Id unik berbasis timestamp agar sandbox dapat membedakan
  # tiap transaksi baru dan tidak tolak dengan "duplicate externalId".
  # partnerReferenceNo TIDAK di-random karena sandbox Yokke hanya menerima
  # nilai yang sudah terdaftar di test case mereka.
  EXTERNAL_ID="$(date +%s%3N | cut -c1-15)"
  do_generate
  if [ -z "${LAST_REFERENCE_NO:-}" ]; then
    echo -e "${C_RED}Generate tidak menghasilkan referenceNo, flow dihentikan.${C_RESET}"
    pause
    return
  fi
  do_query
  do_cancel
  echo -e "${C_GREEN}Full flow test selesai. Cek folder logs/ untuk detail tiap step.${C_RESET}"
  pause
}

# ---------------- Lihat Log ----------------
view_logs() {
  print_header "RIWAYAT LOG TEST"
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$LOG_DIR" 2>/dev/null | head -30)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "Belum ada log."
    pause
    return
  fi

  local i=1
  for f in "${files[@]}"; do
    echo "$i) $f"
    i=$((i+1))
  done
  read -r -p "Pilih nomor untuk lihat detail (ENTER untuk batal): " pick
  if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#files[@]}" ]; then
    echo
    cat "$LOG_DIR/${files[$((pick-1))]}"
    echo
  fi
  pause
}

# ---------------- Bersihkan Log ----------------
clear_logs() {
  print_header "BERSIHKAN SEMUA LOG"
  local count
  count=$(ls -1 "$LOG_DIR"/*.log 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    echo "Tidak ada file log untuk dihapus."
    pause
    return
  fi
  echo -e "${C_YELLOW}Ditemukan $count file log di: $LOG_DIR${C_RESET}"
  read -r -p "Hapus semua log? Tindakan ini tidak dapat dibatalkan. [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -f "$LOG_DIR"/*.log
    echo -e "${C_GREEN}Semua log berhasil dihapus.${C_RESET}"
  else
    echo "Dibatalkan."
  fi
  pause
}

# ---------------- Kelola SSL & Domain ----------------
do_ssl_domain() {
  print_header "KELOLA SSL & DOMAIN (Nginx + Let's Encrypt)"

  # Cek apakah berjalan sebagai root
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}ERROR: Menu ini membutuhkan hak akses root (sudo).${C_RESET}"
    echo "Jalankan ulang dengan: sudo ./qris-test.sh"
    pause; return
  fi

  # Baca port dari file .port jika ada
  WEB_PORT="7080"
  [ -f "$SCRIPT_DIR/web/.port" ] && WEB_PORT="$(cat "$SCRIPT_DIR/web/.port")"

  echo "Port Web Panel saat ini : $WEB_PORT"
  echo
  echo " a) Pasang SSL baru (domain baru, install Nginx + Certbot + HTTPS)"
  echo " b) Perbarui/renew sertifikat SSL"
  echo " c) Lihat status sertifikat SSL aktif"
  echo " d) Hapus konfigurasi Nginx domain ini"
  echo " 0) Kembali ke menu utama"
  echo
  read -r -p "Pilih sub-menu: " ssl_choice

  case "$ssl_choice" in
    a|A)
      _ssl_install_new "$WEB_PORT"
      ;;
    b|B)
      echo -e "${C_CYAN}Memperbarui semua sertifikat SSL...${C_RESET}"
      certbot renew --quiet
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
      echo -e "${C_GREEN}Sertifikat diperbarui (jika ada yang hampir kedaluwarsa).${C_RESET}"
      pause
      ;;
    c|C)
      echo -e "${C_CYAN}Status sertifikat SSL:${C_RESET}"
      certbot certificates 2>/dev/null || echo "Certbot tidak terpasang atau tidak ada sertifikat."
      pause
      ;;
    d|D)
      read -r -p "Masukkan nama domain yang ingin dihapus konfigurasinya: " del_domain
      if [ -z "$del_domain" ]; then echo "Dibatalkan."; pause; return; fi
      local nginx_conf="/etc/nginx/sites-enabled/$del_domain"
      local nginx_avail="/etc/nginx/sites-available/$del_domain"
      [ -f "$nginx_conf" ]   && rm -f "$nginx_conf"   && echo "Dihapus: $nginx_conf"
      [ -f "$nginx_avail" ]  && rm -f "$nginx_avail"  && echo "Dihapus: $nginx_avail"
      systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
      echo -e "${C_GREEN}Konfigurasi Nginx untuk $del_domain dihapus.${C_RESET}"
      pause
      ;;
    0) return ;;
    *) echo "Pilihan tidak valid"; sleep 1 ;;
  esac
}

_ssl_install_new() {
  local web_port="${1:-7080}"

  # --- Install Nginx jika belum ada ---
  if ! command -v nginx >/dev/null 2>&1; then
    echo -e "${C_CYAN}Nginx belum terpasang. Menginstall...${C_RESET}"
    apt-get update -y && apt-get install -y nginx
  else
    echo -e "${C_GREEN}Nginx sudah terpasang: $(nginx -v 2>&1 | head -1)${C_RESET}"
  fi

  # --- Install Certbot jika belum ada ---
  if ! command -v certbot >/dev/null 2>&1; then
    echo -e "${C_CYAN}Certbot belum terpasang. Menginstall...${C_RESET}"
    apt-get update -y && apt-get install -y certbot python3-certbot-nginx
  else
    echo -e "${C_GREEN}Certbot sudah terpasang: $(certbot --version 2>&1)${C_RESET}"
  fi

  echo
  echo -e "${C_YELLOW}PERHATIAN: Pastikan DNS domain Anda sudah mengarah ke IP VPS ini${C_RESET}"
  echo -e "${C_YELLOW}sebelum melanjutkan agar Certbot bisa memverifikasi domain.${C_RESET}"
  echo

  read -r -p "Masukkan nama domain (contoh: qris.example.com): " DOMAIN
  if [ -z "$DOMAIN" ]; then echo "Domain tidak boleh kosong. Dibatalkan."; pause; return; fi

  read -r -p "Email untuk notifikasi SSL Let's Encrypt: " SSL_EMAIL
  if [ -z "$SSL_EMAIL" ]; then echo "Email tidak boleh kosong. Dibatalkan."; pause; return; fi

  # --- Buat konfigurasi Nginx (HTTP dulu, lalu Certbot upgrade ke HTTPS) ---
  local NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
  cat > "$NGINX_CONF" <<NGXEOF
server {
    listen 80;
    server_name $DOMAIN;

    # Proxy ke Web Panel QRIS
    location / {
        proxy_pass         http://127.0.0.1:$web_port;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        client_max_body_size 20M;
    }
}
NGXEOF

  # Aktifkan site
  ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

  # Hapus default jika mengganggu
  [ -f /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default

  # Test & reload Nginx
  echo -e "${C_CYAN}Testing konfigurasi Nginx...${C_RESET}"
  if ! nginx -t 2>&1; then
    echo -e "${C_RED}Konfigurasi Nginx gagal. Periksa error di atas.${C_RESET}"
    pause; return
  fi
  systemctl reload nginx || nginx -s reload

  echo -e "${C_GREEN}Nginx berhasil dikonfigurasi untuk domain: $DOMAIN${C_RESET}"
  echo

  # --- Jalankan Certbot untuk mendapatkan SSL ---
  echo -e "${C_CYAN}Meminta sertifikat SSL dari Let's Encrypt untuk: $DOMAIN${C_RESET}"
  if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect; then
    echo
    echo -e "${C_GREEN}============================================${C_RESET}"
    echo -e "${C_GREEN} SSL BERHASIL DIPASANG!${C_RESET}"
    echo -e "${C_GREEN}============================================${C_RESET}"
    echo "  URL Anda : https://$DOMAIN"
    echo "  Certbot otomatis mengaktifkan HTTPS & redirect HTTP→HTTPS."
    echo "  Sertifikat akan diperbarui otomatis oleh certbot.timer."
    echo

    # FIX: Simpan domain ke file .domain agar Callback URL di Web Panel otomatis terupdate
    echo "$DOMAIN" > "$SCRIPT_DIR/.domain"
    echo -e "${C_GREEN}Domain tersimpan: $SCRIPT_DIR/.domain${C_RESET}"
    echo -e "${C_GREEN}Callback URL di Web Panel akan otomatis menggunakan: https://$DOMAIN/qr/qr-mpm-notify${C_RESET}"

    echo -e "${C_YELLOW}Tips: Pastikan port 80 dan 443 terbuka di firewall:${C_RESET}"
    echo "  ufw allow 80/tcp && ufw allow 443/tcp"
  else
    echo -e "${C_RED}Certbot gagal. Kemungkinan penyebab:${C_RESET}"
    echo "  1. DNS domain $DOMAIN belum mengarah ke IP VPS ini."
    echo "  2. Port 80 belum terbuka di firewall."
    echo "  3. Batas rate-limit Let's Encrypt (coba lagi nanti)."
    echo "  Konfigurasi Nginx HTTP sudah terpasang, SSL bisa dicoba ulang nanti:"
    echo "    certbot --nginx -d $DOMAIN --email $SSL_EMAIL --agree-tos"
  fi
  pause
}

# ---------------- Generate RSA Key Pair ----------------
do_generate_keypair() {
  print_header "GENERATE RSA KEY PAIR (RSA 2048-bit)"
  local priv_path="$KEYS_DIR/private_key.pem"
  local pub_path="$KEYS_DIR/public_key.pem"

  if [ -f "$priv_path" ]; then
    echo -e "${C_YELLOW}Key pair sudah ada di:${C_RESET}"
    echo "  Private key : $priv_path"
    echo "  Public key  : $pub_path"
    echo
    read -r -p "Generate ulang? Key lama akan DITIMPA. [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Dibatalkan."; pause; return; }
  fi

  mkdir -p "$KEYS_DIR"
  echo -e "${C_CYAN}Membuat private key RSA 2048-bit...${C_RESET}"

  if ! openssl genrsa -out "$priv_path" 2048 2>/dev/null; then
    echo -e "${C_RED}ERROR: Gagal membuat private key. Pastikan openssl terinstall.${C_RESET}"
    pause; return
  fi
  chmod 600 "$priv_path"

  echo -e "${C_CYAN}Mengekstrak public key...${C_RESET}"
  if ! openssl rsa -in "$priv_path" -pubout -out "$pub_path" 2>/dev/null; then
    echo -e "${C_RED}ERROR: Gagal mengekstrak public key.${C_RESET}"
    pause; return
  fi

  # Simpan path private key ke konfigurasi
  PRIVATE_KEY_PATH="$priv_path"
  save_config

  echo -e "${C_GREEN}Key pair berhasil dibuat!${C_RESET}"
  echo
  echo "Private key : $priv_path"
  echo "             (JANGAN dibagikan — disimpan di server untuk generate X-Signature)"
  echo "Public key  : $pub_path"
  echo "Path private key otomatis tersimpan ke konfigurasi."
  echo
  echo -e "${C_BOLD}${C_CYAN}========================================================"
  echo " PUBLIC KEY — kirim ke BMRI/Yokke via email:"
  echo " ecommerce@yokke.co.id (cc: application.support@yokke.co.id)"
  echo -e "========================================================${C_RESET}"
  echo
  cat "$pub_path"
  echo
  echo -e "${C_BOLD}${C_CYAN}========================================================${C_RESET}"
  pause
}

# ---------------- Edit Konfigurasi ----------------
menu_edit_config() {
  print_header "UBAH KONFIGURASI"
  ask "Base URL" "${BASE_URL:-}" BASE_URL
  ask "API Version" "${API_VERSION:-}" API_VERSION
  ask "X-Client-Key" "${CLIENT_KEY:-}" CLIENT_KEY
  ask "Client Secret (untuk signature symmetric/auto)" "${CLIENT_SECRET:-}" CLIENT_SECRET
  ask "Path Private Key (untuk signature asymmetric/auto, .pem)" "${PRIVATE_KEY_PATH:-}" PRIVATE_KEY_PATH
  ask "X-Partner-Id" "${PARTNER_ID:-}" PARTNER_ID
  ask "Channel-Id" "${CHANNEL_ID:-02}" CHANNEL_ID
  ask "X-External-Id" "${EXTERNAL_ID:-}" EXTERNAL_ID
  ask "X-Platform" "${PLATFORM:-PORTAL}" PLATFORM
  ask "Merchant ID default" "${MERCHANT_ID:-}" MERCHANT_ID
  ask "Terminal ID default" "${TERMINAL_ID:-}" TERMINAL_ID
  ask "Authorization Bearer (untuk Access Token)" "${AUTH_BEARER:-}" AUTH_BEARER
  save_config
  echo -e "${C_GREEN}Konfigurasi tersimpan.${C_RESET}"
  pause
}

toggle_signature_mode() {
  if [ "${SIGNATURE_MODE:-manual}" = "manual" ]; then
    SIGNATURE_MODE="auto"
    echo "Signature mode diubah ke: auto (generate via openssl, perlu CLIENT_SECRET / PRIVATE_KEY_PATH)"
  else
    SIGNATURE_MODE="manual"
    echo "Signature mode diubah ke: manual (Anda paste signature sendiri tiap request)"
  fi
  save_config
  pause
}

# ---------------- Backup & Restore ----------------
do_backup_restore() {
  print_header "BACKUP & RESTORE"
  echo " a) Buat backup sekarang"
  echo " b) Restore dari file backup"
  echo " c) Lihat daftar backup tersimpan"
  echo " d) Hapus backup lama"
  echo " 0) Kembali"
  echo
  read -r -p "Pilih sub-menu: " br_choice
  case "$br_choice" in
    a|A) _do_backup ;;
    b|B) _do_restore ;;
    c|C) _list_backups ;;
    d|D) _delete_backup ;;
    0) return ;;
    *) echo "Pilihan tidak valid"; sleep 1 ;;
  esac
}

# Direktori penyimpanan backup (di dalam INSTALL_DIR supaya ikut satu folder)
BACKUP_DIR="$SCRIPT_DIR/backups"

_do_backup() {
  print_header "BUAT BACKUP"
  mkdir -p "$BACKUP_DIR"

  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local backup_name="qris-backup-${ts}.tar.gz"
  local backup_path="$BACKUP_DIR/$backup_name"

  # Daftar item yang di-backup (semua yang penting untuk restore ke VPS lain):
  #   config.json  - semua konfigurasi API (client key, secret, URL, mode, dst)
  #   config.env   - konfigurasi versi CLI
  #   auth.json    - kredensial admin Web Panel (username + password hash)
  #   keys/        - RSA private key & public key
  #   web/.port    - nomor port Web Panel
  #   Nginx config - konfigurasi domain SSL (jika ada, disimpan terpisah)

  echo -e "${C_CYAN}Item yang akan di-backup:${C_RESET}"
  echo "  config.json, config.env, auth.json, keys/, web/.port"

  # Kumpulkan file Nginx jika ada
  local nginx_backup_dir="$SCRIPT_DIR/nginx-backup-$ts"
  local has_nginx=0
  if [ -d /etc/nginx/sites-available ]; then
    local nginx_files
    nginx_files=$(find /etc/nginx/sites-available -maxdepth 1 -type f ! -name "default" 2>/dev/null)
    if [ -n "$nginx_files" ]; then
      mkdir -p "$nginx_backup_dir"
      cp -a /etc/nginx/sites-available/. "$nginx_backup_dir/" 2>/dev/null || true
      # Hapus default jika ikut terkopi
      rm -f "$nginx_backup_dir/default" 2>/dev/null || true
      has_nginx=1
      echo "  Konfigurasi Nginx domain (dari /etc/nginx/sites-available/)"
    fi
  fi

  # Buat arsip
  local items_to_pack=()
  local orig_dir
  orig_dir="$(pwd)"
  cd "$SCRIPT_DIR"

  [ -f "config.json" ] && items_to_pack+=("config.json")
  [ -f "config.env"  ] && items_to_pack+=("config.env")
  [ -f "auth.json"   ] && items_to_pack+=("auth.json")
  [ -d "keys"        ] && items_to_pack+=("keys")
  [ -f "web/.port"   ] && items_to_pack+=("web/.port")
  [ "$has_nginx" -eq 1 ] && items_to_pack+=("$(basename "$nginx_backup_dir")")

  if [ "${#items_to_pack[@]}" -eq 0 ]; then
    echo -e "${C_YELLOW}Tidak ada file konfigurasi ditemukan untuk di-backup.${C_RESET}"
    [ "$has_nginx" -eq 1 ] && rm -rf "$nginx_backup_dir"
    cd "$orig_dir"; pause; return
  fi

  echo
  echo -e "${C_CYAN}Membuat arsip: $backup_path${C_RESET}"
  if tar -czf "$backup_path" "${items_to_pack[@]}" 2>/dev/null; then
    # Hapus folder nginx sementara setelah masuk ke arsip
    [ "$has_nginx" -eq 1 ] && rm -rf "$nginx_backup_dir"
    cd "$orig_dir"
    local size
    size=$(du -sh "$backup_path" 2>/dev/null | cut -f1)
    echo
    echo -e "${C_GREEN}============================================${C_RESET}"
    echo -e "${C_GREEN} BACKUP BERHASIL!${C_RESET}"
    echo -e "${C_GREEN}============================================${C_RESET}"
    echo "  File  : $backup_path"
    echo "  Ukuran: $size"
    echo
    echo -e "${C_YELLOW}Cara transfer ke VPS lain:${C_RESET}"
    echo "  scp $backup_path user@IP-VPS-BARU:~/"
    echo "  atau download via SFTP/FileZilla"
    echo
    echo -e "${C_YELLOW}Cara restore di VPS baru:${C_RESET}"
    echo "  1. Jalankan install.sh di VPS baru terlebih dahulu"
    echo "  2. Salin file backup ke VPS baru, lalu jalankan 'menu'"
    echo "  3. Pilih menu 12 -> b) Restore dari file backup"
  else
    [ "$has_nginx" -eq 1 ] && rm -rf "$nginx_backup_dir"
    cd "$orig_dir"
    echo -e "${C_RED}ERROR: Gagal membuat arsip backup.${C_RESET}"
  fi
  pause
}

_do_restore() {
  print_header "RESTORE DARI BACKUP"

  # Cari file backup yang tersedia
  local backup_files=()
  while IFS= read -r f; do backup_files+=("$f"); done < <(
    ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null
  )

  # Juga cek di home directory (jika user meletakkan file backup di sana)
  while IFS= read -r f; do
    [[ "$f" == "$BACKUP_DIR"/* ]] || backup_files+=("$f")
  done < <(ls -1t "$HOME"/qris-backup-*.tar.gz 2>/dev/null)

  if [ "${#backup_files[@]}" -eq 0 ]; then
    echo -e "${C_YELLOW}Tidak ada file backup ditemukan.${C_RESET}"
    echo "Letakkan file backup (.tar.gz) di:"
    echo "  $BACKUP_DIR/"
    echo "  atau $HOME/"
    pause; return
  fi

  echo "File backup tersedia:"
  local i=1
  for f in "${backup_files[@]}"; do
    local sz
    sz=$(du -sh "$f" 2>/dev/null | cut -f1)
    echo "  $i) $(basename "$f")  [$sz]"
    i=$((i+1))
  done
  echo
  read -r -p "Pilih nomor backup untuk di-restore (ENTER untuk batal): " pick
  if [[ ! "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#backup_files[@]}" ]; then
    echo "Dibatalkan."; pause; return
  fi

  local selected="${backup_files[$((pick-1))]}"
  echo
  echo -e "${C_YELLOW}File yang akan di-restore: $(basename "$selected")${C_RESET}"
  echo -e "${C_RED}PERINGATAN: File konfigurasi, key, dan auth yang ada AKAN DITIMPA!${C_RESET}"
  read -r -p "Lanjutkan restore? [y/N]: " confirm
  [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Dibatalkan."; pause; return; }

  # Ekstrak ke lokasi sementara dulu untuk cek isi
  local tmp_dir
  tmp_dir=$(mktemp -d)
  echo -e "${C_CYAN}Mengekstrak backup...${C_RESET}"

  if ! tar -xzf "$selected" -C "$tmp_dir" 2>/dev/null; then
    echo -e "${C_RED}ERROR: File backup rusak atau bukan format tar.gz yang valid.${C_RESET}"
    rm -rf "$tmp_dir"; pause; return
  fi

  # Restore config.json
  if [ -f "$tmp_dir/config.json" ]; then
    cp "$tmp_dir/config.json" "$SCRIPT_DIR/config.json"
    echo -e "${C_GREEN}[OK]${C_RESET} config.json"
  fi

  # Restore config.env
  if [ -f "$tmp_dir/config.env" ]; then
    cp "$tmp_dir/config.env" "$SCRIPT_DIR/config.env"
    echo -e "${C_GREEN}[OK]${C_RESET} config.env"
  fi

  # Restore auth.json (kredensial admin Web Panel)
  if [ -f "$tmp_dir/auth.json" ]; then
    cp "$tmp_dir/auth.json" "$SCRIPT_DIR/auth.json"
    echo -e "${C_GREEN}[OK]${C_RESET} auth.json (kredensial Web Panel)"
  fi

  # Restore keys (RSA key pair)
  if [ -d "$tmp_dir/keys" ]; then
    mkdir -p "$SCRIPT_DIR/keys"
    cp -a "$tmp_dir/keys/." "$SCRIPT_DIR/keys/"
    chmod 600 "$SCRIPT_DIR/keys"/*.pem 2>/dev/null || true
    echo -e "${C_GREEN}[OK]${C_RESET} keys/ (RSA key pair)"
  fi

  # Restore web/.port
  if [ -f "$tmp_dir/web/.port" ]; then
    mkdir -p "$SCRIPT_DIR/web"
    cp "$tmp_dir/web/.port" "$SCRIPT_DIR/web/.port"
    echo -e "${C_GREEN}[OK]${C_RESET} web/.port (port Web Panel)"
  fi

  # Restore konfigurasi Nginx (hanya jika root dan Nginx terpasang)
  local nginx_backup_folder
  nginx_backup_folder=$(find "$tmp_dir" -maxdepth 1 -type d -name "nginx-backup-*" 2>/dev/null | head -1)
  if [ -n "$nginx_backup_folder" ] && command -v nginx >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    echo
    echo -e "${C_CYAN}Ditemukan konfigurasi Nginx di backup. Restore?${C_RESET}"
    echo -e "${C_YELLOW}(Hanya lakukan ini jika domain di VPS baru sama dengan VPS lama)${C_RESET}"
    read -r -p "Restore konfigurasi Nginx? [y/N]: " restore_nginx
    if [[ "$restore_nginx" =~ ^[Yy]$ ]]; then
      local restored_count=0
      for conf_file in "$nginx_backup_folder"/*; do
        [ -f "$conf_file" ] || continue
        local conf_name
        conf_name=$(basename "$conf_file")
        cp "$conf_file" "/etc/nginx/sites-available/$conf_name"
        ln -sf "/etc/nginx/sites-available/$conf_name" "/etc/nginx/sites-enabled/$conf_name"
        restored_count=$((restored_count+1))
        echo -e "${C_GREEN}[OK]${C_RESET} Nginx: $conf_name"
      done
      if [ "$restored_count" -gt 0 ]; then
        if nginx -t 2>/dev/null; then
          systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
          echo -e "${C_GREEN}Nginx berhasil di-reload.${C_RESET}"
        else
          echo -e "${C_YELLOW}Peringatan: konfigurasi Nginx ada error, tidak di-reload.${C_RESET}"
          echo "Cek manual: nginx -t"
        fi
      fi
    else
      echo "Konfigurasi Nginx dilewati."
    fi
  fi

  rm -rf "$tmp_dir"

  # Reload konfigurasi di session CLI ini
  load_config

  echo
  echo -e "${C_GREEN}============================================${C_RESET}"
  echo -e "${C_GREEN} RESTORE SELESAI!${C_RESET}"
  echo -e "${C_GREEN}============================================${C_RESET}"
  echo "Konfigurasi berhasil dipulihkan dari backup."
  echo "Restart Web Panel agar perubahan berlaku:"
  echo "  systemctl restart qris-web  (jika pakai systemd)"
  echo "  atau: cd $SCRIPT_DIR/web && PORT=\$(cat $SCRIPT_DIR/web/.port) node server.js"
  pause
}

_list_backups() {
  print_header "DAFTAR BACKUP TERSIMPAN"
  local count=0
  if [ -d "$BACKUP_DIR" ]; then
    while IFS= read -r f; do
      local sz ts_str
      sz=$(du -sh "$f" 2>/dev/null | cut -f1)
      ts_str=$(stat -c %y "$f" 2>/dev/null | cut -d'.' -f1)
      echo "  $(basename "$f")  [$sz]  $ts_str"
      count=$((count+1))
    done < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
  fi
  if [ "$count" -eq 0 ]; then
    echo "Belum ada backup tersimpan di: $BACKUP_DIR"
  else
    echo
    echo "Total: $count backup"
    echo "Lokasi: $BACKUP_DIR"
  fi
  pause
}

_delete_backup() {
  print_header "HAPUS BACKUP LAMA"
  local backup_files=()
  while IFS= read -r f; do backup_files+=("$f"); done < <(
    ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null
  )
  if [ "${#backup_files[@]}" -eq 0 ]; then
    echo "Tidak ada backup untuk dihapus."
    pause; return
  fi

  local i=1
  for f in "${backup_files[@]}"; do
    local sz
    sz=$(du -sh "$f" 2>/dev/null | cut -f1)
    echo "  $i) $(basename "$f")  [$sz]"
    i=$((i+1))
  done
  echo "  a) Hapus SEMUA backup"
  echo
  read -r -p "Pilih nomor untuk dihapus (atau 'a' untuk semua, ENTER untuk batal): " pick
  if [[ "$pick" =~ ^[Aa]$ ]]; then
    read -r -p "Hapus semua ${#backup_files[@]} backup? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      rm -f "$BACKUP_DIR"/*.tar.gz
      echo -e "${C_GREEN}Semua backup dihapus.${C_RESET}"
    else
      echo "Dibatalkan."
    fi
  elif [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#backup_files[@]}" ]; then
    local target="${backup_files[$((pick-1))]}"
    rm -f "$target"
    echo -e "${C_GREEN}Dihapus: $(basename "$target")${C_RESET}"
  else
    echo "Dibatalkan."
  fi
  pause
}

# ---------------- Restart Semua Layanan ----------------
do_restart_all() {
  print_header "RESTART SEMUA LAYANAN"

  local web_port="7080"
  [ -f "$SCRIPT_DIR/web/.port" ] && web_port="$(cat "$SCRIPT_DIR/web/.port")"

  local service_name="qris-web.service"
  local log_file="$SCRIPT_DIR/logs/web-panel.out.log"

  # ── Deteksi mode yang sedang aktif ──────────────────────────────────────
  local mode="unknown"
  if command -v systemctl >/dev/null 2>&1 &&      systemctl is-active --quiet "$service_name" 2>/dev/null; then
    mode="systemd"
  elif command -v pm2 >/dev/null 2>&1 &&      pm2 list 2>/dev/null | grep -q "qris-web"; then
    mode="pm2"
  elif pgrep -f "server.js" >/dev/null 2>&1; then
    mode="nohup"
  fi

  echo -e "${C_CYAN}Mode yang terdeteksi : ${C_BOLD}$mode${C_RESET}"
  echo -e "${C_CYAN}Port Web Panel       : $web_port${C_RESET}"
  echo

  echo "Layanan yang akan direstart:"
  echo "  [1] Web Panel QRIS  ($mode)"
  echo "  [2] Nginx (reverse proxy / SSL)"
  echo
  read -r -p "Lanjutkan restart semua layanan? [Y/n]: " confirm
  [[ "$confirm" =~ ^[Nn]$ ]] && { echo "Dibatalkan."; pause; return; }

  local ok_web=0 ok_nginx=0

  # ── Restart Web Panel ────────────────────────────────────────────────────
  echo
  echo -e "${C_CYAN}[1/2] Merestart Web Panel...${C_RESET}"

  case "$mode" in
    systemd)
      if systemctl restart "$service_name" 2>/dev/null; then
        sleep 1
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
          ok_web=1
          echo -e "${C_GREEN}  [OK]${C_RESET} Web Panel berjalan via systemd"
        else
          echo -e "${C_RED}  [GAGAL]${C_RESET} Service tidak aktif setelah restart"
          echo "  Cek: systemctl status $service_name"
        fi
      else
        echo -e "${C_RED}  [GAGAL]${C_RESET} systemctl restart gagal"
      fi
      ;;
    pm2)
      if pm2 restart qris-web 2>/dev/null; then
        ok_web=1
        echo -e "${C_GREEN}  [OK]${C_RESET} Web Panel direstart via pm2"
      else
        echo -e "${C_RED}  [GAGAL]${C_RESET} pm2 restart gagal"
      fi
      ;;
    nohup|unknown)
      # Matikan proses lama
      local old_pids
      old_pids=$(pgrep -f "node.*server.js" 2>/dev/null || true)
      if [ -n "$old_pids" ]; then
        echo "  Menghentikan proses lama (PID: $old_pids)..."
        kill $old_pids 2>/dev/null || true
        sleep 1
      fi
      # Jalankan ulang dengan nohup
      mkdir -p "$SCRIPT_DIR/logs"
      ( cd "$SCRIPT_DIR/web" &&         PORT="$web_port" nohup node server.js >> "$log_file" 2>&1 & )
      sleep 2
      if curl -s --max-time 3 "http://127.0.0.1:$web_port/" >/dev/null 2>&1; then
        ok_web=1
        echo -e "${C_GREEN}  [OK]${C_RESET} Web Panel berjalan kembali via nohup (PORT=$web_port)"
      else
        echo -e "${C_YELLOW}  [?]${C_RESET} Proses dijalankan, belum bisa diverifikasi dalam 3 detik"
        echo "  Cek log: tail -20 $log_file"
      fi
      ;;
  esac

  # ── Restart Nginx ────────────────────────────────────────────────────────
  echo
  echo -e "${C_CYAN}[2/2] Merestart Nginx...${C_RESET}"

  if ! command -v nginx >/dev/null 2>&1; then
    echo -e "  ${C_YELLOW}[SKIP]${C_RESET} Nginx tidak terpasang"
  elif [ "$(id -u)" -ne 0 ]; then
    echo -e "  ${C_YELLOW}[SKIP]${C_RESET} Perlu root untuk restart Nginx"
    echo "  Jalankan: sudo systemctl restart nginx"
  else
    if command -v systemctl >/dev/null 2>&1 &&        systemctl is-active --quiet nginx 2>/dev/null; then
      if systemctl restart nginx 2>/dev/null; then
        ok_nginx=1
        echo -e "${C_GREEN}  [OK]${C_RESET} Nginx direstart via systemd"
      else
        echo -e "${C_RED}  [GAGAL]${C_RESET} systemctl restart nginx gagal"
      fi
    else
      if nginx -s reload 2>/dev/null; then
        ok_nginx=1
        echo -e "${C_GREEN}  [OK]${C_RESET} Nginx di-reload"
      else
        echo -e "${C_RED}  [GAGAL]${C_RESET} nginx -s reload gagal"
      fi
    fi
  fi

  # ── Ringkasan ────────────────────────────────────────────────────────────
  echo
  echo -e "${C_BOLD}${C_CYAN}========================================${C_RESET}"
  echo -e "${C_BOLD} Hasil Restart${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}========================================${C_RESET}"

  local domain=""
  [ -f "$SCRIPT_DIR/.domain" ] && domain=$(cat "$SCRIPT_DIR/.domain" | tr -d "[:space:]")

  if [ "$ok_web" -eq 1 ]; then
    echo -e "  Web Panel : ${C_GREEN}AKTIF${C_RESET}"
    if [ -n "$domain" ]; then
      echo -e "  Akses     : ${C_CYAN}https://$domain${C_RESET}"
    else
      local public_ip
      public_ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || echo "")
      [ -n "$public_ip" ] &&         echo -e "  Akses     : ${C_CYAN}http://$public_ip:$web_port${C_RESET}" ||         echo -e "  Akses     : ${C_CYAN}http://<IP-VPS>:$web_port${C_RESET}"
    fi
  else
    echo -e "  Web Panel : ${C_RED}GAGAL / perlu cek manual${C_RESET}"
  fi

  if command -v nginx >/dev/null 2>&1; then
    [ "$ok_nginx" -eq 1 ] &&       echo -e "  Nginx     : ${C_GREEN}AKTIF${C_RESET}" ||       echo -e "  Nginx     : ${C_YELLOW}tidak direstart (lihat pesan di atas)${C_RESET}"
  fi

  echo
  pause
}

# ---------------- Main Menu ----------------
main_menu() {
  while true; do
    clear
    print_banner
    echo " 1) Ubah Konfigurasi (Client Key, Partner ID, Merchant, dst)"
    echo " 2) Get Access Token"
    echo " 3) QR-MPM-Generate (Buat QR)"
    echo " 4) QR-MPM-Query (Cek Status Transaksi)"
    echo " 5) QR-MPM-Cancel (Refund/Cancel)"
    echo " 6) Jalankan Full Flow Test (Generate -> Query -> Cancel)"
    echo " 7) Lihat Riwayat Log Test"
    echo " 8) Toggle Mode Signature (saat ini: ${SIGNATURE_MODE:-manual})"
    echo " 9) Bersihkan Semua Log"
    echo "10) Generate RSA Key Pair (Public + Private Key)"
    echo "11) Kelola SSL & Domain (Nginx + Let's Encrypt HTTPS)"
    echo "12) Backup & Restore (config, key, auth, Nginx)"
    echo "13) Restart Semua Layanan (Web Panel + Nginx)"
    echo " 0) Keluar"
    echo
    read -r -p "Pilih menu: " choice
    case "$choice" in
      1) menu_edit_config ;;
      2) do_access_token ;;
      3) do_generate ;;
      4) do_query ;;
      5) do_cancel ;;
      6) do_full_flow ;;
      7) view_logs ;;
      8) toggle_signature_mode ;;
      9) clear_logs ;;
      10) do_generate_keypair ;;
      11) do_ssl_domain ;;
      12) do_backup_restore ;;
      13) do_restart_all ;;
      0) echo "Sampai jumpa."; exit 0 ;;
      *) echo "Pilihan tidak valid"; sleep 1 ;;
    esac
  done
}

load_config
main_menu
SCRIPT_EOF

chmod +x "$MAIN_SCRIPT"
echo "qris-test.sh (CLI) terpasang di: $MAIN_SCRIPT"

# -----------------------------------------------------------------------------
# 4b. Pasang alias 'menu' di shell user (.bashrc & .bash_profile) supaya
#     user bisa ketik "menu" di terminal untuk langsung membuka menu CLI.
# -----------------------------------------------------------------------------
setup_menu_alias() {
  local alias_line="alias menu='cd $INSTALL_DIR && ./qris-test.sh'"
  local alias_cmd_line="menu() { cd \"$INSTALL_DIR\" && ./qris-test.sh; }"

  # Pasang ke .bashrc dan .bash_profile untuk user yang menjalankan installer
  for rc_file in "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$rc_file" ] || [ "$rc_file" = "$HOME/.bashrc" ]; then
      # Hapus entri lama jika sudah ada untuk mencegah duplikasi
      sed -i '/alias menu=.*qris-test/d' "$rc_file" 2>/dev/null || true
      sed -i '/^menu().*qris-test/d' "$rc_file" 2>/dev/null || true
      # Tulis ulang
      echo "" >> "$rc_file"
      echo "# QRIS SNAP MPM - ketik 'menu' untuk membuka menu interaktif" >> "$rc_file"
      echo "$alias_line" >> "$rc_file"
      echo "Alias 'menu' dipasang di: $rc_file"
    fi
  done

  # Buat symlink /usr/local/bin/menu agar bekerja di semua shell termasuk non-bash
  if [ "$(id -u)" -eq 0 ]; then
    local wrapper="/usr/local/bin/menu"
    cat > "$wrapper" <<MENU_WRAPPER
#!/usr/bin/env bash
cd "$INSTALL_DIR" && exec ./qris-test.sh "\$@"
MENU_WRAPPER
    chmod +x "$wrapper"
    echo "Perintah global 'menu' dipasang di: $wrapper"
    echo "Sekarang Anda bisa ketik 'menu' dari direktori mana pun di terminal."
  else
    echo "Catatan: install sebagai root untuk membuat perintah 'menu' tersedia global."
    echo "Untuk saat ini, ketik: source ~/.bashrc  lalu ketik 'menu'"
  fi
}
setup_menu_alias

# -----------------------------------------------------------------------------
# 5. Migrasi config.env -> config.json (dipakai Web Panel), hanya jika
#    config.json belum ada. CLI dan Web Panel berbagi data yang sama setelah ini.
# -----------------------------------------------------------------------------
migrate_config() {
  if [ -f "$CONFIG_JSON" ]; then
    echo "config.json sudah ada, tidak ditimpa: $CONFIG_JSON"
    return
  fi
  if [ -f "$CONFIG_FILE" ]; then
    (
      set -a
      # shellcheck disable=SC1090
      source "$CONFIG_FILE"
      set +a
      jq -n \
        --arg baseUrl "${BASE_URL:-}" \
        --arg apiVersion "${API_VERSION:-}" \
        --arg clientKey "${CLIENT_KEY:-}" \
        --arg clientSecret "${CLIENT_SECRET:-}" \
        --arg privateKeyPath "${PRIVATE_KEY_PATH:-}" \
        --arg partnerId "${PARTNER_ID:-}" \
        --arg channelId "${CHANNEL_ID:-02}" \
        --arg externalId "${EXTERNAL_ID:-}" \
        --arg platform "${PLATFORM:-PORTAL}" \
        --arg merchantId "${MERCHANT_ID:-}" \
        --arg terminalId "${TERMINAL_ID:-}" \
        --arg authBearer "${AUTH_BEARER:-}" \
        --arg accessToken "${ACCESS_TOKEN:-}" \
        --arg signatureMode "${SIGNATURE_MODE:-manual}" \
        --arg lastPartnerRef "${LAST_PARTNER_REF:-}" \
        --arg lastReferenceNo "${LAST_REFERENCE_NO:-}" \
        --arg lastExternalIdGen "${LAST_EXTERNAL_ID_GEN:-}" \
        --arg lastTrxDate "${LAST_TRX_DATE:-}" \
        --arg lastApprovalCode "${LAST_APPROVAL_CODE:-}" \
        --arg lastAmount "${LAST_AMOUNT:-}" \
        '{baseUrl:$baseUrl, apiVersion:$apiVersion, clientKey:$clientKey, clientSecret:$clientSecret,
          privateKeyPath:$privateKeyPath, partnerId:$partnerId, channelId:$channelId, externalId:$externalId,
          platform:$platform, merchantId:$merchantId, terminalId:$terminalId, authBearer:$authBearer,
          accessToken:$accessToken, signatureMode:$signatureMode, allowInsecureTLS:false,
          lastPartnerRef:$lastPartnerRef, lastReferenceNo:$lastReferenceNo, lastExternalIdGen:$lastExternalIdGen,
          lastTrxDate:$lastTrxDate, lastApprovalCode:$lastApprovalCode, lastAmount:$lastAmount}' > "$CONFIG_JSON"
    )
    echo "Konfigurasi dari config.env berhasil dimigrasikan ke: $CONFIG_JSON"
  else
    echo "Belum ada config.env. config.json akan dibuat otomatis dengan nilai default saat Web Panel pertama kali jalan."
  fi
}
migrate_config

# -----------------------------------------------------------------------------
# 6. Tulis file-file Web Panel (Node.js/Express): package.json, server.js,
#    dan frontend statis di web/public/.
# -----------------------------------------------------------------------------
echo
echo "Menulis file Web Panel ke: $WEB_DIR"

cat > "$WEB_DIR/package.json" <<'PKG_EOF'
{
  "name": "qris-snap-web",
  "version": "1.0.0",
  "private": true,
  "description": "QRIS SNAP MPM Integration Test Web Panel",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "express-session": "^1.18.0",
    "bcryptjs": "^2.4.3",
    "exceljs": "^4.4.0"
  }
}
PKG_EOF

cat > "$WEB_DIR/server.js" << 'SRV_EOF'
#!/usr/bin/env node
/* ============================================================================
 * server.js - QRIS SNAP MPM Web Panel
 * Backend Express untuk menggantikan/ melengkapi qris-test.sh (CLI) dengan
 * antarmuka web. Logika signature, request, dan logging dibuat sefidel
 * mungkin terhadap qris-test.sh agar hasil testing konsisten.
 * ==========================================================================*/
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const https = require('https');
const http = require('http');
const { URL } = require('url');

const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');

const INSTALL_DIR = path.resolve(__dirname, '..');
const LOG_DIR = path.join(INSTALL_DIR, 'logs');
const KEYS_DIR = path.join(INSTALL_DIR, 'keys');
const CONFIG_PATH = path.join(INSTALL_DIR, 'config.json');
const AUTH_PATH = path.join(INSTALL_DIR, 'auth.json');
// FIX: path ke file .domain yang disimpan saat SSL setup berhasil
const DOMAIN_PATH = path.join(INSTALL_DIR, '.domain');

for (const dir of [LOG_DIR, KEYS_DIR]) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

const DEFAULT_CONFIG = {
  baseUrl: 'https://tst.yokke.co.id:8280',
  apiVersion: '1.0.11',
  clientKey: '',
  clientSecret: '',
  privateKeyPath: '',
  partnerId: '',
  channelId: '02',
  externalId: '866330434635474',
  platform: 'PORTAL',
  merchantId: '00007100010926',
  terminalId: '72001126',
  authBearer: '',
  accessToken: '',
  signatureMode: 'manual',
  allowInsecureTLS: false,
  lastPartnerRef: '',
  lastReferenceNo: '',
  lastExternalIdGen: '',
  lastTrxDate: '',
  lastApprovalCode: '',
  lastAmount: '',
};

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    saveConfig(DEFAULT_CONFIG);
    return { ...DEFAULT_CONFIG };
  }
  try {
    const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    return Object.assign({}, DEFAULT_CONFIG, raw);
  } catch (e) {
    return { ...DEFAULT_CONFIG };
  }
}

// FIX: dulu Web Panel HANYA menulis config.json, sementara CLI (qris-test.sh)
// HANYA membaca config.env. Keduanya cuma disamakan SEKALI lewat migrasi saat
// install, sesudah itu config.json dan config.env tidak pernah sinkron lagi -
// ini sebabnya perubahan di Web Panel tidak pernah muncul di CLI. Sekarang
// setiap saveConfig() juga menulis ulang config.env, supaya CLI selalu
// melihat nilai terbaru.
const CONFIG_ENV_PATH = path.join(INSTALL_DIR, 'config.env');

// Escape value supaya aman saat dimasukkan ke dalam string ber-kutip-dua
// yang nanti di-`source` oleh bash (config.env).
function shEscape(val) {
  return String(val == null ? '' : val)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\$/g, '\\$')
    .replace(/`/g, '\\`');
}

function writeConfigEnv(cfg) {
  const lines = [
    '# =============================================================',
    '# Konfigurasi QRIS SNAP MPM Test CLI',
    '# File ini otomatis disinkronkan dari Web Panel (config.json).',
    '# Boleh diedit manual lewat menu CLI "Ubah Konfigurasi" - perubahan',
    '# dari CLI juga akan ditulis balik ke config.json.',
    '# =============================================================',
    `BASE_URL="${shEscape(cfg.baseUrl)}"`,
    `API_VERSION="${shEscape(cfg.apiVersion)}"`,
    '',
    `CLIENT_KEY="${shEscape(cfg.clientKey)}"`,
    `CLIENT_SECRET="${shEscape(cfg.clientSecret)}"`,
    `PRIVATE_KEY_PATH="${shEscape(cfg.privateKeyPath)}"`,
    `PARTNER_ID="${shEscape(cfg.partnerId)}"`,
    `CHANNEL_ID="${shEscape(cfg.channelId)}"`,
    `EXTERNAL_ID="${shEscape(cfg.externalId)}"`,
    `PLATFORM="${shEscape(cfg.platform)}"`,
    '',
    `MERCHANT_ID="${shEscape(cfg.merchantId)}"`,
    `TERMINAL_ID="${shEscape(cfg.terminalId)}"`,
    '',
    `AUTH_BEARER="${shEscape(cfg.authBearer)}"`,
    `ACCESS_TOKEN="${shEscape(cfg.accessToken)}"`,
    '',
    `SIGNATURE_MODE="${shEscape(cfg.signatureMode || 'manual')}"`,
    '',
    `LAST_PARTNER_REF="${shEscape(cfg.lastPartnerRef)}"`,
    `LAST_REFERENCE_NO="${shEscape(cfg.lastReferenceNo)}"`,
    `LAST_EXTERNAL_ID_GEN="${shEscape(cfg.lastExternalIdGen)}"`,
    `LAST_TRX_DATE="${shEscape(cfg.lastTrxDate)}"`,
    `LAST_APPROVAL_CODE="${shEscape(cfg.lastApprovalCode)}"`,
    `LAST_AMOUNT="${shEscape(cfg.lastAmount)}"`,
    '',
  ];
  try {
    fs.writeFileSync(CONFIG_ENV_PATH, lines.join('\n'), 'utf8');
  } catch (e) {
    console.error('Gagal menulis config.env:', e.message);
  }
}

function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2), 'utf8');
  writeConfigEnv(cfg);
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

// Semua waktu dipakai timezone WIB (Asia/Jakarta, UTC+7) agar konsisten dengan
// sandbox Yokke dan tidak bergantung pada timezone server VPS.
const WIB_OFFSET_MS = 7 * 60 * 60 * 1000;

function wibDate() {
  return new Date(Date.now() + WIB_OFFSET_MS);
}

// Format: 2026-06-30T10:21:57+07:00
function timestampNow() {
  const d = wibDate();
  return (
    `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}` +
    `T${pad2(d.getUTCHours())}:${pad2(d.getUTCMinutes())}:${pad2(d.getUTCSeconds())}` +
    `+07:00`
  );
}

// Format: YYYYMMDD dalam WIB
function dateYYYYMMDD() {
  const d = wibDate();
  return `${d.getUTCFullYear()}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}`;
}

// Untuk nama file log, pakai WIB
function fileTimestamp() {
  const d = wibDate();
  return (
    `${d.getUTCFullYear()}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}-` +
    `${pad2(d.getUTCHours())}${pad2(d.getUTCMinutes())}${pad2(d.getUTCSeconds())}`
  );
}

function logResult(name, httpCode, reqBody, respBody, reqHeaders) {
  const fname = `${fileTimestamp()}_${String(name).replace(/\s+/g, '_')}.log`;
  const headerLines = reqHeaders
    ? Object.entries(reqHeaders).map(([k, v]) => `${k}: ${v}`).join('\n')
    : '';
  const content =
    `==== ${name} ====\n` +
    `Waktu       : ${new Date().toISOString()}\n` +
    `HTTP Code   : ${httpCode}\n` +
    `---- Request Headers ----\n${headerLines}\n` +
    `---- Request Body ----\n${reqBody}\n` +
    `---- Response Body ----\n${respBody}\n`;
  fs.writeFileSync(path.join(LOG_DIR, fname), content, 'utf8');
  return fname;
}

// ---------------- Signature (identik dgn sig_asymmetric / sig_symmetric di qris-test.sh) ----------------
function sigAsymmetric(clientKey, ts, privateKeyPem) {
  const stringToSign = `${clientKey}|${ts}`;
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(stringToSign);
  signer.end();
  return signer.sign(privateKeyPem, 'base64');
}

function sigSymmetric(method, relativeUrl, accessToken, bodyStr, ts, clientSecret) {
  let minified;
  try {
    minified = JSON.stringify(JSON.parse(bodyStr));
  } catch (e) {
    minified = bodyStr;
  }
  const bodyHash = crypto.createHash('sha256').update(minified).digest('hex');
  const stringToSign = `${method}:${relativeUrl}:${accessToken}:${bodyHash}:${ts}`;
  return crypto.createHmac('sha512', clientSecret).update(stringToSign).digest('base64');
}

function getPrivateKeyPem(cfg) {
  if (!cfg.privateKeyPath) return null;
  try {
    return fs.readFileSync(cfg.privateKeyPath, 'utf8');
  } catch (e) {
    return null;
  }
}

async function resolveSignature({ kind, cfg, manualOverride, args }) {
  if (cfg.signatureMode === 'auto') {
    if (kind === 'asymmetric') {
      const pem = getPrivateKeyPem(cfg);
      if (!pem) {
        throw new Error('Private key belum diset / tidak terbaca, tidak bisa auto-sign (asymmetric).');
      }
      return sigAsymmetric(args.clientKey, args.ts, pem);
    }
    if (!cfg.clientSecret) {
      throw new Error('Client Secret belum diset, tidak bisa auto-sign (symmetric).');
    }
    return sigSymmetric(args.method, args.relativeUrl, args.accessToken, args.body, args.ts, cfg.clientSecret);
  }
  if (manualOverride && String(manualOverride).trim()) return String(manualOverride).trim();
  throw new Error('Mode signature = manual: harap isi field X-Signature secara manual, atau pindah ke mode auto di Konfigurasi.');
}

// ---------------- HTTP client (pengganti curl) ----------------
function httpRequest({ url, method = 'GET', headers = {}, body = '', insecure = false }) {
  return new Promise((resolve, reject) => {
    let u;
    try {
      u = new URL(url);
    } catch (e) {
      return reject(new Error('Base URL tidak valid: ' + url));
    }
    const lib = u.protocol === 'https:' ? https : http;
    const finalHeaders = Object.assign({}, headers);
    if (body) finalHeaders['Content-Length'] = Buffer.byteLength(body);
    const options = {
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + (u.search || ''),
      method,
      headers: finalHeaders,
    };
    if (u.protocol === 'https:') options.rejectUnauthorized = !insecure;
    const req = lib.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve({ statusCode: res.statusCode, body: data }));
    });
    req.on('error', (err) => reject(err));
    req.setTimeout(20000, () => req.destroy(new Error('Request timeout (20s)')));
    if (body) req.write(body);
    req.end();
  });
}

function tryParseJSON(str) {
  try {
    return JSON.parse(str);
  } catch (e) {
    return null;
  }
}

// ---------------- Endpoint logic (setara do_access_token / do_generate / do_query / do_cancel) ----------------
async function performAccessToken(cfg, input) {
  const baseUrl = input.baseUrl || cfg.baseUrl;
  const apiVersion = input.apiVersion || cfg.apiVersion;
  const clientKey = input.clientKey || cfg.clientKey;
  const authBearer = input.authBearer || cfg.authBearer;
  const platform = input.platform || cfg.platform;

  const relativeUrl = `/qrissnapmpm/${apiVersion}/qr/v2.0/access-token/b2b`;
  const url = `${baseUrl}${relativeUrl}`;
  const ts = timestampNow();
  const body = JSON.stringify({ grantType: 'client_credentials' });

  const signature = await resolveSignature({
    kind: 'asymmetric',
    cfg,
    manualOverride: input.signature,
    args: { clientKey, ts },
  });

  const headers = {
    Authorization: `Bearer ${authBearer}`,
    'Content-Type': 'application/json',
    'X-Timestamp': ts,
    'X-Signature': signature,
    'X-Client-Key': clientKey,
  };
  if (platform) headers['X-Platform'] = platform;

  const result = await httpRequest({ url, method: 'POST', headers, body, insecure: !!cfg.allowInsecureTLS });
  const parsed = tryParseJSON(result.body);

  Object.assign(cfg, { baseUrl, apiVersion, clientKey, authBearer, platform });
  if (parsed && parsed.accessToken) cfg.accessToken = parsed.accessToken;

  const logFile = logResult('GET_ACCESS_TOKEN', result.statusCode, body, result.body, headers);
  return {
    httpCode: result.statusCode,
    requestBody: body,
    responseBody: parsed !== null ? parsed : result.body,
    signature,
    timestamp: ts,
    url,
    headers,
    logFile,
    accessTokenSaved: !!(parsed && parsed.accessToken),
  };
}

async function performGenerate(cfg, input) {
  const baseUrl = input.baseUrl || cfg.baseUrl;
  const apiVersion = input.apiVersion || cfg.apiVersion;
  const accessToken = input.accessToken || cfg.accessToken;
  const channelId = input.channelId || cfg.channelId;
  const partnerId = input.partnerId || cfg.partnerId;
  const merchantId = input.merchantId || cfg.merchantId;
  const terminalId = input.terminalId || cfg.terminalId;
  const amountValue = input.amountValue || '10000.00';
  const feeValue = input.feeValue || '10000.00';
  const currency = input.currency || 'IDR';

  // partnerReferenceNo: pakai nilai dari user/form, lalu dari config tersimpan,
  // lalu dari default sandbox. TIDAK di-random agar sesuai test case sandbox Yokke.
  const partnerReferenceNo = input.partnerReferenceNo || cfg.lastPartnerRef || '230218123798000';

  // FIX: X-External-Id HARUS unik per request Generate agar sandbox tidak
  // menolak dengan "duplicate externalId". Dihitung SEKALI dan dipakai konsisten
  // sebagai header DAN disimpan ke cfg.lastExternalIdGen untuk Query/Cancel.
  const externalId = input.externalId ||
    (String(Date.now()) + Math.floor(Math.random() * 9 + 1).toString()).slice(0, 15);

  const relativeUrl = `/qrissnapmpm/${apiVersion}/v2.0/qr/qr-mpm-generate`;
  const url = `${baseUrl}${relativeUrl}`;
  const ts = timestampNow();
  const body = JSON.stringify({
    merchantId,
    terminalId,
    partnerReferenceNo,
    amount: { value: amountValue, currency },
    feeAmount: { value: feeValue, currency },
  });

  const signature = await resolveSignature({
    kind: 'symmetric',
    cfg,
    manualOverride: input.signature,
    args: { method: 'POST', relativeUrl, accessToken, body, ts },
  });

  const headers = {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
    'X-Timestamp': ts,
    'X-Signature': signature,
    'X-External-Id': externalId,
    'X-Partner-Id': partnerId,
    'Channel-Id': channelId,
  };
  if (cfg.platform) headers['X-Platform'] = cfg.platform;

  const result = await httpRequest({ url, method: 'POST', headers, body, insecure: !!cfg.allowInsecureTLS });
  const parsed = tryParseJSON(result.body);

  Object.assign(cfg, { baseUrl, apiVersion, accessToken, channelId, externalId, partnerId, merchantId, terminalId });
  cfg.lastPartnerRef = partnerReferenceNo;
  cfg.lastReferenceNo = (parsed && parsed.referenceNo) || '';
  // FIX: originalExternalId untuk Query/Cancel harus = X-External-Id header yang
  // dipakai saat Generate (cfg.externalId / externalId), BUKAN referenceNo dari
  // response Generate. Sandbox Yokke memvalidasi nilai ini berdasarkan externalId
  // yang dikirim saat transaksi Generate berlangsung.
  cfg.lastExternalIdGen = externalId;
  cfg.lastTrxDate = dateYYYYMMDD();
  cfg.lastAmount = amountValue;

  const logFile = logResult('QR_MPM_GENERATE', result.statusCode, body, result.body, headers);
  return {
    httpCode: result.statusCode,
    requestBody: body,
    responseBody: parsed !== null ? parsed : result.body,
    signature,
    timestamp: ts,
    url,
    headers,
    logFile,
    referenceNo: cfg.lastReferenceNo,
  };
}

async function performQuery(cfg, input) {
  const baseUrl = input.baseUrl || cfg.baseUrl;
  const apiVersion = input.apiVersion || cfg.apiVersion;
  const accessToken = input.accessToken || cfg.accessToken;
  const channelId = input.channelId || cfg.channelId;
  const partnerId = input.partnerId || cfg.partnerId;
  const merchantId = input.merchantId || cfg.merchantId;
  const terminalId = input.terminalId || cfg.terminalId;
  const originalReferenceNo = input.originalReferenceNo || cfg.lastReferenceNo;
  // FIX FINAL: X-External-Id HEADER dan originalExternalId BODY harus SAMA PERSIS,
  // keduanya = externalId yang dipakai saat Generate (cfg.lastExternalIdGen).
  // Manual override dari input tetap dipakai jika ada.
  const originalExternalId = input.originalExternalId || cfg.lastExternalIdGen;
  const externalId = input.externalId || originalExternalId;
  const serviceCode = input.serviceCode || '51';
  const originalTransactionDate = input.originalTransactionDate || cfg.lastTrxDate || dateYYYYMMDD();

  const relativeUrl = `/qrissnapmpm/${apiVersion}/v2.0/qr/qr-mpm-query`;
  const url = `${baseUrl}${relativeUrl}`;
  const ts = timestampNow();
  const body = JSON.stringify({
    originalReferenceNo,
    originalExternalId,
    serviceCode,
    merchantId,
    additionalInfo: { originalTransactionDate, terminalId },
  });

  const signature = await resolveSignature({
    kind: 'symmetric',
    cfg,
    manualOverride: input.signature,
    args: { method: 'POST', relativeUrl, accessToken, body, ts },
  });

  const headers = {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
    'X-Timestamp': ts,
    'X-Signature': signature,
    'X-External-Id': externalId,
    'X-Partner-Id': partnerId,
    'Channel-Id': channelId,
  };
  if (cfg.platform) headers['X-Platform'] = cfg.platform;

  const result = await httpRequest({ url, method: 'POST', headers, body, insecure: !!cfg.allowInsecureTLS });
  const parsed = tryParseJSON(result.body);

  // Tidak menulis externalId ke cfg agar cfg.externalId (dari Generate) tetap terjaga
  // sebagai referensi originalExternalId untuk Cancel berikutnya.
  Object.assign(cfg, { baseUrl, apiVersion, accessToken, channelId, partnerId, merchantId, terminalId });

  const logFile = logResult('QR_MPM_QUERY', result.statusCode, body, result.body, headers);
  return {
    httpCode: result.statusCode,
    requestBody: body,
    responseBody: parsed !== null ? parsed : result.body,
    signature,
    timestamp: ts,
    url,
    headers,
    logFile,
  };
}

async function performCancel(cfg, input) {
  const baseUrl = input.baseUrl || cfg.baseUrl;
  const apiVersion = input.apiVersion || cfg.apiVersion;
  const accessToken = input.accessToken || cfg.accessToken;
  const channelId = input.channelId || cfg.channelId;
  const partnerId = input.partnerId || cfg.partnerId;
  const merchantId = input.merchantId || cfg.merchantId;
  const terminalId = input.terminalId || cfg.terminalId;
  const originalReferenceNo = input.originalReferenceNo || cfg.lastReferenceNo;
  const originalPartnerReferenceNo = input.originalPartnerReferenceNo || cfg.lastPartnerRef;
  // FIX FINAL: X-External-Id HEADER dan originalExternalId BODY harus SAMA PERSIS,
  // keduanya = externalId yang dipakai saat Generate (cfg.lastExternalIdGen).
  const originalExternalId = input.originalExternalId || cfg.lastExternalIdGen;
  const externalId = input.externalId || originalExternalId;
  const reason = input.reason || 'Customer';
  const refundValue = input.refundValue || cfg.lastAmount || '10000.00';
  const currency = input.currency || 'IDR';
  const originalTransactionDate = input.originalTransactionDate || cfg.lastTrxDate || dateYYYYMMDD();
  const originalApprovalCode = input.originalApprovalCode || cfg.lastApprovalCode || '';

  const relativeUrl = `/qrissnapmpm/${apiVersion}/v2.0/qr/qr-mpm-cancel`;
  const url = `${baseUrl}${relativeUrl}`;
  const ts = timestampNow();
  const body = JSON.stringify({
    originalReferenceNo,
    originalPartnerReferenceNo,
    originalExternalId,
    merchantId,
    reason,
    refundAmount: { value: refundValue, currency },
    additionalInfo: { originalTransactionDate, terminalId, originalApprovalCode },
  });

  const signature = await resolveSignature({
    kind: 'symmetric',
    cfg,
    manualOverride: input.signature,
    args: { method: 'POST', relativeUrl, accessToken, body, ts },
  });

  const headers = {
    Authorization: `Bearer ${accessToken}`,
    'Content-Type': 'application/json',
    'X-Timestamp': ts,
    'X-Signature': signature,
    'X-External-Id': externalId,
    'X-Partner-Id': partnerId,
    'Channel-Id': channelId,
  };
  if (cfg.platform) headers['X-Platform'] = cfg.platform;

  const result = await httpRequest({ url, method: 'POST', headers, body, insecure: !!cfg.allowInsecureTLS });
  const parsed = tryParseJSON(result.body);

  // Tidak menulis externalId ke cfg karena setiap request pakai externalId unik.
  Object.assign(cfg, { baseUrl, apiVersion, accessToken, channelId, partnerId, merchantId, terminalId });
  cfg.lastApprovalCode = originalApprovalCode;

  const logFile = logResult('QR_MPM_CANCEL', result.statusCode, body, result.body, headers);
  return {
    httpCode: result.statusCode,
    requestBody: body,
    responseBody: parsed !== null ? parsed : result.body,
    signature,
    timestamp: ts,
    url,
    headers,
    logFile,
  };
}

// ============================== EXPRESS APP ==============================
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));

const SESSION_SECRET = crypto.randomBytes(32).toString('hex');
app.use(
  session({
    secret: SESSION_SECRET,
    resave: false,
    saveUninitialized: false,
    cookie: { maxAge: 1000 * 60 * 60 * 8, sameSite: 'lax' },
  })
);

function requireAuth(req, res, next) {
  if (req.session && req.session.user) return next();
  return res.status(401).json({ error: 'Sesi tidak ditemukan, silakan login kembali.' });
}

function loadAuth() {
  if (!fs.existsSync(AUTH_PATH)) return null;
  try {
    return JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
  } catch (e) {
    return null;
  }
}

// -------- Auth routes --------
app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  const auth = loadAuth();
  if (!auth) return res.status(500).json({ error: 'Kredensial admin belum dikonfigurasi di server.' });
  if (
    username &&
    username === auth.username &&
    password &&
    bcrypt.compareSync(String(password), auth.passwordHash)
  ) {
    req.session.user = username;
    return res.json({ success: true });
  }
  return res.status(401).json({ error: 'Username atau password salah.' });
});

app.post('/api/logout', (req, res) => {
  req.session.destroy(() => res.json({ success: true }));
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.user });
});

// FIX: Endpoint untuk menyimpan/update domain manual dari Web Panel
app.post('/api/set-domain', requireAuth, (req, res) => {
  const { domain } = req.body || {};
  if (!domain || !domain.trim()) {
    // Hapus file .domain jika domain dikosongkan (kembali ke mode IP:PORT)
    try { if (fs.existsSync(DOMAIN_PATH)) fs.unlinkSync(DOMAIN_PATH); } catch (e) {}
    return res.json({ success: true, domain: null, message: 'Domain dihapus, Callback URL kembali menggunakan IP:PORT.' });
  }
  const cleaned = domain.trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  try {
    fs.writeFileSync(DOMAIN_PATH, cleaned + '\n', 'utf8');
  } catch (e) {
    return res.status(500).json({ error: 'Gagal menyimpan domain: ' + e.message });
  }
  res.json({
    success: true,
    domain: cleaned,
    callbackUrl: 'https://' + cleaned + '/qr/qr-mpm-notify',
    message: 'Domain berhasil disimpan.',
  });
});

// FIX: Endpoint untuk membaca domain yang tersimpan saat SSL setup
// Frontend menggunakan ini agar Callback URL selalu menampilkan domain yang benar,
// bukan window.location.origin yang bisa salah jika diakses via IP:PORT
app.get('/api/panel-url', requireAuth, (req, res) => {
  let domain = '';
  try {
    if (fs.existsSync(DOMAIN_PATH)) {
      domain = fs.readFileSync(DOMAIN_PATH, 'utf8').trim();
    }
  } catch (e) {
    domain = '';
  }

  let panelUrl;
  if (domain) {
    // Domain sudah disetup via SSL → gunakan https://domain
    panelUrl = 'https://' + domain;
  } else {
    // Belum ada domain → fallback ke X-Forwarded-Proto/Host (jika di balik proxy)
    // atau ke IP:PORT dari request saat ini
    const proto = req.headers['x-forwarded-proto'] || req.protocol || 'http';
    const host  = req.headers['x-forwarded-host']  || req.headers['host'] || req.hostname;
    panelUrl = proto + '://' + host;
  }

  res.json({
    panelUrl,
    callbackUrl: panelUrl + '/qr/qr-mpm-notify',
    domain: domain || null,
    source: domain ? 'domain_file' : 'request_host',
  });
});

app.post('/api/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body || {};
  const auth = loadAuth();
  if (!auth) return res.status(500).json({ error: 'Kredensial admin belum dikonfigurasi.' });
  if (!bcrypt.compareSync(String(currentPassword || ''), auth.passwordHash)) {
    return res.status(400).json({ error: 'Password saat ini salah.' });
  }
  if (!newPassword || String(newPassword).length < 6) {
    return res.status(400).json({ error: 'Password baru minimal 6 karakter.' });
  }
  auth.passwordHash = bcrypt.hashSync(String(newPassword), 10);
  fs.writeFileSync(AUTH_PATH, JSON.stringify(auth, null, 2), 'utf8');
  res.json({ success: true });
});

// -------- Config routes --------
app.get('/api/config', requireAuth, (req, res) => {
  const cfg = loadConfig();
  res.json(cfg);
});

app.post('/api/config', requireAuth, (req, res) => {
  const cfg = loadConfig();
  const body = Object.assign({}, req.body || {});
  if (typeof body.privateKeyPem === 'string' && body.privateKeyPem.trim()) {
    const keyPath = path.join(KEYS_DIR, 'private_key.pem');
    fs.writeFileSync(keyPath, body.privateKeyPem.trim() + '\n', 'utf8');
    body.privateKeyPath = keyPath;
  }
  delete body.privateKeyPem;
  Object.assign(cfg, body);
  saveConfig(cfg);
  res.json({ success: true, config: cfg });
});

app.post('/api/toggle-signature-mode', requireAuth, (req, res) => {
  const cfg = loadConfig();
  cfg.signatureMode = cfg.signatureMode === 'auto' ? 'manual' : 'auto';
  saveConfig(cfg);
  res.json({ success: true, signatureMode: cfg.signatureMode });
});

// -------- Action routes --------
app.post('/api/access-token', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  try {
    const result = await performAccessToken(cfg, req.body || {});
    saveConfig(cfg);
    res.json({ success: true, ...result });
  } catch (e) {
    saveConfig(cfg);
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/qr-generate', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  try {
    const result = await performGenerate(cfg, req.body || {});
    saveConfig(cfg);
    res.json({ success: true, ...result });
  } catch (e) {
    saveConfig(cfg);
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/qr-query', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  try {
    const result = await performQuery(cfg, req.body || {});
    saveConfig(cfg);
    res.json({ success: true, ...result });
  } catch (e) {
    saveConfig(cfg);
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/qr-cancel', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  try {
    const result = await performCancel(cfg, req.body || {});
    saveConfig(cfg);
    res.json({ success: true, ...result });
  } catch (e) {
    saveConfig(cfg);
    res.status(400).json({ error: e.message });
  }
});

app.post('/api/full-flow', requireAuth, async (req, res) => {
  const cfg = loadConfig();
  if (cfg.signatureMode !== 'auto') {
    return res.status(400).json({
      error:
        'Full Flow otomatis butuh Signature Mode = "auto" (Private Key & Client Secret harus sudah diisi di Konfigurasi). ' +
        'Jika masih mode manual, jalankan Generate -> Query -> Cancel satu per satu di tab masing-masing.',
    });
  }
  const steps = {};
  try {
    // FIX: STEP 0 - Refresh Access Token otomatis sebelum flow dimulai
    // agar token selalu valid dan tidak expired
    steps.accessToken = await performAccessToken(cfg, (req.body && req.body.accessToken) || {});
    if (!cfg.accessToken) {
      saveConfig(cfg);
      return res.json({
        success: false,
        message: 'Gagal mendapatkan Access Token, flow dihentikan. Periksa Client Key, Auth Bearer, dan Private Key di Konfigurasi.',
        steps,
      });
    }

    // FIX: STEP 1 - Generate dengan partnerReferenceNo dari form, atau fallback ke cfg/default
    const generateInput = Object.assign({}, (req.body && req.body.generate) || {});
    steps.generate = await performGenerate(cfg, generateInput);
    if (!steps.generate.referenceNo) {
      saveConfig(cfg);
      return res.json({
        success: false,
        message: 'Generate tidak menghasilkan referenceNo, flow dihentikan. Pastikan partnerReferenceNo valid di sandbox.',
        steps,
      });
    }

    // FIX: STEP 2 - Query otomatis pakai referenceNo dari hasil Generate (sudah ada di cfg)
    steps.query = await performQuery(cfg, (req.body && req.body.query) || {});

    // FIX: STEP 3 - Cancel otomatis pakai referenceNo & partnerRef dari Generate
    steps.cancel = await performCancel(cfg, (req.body && req.body.cancel) || {});

    saveConfig(cfg);
    res.json({ success: true, steps });
  } catch (e) {
    saveConfig(cfg);
    res.status(400).json({ error: e.message, steps });
  }
});

// -------- Logs routes --------
app.get('/api/logs', requireAuth, (req, res) => {
  let files = [];
  try {
    files = fs.readdirSync(LOG_DIR).filter((f) => f.endsWith('.log'));
  } catch (e) {
    files = [];
  }
  files.sort().reverse();
  res.json({ files: files.slice(0, 100) });
});

app.get('/api/logs/:file', requireAuth, (req, res) => {
  const fname = path.basename(req.params.file);
  const fpath = path.join(LOG_DIR, fname);
  if (!fpath.startsWith(LOG_DIR) || !fs.existsSync(fpath)) {
    return res.status(404).json({ error: 'Log tidak ditemukan.' });
  }
  res.type('text/plain').send(fs.readFileSync(fpath, 'utf8'));
});

app.delete('/api/logs', requireAuth, (req, res) => {
  try {
    const files = fs.readdirSync(LOG_DIR).filter((f) => f.endsWith('.log'));
    files.forEach((f) => fs.unlinkSync(path.join(LOG_DIR, f)));
    res.json({ success: true, deleted: files.length });
  } catch (e) {
    res.status(500).json({ error: 'Gagal menghapus log: ' + e.message });
  }
});

// -------- Download Test Case (XLSX) --------
app.get('/api/download-testcase', requireAuth, async (req, res) => {
  try {
    const ExcelJS = require('exceljs');
    const wb = new ExcelJS.Workbook();
    wb.creator = 'QRIS SNAP MPM Web Panel';
    wb.created = new Date();

    // ---- Style sesuai contoh file SIT-QR_MPM_SNAP-_API_Test_Review ----
    const HDR_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF00B0F0' } };
    const HDR_FONT = { bold: true, color: { argb: 'FFFFFFFF' }, name: 'Calibri', size: 9 };
    const HDR_ALIGN = { horizontal: 'center', vertical: 'middle', wrapText: true };
    const BORDER_THIN = { style: 'thin', color: { argb: 'FF9E9E9E' } };
    const ALL_BORDER = { top: BORDER_THIN, left: BORDER_THIN, bottom: BORDER_THIN, right: BORDER_THIN };
    const ROW_FILL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE3EFF9' } };
    const STATUS_PASS = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFC6EFCE' } };
    const STATUS_FAIL = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFC7CE' } };
    const STATUS_NA = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };

    // ---- Data test case (sesuai contoh SIT-QR_MPM_SNAP-_API_Test_Review) ----
    const TESTCASES = [
      { no: 1, case: 'QR Generation',           testCase: 'Regular Generate with  Amount',           expected: 'Success' },
      { no: 2, case: 'QR Inquiry Status',        testCase: 'Regular Inquiry Status Transaction',      expected: 'Success' },
      { no: 3, case: 'QR Payment Credit Refund', testCase: 'Reguler Payment Refund',                  expected: 'Success' },
      { no: 4, case: 'QR Payment Credit Notify', testCase: 'Payment Notify  ( MTI to Client )',       expected: 'Success' },
    ];

    // ---- Parse semua log file menjadi entri terstruktur, urut berdasarkan waktu ----
    function parseLogFile(fname) {
      const content = fs.readFileSync(path.join(LOG_DIR, fname), 'utf8');
      const lines = content.split('\n');
      let section = null;
      const hdrLines = [], reqLines = [], respLines = [];
      let httpCode = '', waktu = '';
      for (const line of lines) {
        if (line.startsWith('Waktu       :')) waktu = line.replace('Waktu       :', '').trim();
        if (line.startsWith('HTTP Code   :')) httpCode = line.replace('HTTP Code   :', '').trim();
        if (line.startsWith('---- Request Headers ----')) { section = 'hdr'; continue; }
        if (line.startsWith('---- Request Body ----')) { section = 'req'; continue; }
        if (line.startsWith('---- Response Body ----')) { section = 'resp'; continue; }
        if (section === 'hdr') hdrLines.push(line);
        else if (section === 'req') reqLines.push(line);
        else if (section === 'resp') respLines.push(line);
      }
      const reqStr = reqLines.join('\n').trim();
      const respStr = respLines.join('\n').trim();
      let reqHeaders = {};
      for (const hl of hdrLines) {
        const idx = hl.indexOf(':');
        if (idx > -1) reqHeaders[hl.slice(0, idx).trim().toLowerCase()] = hl.slice(idx + 1).trim();
      }
      let reqJson = null, respJson = null;
      try { reqJson = JSON.parse(reqStr); } catch (e) {}
      try { respJson = JSON.parse(respStr); } catch (e) {}

      const fnLower = fname.toLowerCase();
      let opType = null;
      if (fnLower.includes('generate')) opType = 'generate';
      else if (fnLower.includes('query')) opType = 'query';
      else if (fnLower.includes('cancel')) opType = 'cancel';
      else if (fnLower.includes('access_token')) opType = 'access_token';
      else if (fnLower.includes('payment_notify')) opType = 'notify';

      const externalId = reqHeaders['x-external-id'] || (reqJson && reqJson.originalExternalId) || '';
      const responseCode = (respJson && respJson.responseCode) || '';
      const trxTime = (respJson && (respJson.transactionTime || respJson.transTime)) || '';
      const trxDate = (reqJson && reqJson.additionalInfo && reqJson.additionalInfo.originalTransactionDate) ||
                       (respJson && respJson.transactionDate) || '';
      const success = !!httpCode && String(httpCode).trim() === '200' &&
                       (!responseCode || /^200/.test(responseCode));

      return {
        fname, opType, waktu, httpCode, reqStr, respStr, reqHeaders,
        externalId, responseCode, trxTime, trxDate, success,
      };
    }

    let logEntries = [];
    try {
      const logFiles = fs.readdirSync(LOG_DIR).filter((f) => f.endsWith('.log')).sort();
      logEntries = logFiles.map(parseLogFile);
    } catch (e) { /* log parsing optional */ }

    // Kelompokkan log per opType, urut kronologis, supaya bisa dipasangkan
    // secara berurutan ke test case sejenis (generate ke-1, ke-2, dst).
    const logByOp = { generate: [], query: [], cancel: [], notify: [] };
    for (const entry of logEntries) {
      if (logByOp[entry.opType]) logByOp[entry.opType].push(entry);
    }
    const opCursor = { generate: 0, query: 0, cancel: 0, notify: 0 };

    // Tentukan opType yang relevan untuk sebuah test case berdasarkan Case-nya
    function resolveOpType(tc) {
      if (tc.case === 'QR Generation') return 'generate';
      if (tc.case === 'QR Inquiry Status') return 'query';
      if (tc.case === 'QR Payment Credit Refund') return 'cancel';
      if (tc.case === 'QR Payment Credit Notify') return 'notify';
      return null;
    }

    // Ambil entri log berikutnya (berurutan) untuk opType test case ini
    function nextLogFor(tc) {
      const opType = resolveOpType(tc);
      if (!opType) return null;
      const arr = logByOp[opType] || [];
      const idx = opCursor[opType]++;
      return arr[idx] || null;
    }

    // ---- Sheet: Testcase (1 sheet, format persis mengikuti contoh "SIT-Open API") ----
    const ws = wb.addWorksheet('SIT-Open API ');
    ws.views = [{ state: 'frozen', ySplit: 1 }];

    const headersRow = ['No', 'Case', 'Test case', 'Expected Result', 'Actual Result',
      'Response Code', 'External ID', 'Transaction Time', 'Transaction Date',
      'Evidence - Request & Response Body ( LOG )', 'Status'];
    const colWidths = [4.09, 18.73, 44.63, 16.54, 16.45, 10.54, 9.82, 10.73, 8.91, 58.45, 8.54];
    ws.columns = headersRow.map((h, i) => ({ header: h, key: h, width: colWidths[i] }));

    ws.getRow(1).eachCell((cell, colNum) => {
      cell.fill = HDR_FILL;
      cell.font = HDR_FONT;
      cell.alignment = { horizontal: colNum === 2 ? 'left' : 'center', vertical: 'middle', wrapText: true };
      cell.border = ALL_BORDER;
    });
    ws.getRow(1).height = 29;

    TESTCASES.forEach((tc, i) => {
      const log = nextLogFor(tc);

      let actualResult = '', responseCode = '', externalId = '', trxTime = '', trxDate = '', evidence = '', status = 'Belum Diuji';

      if (log) {
        responseCode = log.responseCode || log.httpCode || '';
        externalId = log.externalId || '';
        trxTime = log.trxTime || (log.waktu ? log.waktu.split('T')[1] || '' : '');
        trxDate = log.trxDate || (log.waktu ? log.waktu.split('T')[0] || '' : '');
        actualResult = log.success ? 'Success' : 'Failed';
        evidence = `Request:\n${log.reqStr}\n\nResponse:\n${log.respStr}\n\n(log: ${log.fname})`;
        if (evidence.length > 3000) evidence = evidence.slice(0, 3000) + '\n... (lihat file log lengkap di server)';
        status = actualResult === tc.expected ? 'Pass' : 'Fail';
      }

      const row = ws.addRow([
        tc.no, tc.case || '', tc.testCase, tc.expected, actualResult,
        responseCode, externalId, trxTime, trxDate, evidence, status,
      ]);
      row.height = 27;

      // Horizontal alignment per kolom: persis seperti file contoh
      // A:left  B:left  C:left  D:center E:center F:center G:center H:center I:center J:left K:left
      const COL_ALIGN = { 1: 'left', 2: 'left', 3: 'left', 4: 'center', 5: 'center',
        6: 'center', 7: 'center', 8: 'center', 9: 'center', 10: 'left', 11: 'left' };

      row.eachCell({ includeEmpty: true }, (cell, colNum) => {
        cell.border = ALL_BORDER;
        cell.font = { name: 'Calibri', size: 9 };
        cell.fill = ROW_FILL;
        cell.alignment = { vertical: 'top', wrapText: true, horizontal: COL_ALIGN[colNum] };
        if (colNum === 11) {
          cell.font = { ...cell.font, bold: true };
          if (status === 'Pass') cell.fill = STATUS_PASS;
          else if (status === 'Fail') cell.fill = STATUS_FAIL;
          else cell.fill = STATUS_NA;
        }
      });
    });

    // ---- Kirim file ----
    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    const stamp = `${now.getFullYear()}${pad(now.getMonth()+1)}${pad(now.getDate())}_${pad(now.getHours())}${pad(now.getMinutes())}`;
    const filename = `QRISSNAPMPM_TestCase_${stamp}.xlsx`;

    res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    await wb.xlsx.write(res);
    res.end();
  } catch (e) {
    res.status(500).json({ error: 'Gagal generate test case: ' + e.message });
  }
});


// -------- Payment Notify Callback --------
const NOTIFY_LOG_PATH = path.join(INSTALL_DIR, 'notify-log.json');

function loadNotifications() {
  if (!fs.existsSync(NOTIFY_LOG_PATH)) return [];
  try { return JSON.parse(fs.readFileSync(NOTIFY_LOG_PATH, 'utf8')); }
  catch (e) { return []; }
}

function appendNotification(entry) {
  const list = loadNotifications();
  list.unshift(entry);
  if (list.length > 300) list.splice(300);
  fs.writeFileSync(NOTIFY_LOG_PATH, JSON.stringify(list, null, 2), 'utf8');
}

// Endpoint PUBLIC — dipanggil BMRI saat pembayaran QR berhasil.
// URL yang didaftarkan ke BMRI: https://<DOMAIN_ANDA>/qr/qr-mpm-notify
app.post('/qr/qr-mpm-notify', (req, res) => {
  const body = req.body || {};
  const entry = {
    receivedAt: new Date().toISOString(),
    ip: req.headers['x-forwarded-for'] || (req.socket && req.socket.remoteAddress) || '',
    headers: req.headers,
    body,
  };
  try {
    appendNotification(entry);
    logResult('PAYMENT_NOTIFY', 200, '(incoming callback)', JSON.stringify(body, null, 2), req.headers);
  } catch (e) { /* tetap balas 200 meski gagal simpan */ }
  // SNAP/BMRI mengharapkan HTTP 200 + responseCode "2005300"
  res.status(200).json({
    responseCode: '2005300',
    responseMessage: 'Request has been processed successfully',
  });
});

// Daftar notifikasi masuk (dilindungi login)
app.get('/api/notifications', requireAuth, (req, res) => {
  res.json({ notifications: loadNotifications() });
});

// Hapus semua notifikasi (dilindungi login)
app.delete('/api/notifications', requireAuth, (req, res) => {
  try {
    fs.writeFileSync(NOTIFY_LOG_PATH, '[]', 'utf8');
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ error: 'Gagal menghapus notifikasi: ' + e.message });
  }
});

// -------- Generate RSA Key Pair --------
app.post('/api/generate-keypair', requireAuth, (req, res) => {
  try {
    const { generateKeyPairSync } = crypto;
    const { privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding:  { type: 'spki',  format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const privPath = path.join(KEYS_DIR, 'private_key.pem');
    const pubPath  = path.join(KEYS_DIR, 'public_key.pem');
    fs.writeFileSync(privPath, privateKey, { encoding: 'utf8', mode: 0o600 });
    fs.writeFileSync(pubPath,  publicKey,  'utf8');
    // Auto-update config: privateKeyPath
    const cfg = loadConfig();
    cfg.privateKeyPath = privPath;
    saveConfig(cfg);
    res.json({ success: true, publicKey, privateKeyPath: privPath, publicKeyPath: pubPath });
  } catch (e) {
    res.status(500).json({ error: 'Gagal generate key pair: ' + e.message });
  }
});

// -------- Static frontend --------
app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
  res.sendFile ? res.sendFile(path.join(__dirname, 'public', 'index.html')) : res.redirect('/index.html');
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`QRIS SNAP MPM Web Panel berjalan di port ${PORT}`);
  console.log(`Install dir : ${INSTALL_DIR}`);
});
SRV_EOF

cat > "$WEB_DIR/public/style.css" << 'CSS_EOF'
:root {
  --bg: #0b1115;
  --panel: #131a20;
  --panel-2: #1a2228;
  --border: #243038;
  --text: #d8e2e8;
  --muted: #7c8a93;
  --cyan: #2dd4d4;
  --green: #34d399;
  --red: #f3514c;
  --yellow: #f2c94c;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
}

/* ---------- Login ---------- */
.login-body {
  height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
}
.login-card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 36px 32px;
  width: 320px;
  text-align: center;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.4);
}
.login-card h1 {
  color: var(--cyan);
  margin: 0 0 4px;
  font-size: 22px;
  letter-spacing: 0.5px;
}
.login-card .subtitle {
  color: var(--muted);
  margin: 0 0 22px;
  font-size: 13px;
}
.login-card form { display: flex; flex-direction: column; text-align: left; }
.login-card label { font-size: 12px; color: var(--muted); margin: 10px 0 4px; }
.login-card input {
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--text);
  padding: 10px 12px;
  border-radius: 8px;
  font-size: 14px;
}
.login-card button {
  margin-top: 18px;
  background: var(--cyan);
  color: #062222;
  font-weight: 600;
  border: none;
  padding: 11px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 14px;
}
.login-card button:hover { opacity: 0.9; }
.error-msg { color: var(--red); font-size: 13px; margin-top: 10px; min-height: 16px; }

/* ---------- Dashboard layout ---------- */
.app-shell { display: flex; min-height: 100vh; }

.sidebar {
  width: 220px;
  background: var(--panel);
  border-right: 1px solid var(--border);
  padding: 20px 0;
  flex-shrink: 0;
}
.sidebar h2 {
  color: var(--cyan);
  font-size: 16px;
  padding: 0 20px 16px;
  margin: 0;
  border-bottom: 1px solid var(--border);
}
.nav-item {
  display: block;
  padding: 12px 20px;
  color: var(--muted);
  cursor: pointer;
  font-size: 14px;
  border-left: 3px solid transparent;
}
.nav-item:hover { color: var(--text); background: var(--panel-2); }
.nav-item.active {
  color: var(--cyan);
  border-left-color: var(--cyan);
  background: var(--panel-2);
}
.sidebar .logout-btn {
  margin: 20px 20px 0;
  width: calc(100% - 40px);
  background: transparent;
  border: 1px solid var(--border);
  color: var(--muted);
  padding: 8px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 13px;
}
.sidebar .logout-btn:hover { color: var(--red); border-color: var(--red); }

.main { flex: 1; padding: 24px 32px; max-width: 980px; }

.status-bar {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px 18px;
  margin-bottom: 22px;
  display: grid;
  grid-template-columns: repeat(5, 1fr);
  gap: 10px;
  font-size: 13px;
}
.status-bar .label { color: var(--muted); display: block; font-size: 11px; }
.status-bar .value { color: var(--text); font-weight: 600; word-break: break-all; }

.panel {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 20px 22px;
  margin-bottom: 20px;
}
.panel h3 {
  margin: 0 0 16px;
  color: var(--cyan);
  font-size: 15px;
  letter-spacing: 0.3px;
}
.section { display: none; }
.section.active { display: block; }

.form-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px 16px;
}
.field { display: flex; flex-direction: column; }
.field.full { grid-column: 1 / -1; }
.field label { font-size: 12px; color: var(--muted); margin-bottom: 5px; }
.field input, .field select, .field textarea {
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--text);
  padding: 9px 10px;
  border-radius: 7px;
  font-size: 13px;
  font-family: inherit;
}
.field textarea { resize: vertical; min-height: 80px; font-family: "SF Mono", Menlo, monospace; }

.btn-row { margin-top: 16px; display: flex; gap: 10px; flex-wrap: wrap; }
button.primary {
  background: var(--cyan);
  color: #062222;
  border: none;
  padding: 10px 18px;
  border-radius: 8px;
  font-weight: 600;
  cursor: pointer;
  font-size: 13px;
}
button.secondary {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text);
  padding: 10px 18px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 13px;
}
button.danger { color: var(--red); border-color: var(--red); }
button:hover { opacity: 0.88; }
button:disabled { opacity: 0.5; cursor: not-allowed; }

.result-box {
  margin-top: 16px;
  border-top: 1px solid var(--border);
  padding-top: 14px;
}
.badge {
  display: inline-block;
  padding: 3px 10px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 700;
  margin-right: 8px;
}
.badge.pass { background: rgba(52, 211, 153, 0.15); color: var(--green); }
.badge.fail { background: rgba(243, 81, 76, 0.15); color: var(--red); }
.badge.info { background: rgba(45, 212, 212, 0.15); color: var(--cyan); }

pre.code-block {
  background: #07090c;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 12px;
  font-size: 12px;
  overflow-x: auto;
  max-height: 320px;
  color: #b9c4cb;
  font-family: "SF Mono", Menlo, monospace;
  white-space: pre-wrap;
  word-break: break-all;
}

.meta-line { font-size: 12px; color: var(--muted); margin: 4px 0; }
.meta-line b { color: var(--text); }

table.headers-table {
  width: 100%;
  border-collapse: collapse;
  margin: 8px 0 14px;
  font-size: 12.5px;
  font-family: "SF Mono", Menlo, monospace;
}
table.headers-table th {
  text-align: left;
  color: var(--muted);
  font-weight: 600;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.4px;
  padding: 6px 10px;
  border-bottom: 1px solid var(--border);
}
table.headers-table td {
  padding: 7px 10px;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
  word-break: break-all;
}
table.headers-table td.hk {
  color: var(--cyan);
  white-space: nowrap;
  width: 1%;
  font-weight: 600;
}
table.headers-table td.hv { color: #b9c4cb; }
table.headers-table tr:last-child td { border-bottom: none; }

.logs-list { list-style: none; padding: 0; margin: 0; }
.logs-list li {
  padding: 9px 12px;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  font-size: 13px;
  color: var(--muted);
}
.logs-list li:hover { color: var(--cyan); background: var(--panel-2); }

.hint {
  font-size: 12px;
  color: var(--muted);
  margin-top: 6px;
}
.checkbox-row { display: flex; align-items: center; gap: 8px; font-size: 13px; }

@media (max-width: 800px) {
  .app-shell { flex-direction: column; }
  .sidebar { width: 100%; display: flex; overflow-x: auto; padding: 10px 0; }
  .sidebar h2 { display: none; }
  .nav-item { white-space: nowrap; border-left: none; border-bottom: 3px solid transparent; }
  .nav-item.active { border-left: none; border-bottom-color: var(--cyan); }
  .status-bar { grid-template-columns: 1fr 1fr; }
  .form-grid { grid-template-columns: 1fr; }
  .main { padding: 16px; }
}
CSS_EOF

cat > "$WEB_DIR/public/login.html" << 'LOGIN_EOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Login - QRIS SNAP MPM Panel</title>
<link rel="stylesheet" href="style.css" />
</head>
<body class="login-body">
  <div class="login-card">
    <h1>QRIS SNAP MPM</h1>
    <p class="subtitle">Integration Test Web Panel</p>
    <form id="loginForm">
      <label>Username</label>
      <input type="text" id="username" autocomplete="username" required />
      <label>Password</label>
      <input type="password" id="password" autocomplete="current-password" required />
      <button type="submit">Masuk</button>
      <div id="loginError" class="error-msg"></div>
    </form>
  </div>
<script>
document.getElementById('loginForm').addEventListener('submit', async function (e) {
  e.preventDefault();
  const username = document.getElementById('username').value;
  const password = document.getElementById('password').value;
  const errEl = document.getElementById('loginError');
  errEl.textContent = '';
  try {
    const res = await fetch('/api/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, password }),
    });
    const data = await res.json();
    if (res.ok && data.success) {
      window.location.href = '/index.html';
    } else {
      errEl.textContent = data.error || 'Login gagal.';
    }
  } catch (err) {
    errEl.textContent = 'Tidak bisa menghubungi server.';
  }
});
</script>
</body>
</html>
LOGIN_EOF

cat > "$WEB_DIR/public/index.html" << 'INDEX_EOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>QRIS SNAP MPM - Web Panel</title>
<link rel="stylesheet" href="style.css" />
</head>
<body>
<div class="app-shell">
  <div class="sidebar">
    <h2>QRIS SNAP MPM</h2>
    <span class="nav-item active" data-target="dashboard">Dashboard</span>
    <span class="nav-item" data-target="config">Konfigurasi</span>
    <span class="nav-item" data-target="access-token">Get Access Token</span>
    <span class="nav-item" data-target="generate">QR-MPM-Generate</span>
    <span class="nav-item" data-target="query">QR-MPM-Query</span>
    <span class="nav-item" data-target="cancel">QR-MPM-Cancel</span>
    <span class="nav-item" data-target="full-flow">Full Flow Test</span>
    <span class="nav-item" data-target="logs">Riwayat Log</span>
    <span class="nav-item" data-target="testcase">Download Test Case</span>
    <span class="nav-item" data-target="notify">&#128276; Payment Notify</span>
    <span class="nav-item" data-target="account">Akun</span>
    <button class="logout-btn" id="logoutBtn">Logout</button>
  </div>

  <div class="main">
    <div class="status-bar" id="statusBar">
      <div><span class="label">Base URL</span><span class="value" id="statBaseUrl">-</span></div>
      <div><span class="label">Partner ID</span><span class="value" id="statPartnerId">-</span></div>
      <div><span class="label">Merchant ID</span><span class="value" id="statMerchantId">-</span></div>
      <div><span class="label">Access Token</span><span class="value" id="statToken">-</span></div>
      <div><span class="label">Signature Mode</span><span class="value" id="statSigMode">-</span></div>
    </div>

    <!-- DASHBOARD -->
    <div class="section active" id="section-dashboard">
      <div class="panel">
        <h3>Selamat datang</h3>
        <p class="hint">
          Panel ini adalah versi web dari <b>qris-test.sh</b> untuk menguji integrasi QRIS SNAP MPM
          (Access Token, QR Generate, QR Query, QR Cancel) ke sandbox Yokke. Mulai dengan mengisi
          tab <b>Konfigurasi</b>, lalu jalankan endpoint satu per satu, atau gunakan <b>Full Flow Test</b>.
        </p>
      </div>
    </div>

    <!-- KONFIGURASI -->
    <div class="section" id="section-config">
      <div class="panel">
        <h3>Konfigurasi Umum</h3>
        <div class="form-grid" id="configForm">
          <div class="field"><label>Base URL</label><input data-cfg="baseUrl" /></div>
          <div class="field"><label>API Version</label><input data-cfg="apiVersion" /></div>
          <div class="field"><label>X-Client-Key</label><input data-cfg="clientKey" /></div>
          <div class="field"><label>Client Secret (symmetric/auto)</label><input data-cfg="clientSecret" type="password" /></div>
          <div class="field"><label>X-Partner-Id</label><input data-cfg="partnerId" /></div>
          <div class="field"><label>Channel-Id</label><input data-cfg="channelId" /></div>
          <div class="field"><label>X-External-Id</label><input data-cfg="externalId" /></div>
          <div class="field"><label>X-Platform</label><input data-cfg="platform" /></div>
          <div class="field"><label>Merchant ID default</label><input data-cfg="merchantId" /></div>
          <div class="field"><label>Terminal ID default</label><input data-cfg="terminalId" /></div>
          <div class="field"><label>Authorization Bearer (Access Token endpoint)</label><input data-cfg="authBearer" /></div>
          <div class="field"><label>Access Token (tersimpan otomatis)</label><input data-cfg="accessToken" /></div>
          <div class="field">
            <label>Signature Mode</label>
            <select data-cfg="signatureMode">
              <option value="manual">manual (saya paste sendiri)</option>
              <option value="auto">auto (generate via Private Key / Client Secret)</option>
            </select>
          </div>
          <div class="field">
            <label class="checkbox-row"><input type="checkbox" data-cfg="allowInsecureTLS" style="width:auto" /> Izinkan sertifikat TLS tidak valid (insecure)</label>
          </div>
          <div class="field full">
            <label>Path Private Key (.pem) — atau paste isi key di bawah</label>
            <input data-cfg="privateKeyPath" placeholder="/root/qris-snap-test/keys/private_key.pem" />
          </div>
          <div class="field full">
            <label>Paste isi Private Key PEM (opsional, akan disimpan ke server & path di atas otomatis terisi)</label>
            <textarea id="privateKeyPem" placeholder="-----BEGIN PRIVATE KEY-----..."></textarea>
          </div>
        </div>
        <div class="btn-row">
          <button class="primary" id="saveConfigBtn">Simpan Konfigurasi</button>
          <button class="secondary" id="reloadConfigBtn">Muat Ulang</button>
        </div>
        <div id="configMsg" class="hint"></div>
      </div>

      <div class="panel">
        <h3>&#128273; Generate RSA Key Pair</h3>
        <p class="hint">
          Buat pasangan RSA 2048-bit langsung dari server. <b>Private Key</b> disimpan otomatis di server
          dan path-nya langsung terisi di Konfigurasi. <b>Public Key</b> harus dikirim ke
          BMRI/Yokke via email <b>ecommerce@yokke.co.id</b> (cc: application.support@yokke.co.id)
          bersama Callback URL untuk tahap UAT.
        </p>
        <div class="btn-row">
          <button class="secondary" id="generateKeyPairBtn">&#9881; Generate Key Pair Baru (RSA 2048-bit)</button>
        </div>
        <div id="keypairMsg" class="hint" style="min-height:18px;margin-top:6px;"></div>
        <div id="keypairResult" style="display:none;margin-top:14px;">
          <div class="meta-line">&#128274; <b>Private Key</b>: tersimpan di server &mdash; path otomatis terisi di Konfigurasi di atas.</div>
          <div class="meta-line" style="margin-top:12px;">&#128275; <b>Public Key</b> &mdash; salin dan kirim ke BMRI/Yokke via email:</div>
          <textarea id="publicKeyOutput" readonly style="width:100%;height:168px;margin-top:6px;background:var(--panel-2);border:1px solid var(--border);color:var(--green);padding:10px 12px;border-radius:8px;font-family:'SF Mono',Menlo,monospace;font-size:12px;resize:vertical;"></textarea>
          <div class="btn-row" style="margin-top:8px;">
            <button class="secondary" id="copyPublicKeyBtn">&#128203; Salin Public Key</button>
          </div>
          <div id="copyKeyMsg" class="hint"></div>
        </div>
      </div>
    </div>

    <!-- ACCESS TOKEN -->
    <div class="section" id="section-access-token">
      <div class="panel">
        <h3>Get Access Token</h3>
        <div class="form-grid" id="form-access-token">
          <div class="field"><label>Base URL</label><input data-f="baseUrl" /></div>
          <div class="field"><label>API Version</label><input data-f="apiVersion" /></div>
          <div class="field"><label>X-Client-Key</label><input data-f="clientKey" /></div>
          <div class="field"><label>Authorization Bearer</label><input data-f="authBearer" /></div>
          <div class="field"><label>X-Platform</label><input data-f="platform" /></div>
          <div class="field full manual-sig"><label>X-Signature (manual, jika mode = manual)</label><input data-f="signature" data-default="C94w/a2rvKcJn2EZ6wkuWaEc9SGiQLWYcUjqp70lWGTP4jNQ3bUw4FkdHyCGJwlPVvcLNShkGPr/AjHVJpQAHQ==" /></div>
        </div>
        <div class="btn-row"><button class="primary run-btn" data-endpoint="/api/access-token" data-form="form-access-token">Kirim Request</button></div>
        <div class="result-box" id="result-access-token"></div>
      </div>
    </div>

    <!-- GENERATE -->
    <div class="section" id="section-generate">
      <div class="panel">
        <h3>QR-MPM-Generate (Buat QR)</h3>
        <div class="form-grid" id="form-generate">
          <div class="field"><label>Base URL</label><input data-f="baseUrl" /></div>
          <div class="field"><label>API Version</label><input data-f="apiVersion" /></div>
          <div class="field"><label>Access Token</label><input data-f="accessToken" /></div>
          <div class="field"><label>Channel-Id</label><input data-f="channelId" /></div>
          <div class="field"><label>X-External-Id</label><input data-f="externalId" /></div>
          <div class="field"><label>X-Partner-Id</label><input data-f="partnerId" /></div>
          <div class="field"><label>Merchant ID</label><input data-f="merchantId" /></div>
          <div class="field"><label>Terminal ID</label><input data-f="terminalId" /></div>
          <div class="field"><label>Partner Reference No</label><input data-f="partnerReferenceNo" data-default="230218123798000" /></div>
          <div class="field"><label>Amount value</label><input data-f="amountValue" data-default="10000.00" /></div>
          <div class="field"><label>Fee Amount value</label><input data-f="feeValue" data-default="10000.00" /></div>
          <div class="field"><label>Currency</label><input data-f="currency" data-default="IDR" /></div>
          <div class="field full manual-sig"><label>X-Signature (manual, jika mode = manual)</label><input data-f="signature" data-default="C94w/a2rvKcJn2EZ6wkuWaEc9SGiQLWYcUjqp70lWGTP4jNQ3bUw4FkdHyCGJwlPVvcLNShkGPr/AjHVJpQAHQ==" /></div>
        </div>
        <div class="btn-row"><button class="primary run-btn" data-endpoint="/api/qr-generate" data-form="form-generate">Kirim Request</button></div>
        <div class="result-box" id="result-generate"></div>
      </div>
    </div>

    <!-- QUERY -->
    <div class="section" id="section-query">
      <div class="panel">
        <h3>QR-MPM-Query (Cek Status Transaksi)</h3>
        <div class="form-grid" id="form-query">
          <div class="field"><label>Base URL</label><input data-f="baseUrl" /></div>
          <div class="field"><label>API Version</label><input data-f="apiVersion" /></div>
          <div class="field"><label>Access Token</label><input data-f="accessToken" /></div>
          <div class="field"><label>Channel-Id</label><input data-f="channelId" /></div>
          <div class="field"><label>X-External-Id</label><input data-f="externalId" /></div>
          <div class="field"><label>X-Partner-Id</label><input data-f="partnerId" /></div>
          <div class="field"><label>Merchant ID</label><input data-f="merchantId" /></div>
          <div class="field"><label>Terminal ID</label><input data-f="terminalId" /></div>
          <div class="field"><label>Original Reference No</label><input data-f="originalReferenceNo" data-default="908718002198" /></div>
          <div class="field"><label>Original External Id</label><input data-f="originalExternalId" /></div>
          <div class="field"><label>Service Code</label><input data-f="serviceCode" data-default="51" /></div>
          <div class="field"><label>Original Transaction Date (YYYYMMDD)</label><input data-f="originalTransactionDate" /></div>
          <div class="field full manual-sig"><label>X-Signature (manual, jika mode = manual)</label><input data-f="signature" data-default="C94w/a2rvKcJn2EZ6wkuWaEc9SGiQLWYcUjqp70lWGTP4jNQ3bUw4FkdHyCGJwlPVvcLNShkGPr/AjHVJpQAHQ==" /></div>
        </div>
        <div class="btn-row"><button class="primary run-btn" data-endpoint="/api/qr-query" data-form="form-query">Kirim Request</button></div>
        <div class="result-box" id="result-query"></div>
      </div>
    </div>

    <!-- CANCEL -->
    <div class="section" id="section-cancel">
      <div class="panel">
        <h3>QR-MPM-Cancel (Refund/Cancel)</h3>
        <div class="form-grid" id="form-cancel">
          <div class="field"><label>Base URL</label><input data-f="baseUrl" /></div>
          <div class="field"><label>API Version</label><input data-f="apiVersion" /></div>
          <div class="field"><label>Access Token</label><input data-f="accessToken" /></div>
          <div class="field"><label>Channel-Id</label><input data-f="channelId" /></div>
          <div class="field"><label>X-External-Id</label><input data-f="externalId" /></div>
          <div class="field"><label>X-Partner-Id</label><input data-f="partnerId" /></div>
          <div class="field"><label>Merchant ID</label><input data-f="merchantId" /></div>
          <div class="field"><label>Terminal ID</label><input data-f="terminalId" /></div>
          <div class="field"><label>Original Reference No</label><input data-f="originalReferenceNo" data-default="955975998009" /></div>
          <div class="field"><label>Original Partner Reference No</label><input data-f="originalPartnerReferenceNo" data-default="230218123798000" /></div>
          <div class="field"><label>Original External Id</label><input data-f="originalExternalId" data-default="955975998009001" /></div>
          <div class="field"><label>Reason</label><input data-f="reason" data-default="Customer" /></div>
          <div class="field"><label>Refund Amount value</label><input data-f="refundValue" data-default="10000.00" /></div>
          <div class="field"><label>Currency</label><input data-f="currency" data-default="IDR" /></div>
          <div class="field"><label>Original Transaction Date (YYYYMMDD)</label><input data-f="originalTransactionDate" /></div>
          <div class="field"><label>Original Approval Code</label><input data-f="originalApprovalCode" data-default="142403" /></div>
          <div class="field full manual-sig"><label>X-Signature (manual, jika mode = manual)</label><input data-f="signature" data-default="C94w/a2rvKcJn2EZ6wkuWaEc9SGiQLWYcUjqp70lWGTP4jNQ3bUw4FkdHyCGJwlPVvcLNShkGPr/AjHVJpQAHQ==" /></div>
        </div>
        <div class="btn-row"><button class="primary run-btn" data-endpoint="/api/qr-cancel" data-form="form-cancel">Kirim Request</button></div>
        <div class="result-box" id="result-cancel"></div>
      </div>
    </div>

    <!-- FULL FLOW -->
    <div class="section" id="section-full-flow">
      <div class="panel">
        <h3>Full Flow Test: Access Token -> Generate -> Query -> Cancel</h3>
        <p class="hint">
          Membutuhkan Signature Mode = <b>auto</b> (Private Key &amp; Client Secret sudah terisi di Konfigurasi).
          Full Flow akan otomatis: <b>(1)</b> refresh Access Token, <b>(2)</b> Generate QR, <b>(3)</b> Query status,
          <b>(4)</b> Cancel/Refund &mdash; tanpa input manual.<br><br>
          <b>Penting:</b> Isi <b>Partner Reference No</b> di bawah dengan nilai yang sudah terdaftar di sandbox.
          Jika dikosongkan, akan menggunakan nilai yang tersimpan dari sesi Generate sebelumnya atau default sandbox.
        </p>
        <div class="form-grid" id="form-full-flow" style="margin-bottom:12px;">
          <div class="field">
            <label>Partner Reference No <span style="color:var(--cyan);font-size:11px;">(isi jika ingin override, kosongkan = pakai tersimpan/default)</span></label>
            <input id="ff-partnerReferenceNo" data-ff="partnerReferenceNo" placeholder="contoh: 230218123798000" />
          </div>
          <div class="field">
            <label>Amount Value <span style="color:var(--cyan);font-size:11px;">(opsional, default: 10000.00)</span></label>
            <input id="ff-amountValue" data-ff="amountValue" placeholder="10000.00" />
          </div>
          <div class="field">
            <label>Fee Amount Value <span style="color:var(--cyan);font-size:11px;">(opsional, default: 10000.00)</span></label>
            <input id="ff-feeValue" data-ff="feeValue" placeholder="10000.00" />
          </div>
        </div>
        <div class="btn-row"><button class="primary" id="runFullFlowBtn">&#9654; Jalankan Full Flow</button></div>
        <div class="result-box" id="result-full-flow"></div>
      </div>
    </div>

    <!-- LOGS -->
    <div class="section" id="section-logs">
      <div class="panel">
        <h3>Riwayat Log Test</h3>
        <div class="btn-row">
          <button class="secondary" id="refreshLogsBtn">Muat Ulang Daftar</button>
          <button class="secondary danger" id="clearLogsBtn">🗑 Bersihkan Semua Log</button>
        </div>
        <div id="clearLogsMsg" class="hint" style="min-height:18px;"></div>
        <ul class="logs-list" id="logsList"></ul>
        <div class="result-box" id="logDetail"></div>
      </div>
    </div>

    <!-- TEST CASE DOWNLOAD -->
    <div class="section" id="section-testcase">
      <div class="panel">
        <h3>Download Test Case (XLSX)</h3>
        <p class="hint">
          Mengunduh file Excel <b>QRISSNAPMPM_TestCase_[timestamp].xlsx</b> dengan 1 sheet <b>Testcase</b>,
          format mengikuti contoh review SIT &mdash; kolom: No, Case, Test case, Expected Result,
          <b>Actual Result</b>, Response Code, External ID, Transaction Time, Transaction Date,
          Evidence (Request &amp; Response Body LOG), dan Status.<br>
          Kolom Actual Result, Response Code, External ID, Transaction Time/Date, Evidence, dan Status
          akan <b>otomatis terisi</b> dari log hasil pengujian (Generate/Inquiry/Refund) yang tersimpan di server,
          dicocokkan berurutan sesuai kelompok test case-nya.
        </p>
        <div class="btn-row">
          <a id="downloadTCBtn" href="/api/download-testcase" class="primary" style="text-decoration:none;padding:10px 18px;border-radius:8px;font-weight:600;font-size:13px;background:var(--cyan);color:#062222;display:inline-block;">
            ⬇ Download Test Case (.xlsx)
          </a>
        </div>
        <div id="tcMsg" class="hint" style="margin-top:12px;"></div>
      </div>
    </div>

    <!-- PAYMENT NOTIFY -->
    <div class="section" id="section-notify">
      <div class="panel">
        <h3>&#128276; Payment Notify &mdash; Callback URL</h3>
        <p class="hint">
          Daftarkan URL di bawah ini ke BMRI sebagai <b>Callback URL</b>. Format sesuai instruksi:
          <code>https://&lt;DOMAIN_ANDA&gt;/qr/qr-mpm-notify</code>. Server akan menerima dan menyimpan
          setiap notifikasi pembayaran yang dikirim BMRI secara otomatis.
        </p>

        <!-- FIX: Panel set domain manual agar Callback URL selalu benar -->
        <div class="panel" style="background:var(--panel-2);margin-top:0;margin-bottom:14px;">
          <div class="meta-line" style="margin-bottom:8px;">
            <b>&#127758; Pengaturan Domain Panel</b>
            <span id="domainSourceBadge" class="hint" style="margin-left:8px;"></span>
          </div>
          <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
            <input id="domainInput" type="text"
              placeholder="contoh: qris.example.com (tanpa https://)"
              style="flex:1;min-width:200px;padding:8px 12px;border-radius:6px;border:1px solid var(--border);background:var(--bg);color:var(--fg);font-size:13px;" />
            <button class="primary" id="saveDomainBtn" style="white-space:nowrap;">&#128190; Simpan Domain</button>
            <button class="secondary" id="clearDomainBtn" style="white-space:nowrap;">&#10006; Hapus Domain</button>
          </div>
          <div id="domainMsg" class="hint" style="margin-top:6px;min-height:18px;"></div>
          <div class="hint" style="margin-top:4px;">
            Isi domain jika sudah setup SSL/Nginx. Kosongkan untuk kembali menggunakan IP:PORT.
            Nilai ini disimpan di server dan dipakai otomatis untuk generate Callback URL di bawah.
          </div>
        </div>

        <div class="panel" style="background:var(--panel-2);margin-top:0;">
          <div class="meta-line"><b>Callback URL yang perlu didaftarkan ke BMRI (email ke ecommerce@yokke.co.id):</b></div>
          <pre class="code-block" id="notifyCallbackUrl" style="max-height:56px;cursor:pointer;" title="Klik untuk salin">Memuat...</pre>
          <div class="hint" style="margin-top:6px;">
            Pastikan port 80 dan 443 terbuka di firewall dan sudah menggunakan HTTPS via Nginx + Certbot agar BMRI bisa mengakses URL ini.
            Klik URL di atas untuk menyalinnya ke clipboard.
          </div>
        </div>
      </div>

      <div class="panel">
        <h3>Riwayat Notifikasi Masuk</h3>
        <div class="btn-row">
          <button class="secondary" id="refreshNotifyBtn">&#8635; Muat Ulang</button>
          <button class="secondary danger" id="clearNotifyBtn">&#128465; Hapus Semua</button>
        </div>
        <div id="notifyMsg" class="hint" style="min-height:18px;margin-top:6px;"></div>
        <div id="notifyCount" class="hint" style="margin-bottom:10px;"></div>
        <ul class="logs-list" id="notifyList"></ul>
        <div class="result-box" id="notifyDetail"></div>
      </div>
    </div>

    <!-- ACCOUNT -->
    <div class="section" id="section-account">
      <div class="panel">
        <h3>Ubah Password Admin</h3>
        <div class="form-grid">
          <div class="field"><label>Password Saat Ini</label><input id="curPass" type="password" /></div>
          <div class="field"><label>Password Baru (min. 6 karakter)</label><input id="newPass" type="password" /></div>
        </div>
        <div class="btn-row"><button class="primary" id="changePassBtn">Ubah Password</button></div>
        <div id="accountMsg" class="hint"></div>
      </div>
    </div>

  </div>
</div>
<script src="app.js"></script>
</body>
</html>
INDEX_EOF

cat > "$WEB_DIR/public/app.js" << 'APPJS_EOF'
(function () {
  'use strict';

  let currentConfig = {};

  async function api(url, opts) {
    const res = await fetch(url, Object.assign({ headers: { 'Content-Type': 'application/json' } }, opts));
    if (res.status === 401) {
      window.location.href = '/login.html';
      throw new Error('unauthorized');
    }
    let data = {};
    try { data = await res.json(); } catch (e) { /* may be plain text for logs */ }
    if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  }

  function fmtJson(v) {
    if (v === null || v === undefined) return '';
    if (typeof v === 'string') return v;
    try { return JSON.stringify(v, null, 2); } catch (e) { return String(v); }
  }

  function renderHeadersTable(headers) {
    if (!headers) return '';
    const rows = Object.keys(headers)
      .map((key) => {
        let val = headers[key];
        if (key.toLowerCase() === 'authorization') {
          val = '•'.repeat(24);
        }
        return (
          '<tr><td class="hk">' + escapeHtml(key) + '</td><td class="hv">' + escapeHtml(val) + '</td></tr>'
        );
      })
      .join('');
    return (
      '<div class="meta-line"><b>Headers:</b></div>' +
      '<table class="headers-table"><thead><tr><th>Key</th><th>Value</th></tr></thead>' +
      '<tbody>' + rows + '</tbody></table>'
    );
  }

  function renderResult(containerId, data, errorMsg) {
    const el = document.getElementById(containerId);
    if (errorMsg) {
      el.innerHTML =
        '<span class="badge fail">ERROR</span>' +
        '<div class="meta-line">' + escapeHtml(errorMsg) + '</div>';
      return;
    }
    const isPass = data.httpCode && String(data.httpCode)[0] === '2';
    let html = '';
    html += '<span class="badge ' + (isPass ? 'pass' : 'fail') + '">' + (isPass ? 'PASS' : 'FAIL') + '</span>';
    html += '<span class="badge info">HTTP ' + data.httpCode + '</span>';
    if (data.logFile) html += '<span class="meta-line" style="display:inline">&nbsp;log: ' + escapeHtml(data.logFile) + '</span>';
    if (data.url) html += '<div class="meta-line"><b>URL:</b> ' + escapeHtml(data.url) + '</div>';
    if (data.referenceNo) html += '<div class="meta-line"><b>referenceNo tersimpan:</b> ' + escapeHtml(data.referenceNo) + '</div>';
    html += renderHeadersTable(data.headers);
    html += '<div class="meta-line"><b>Request Body:</b></div><pre class="code-block">' + escapeHtml(fmtJson(data.requestBody)) + '</pre>';
    html += '<div class="meta-line"><b>Response Body:</b></div><pre class="code-block">' + escapeHtml(fmtJson(data.responseBody)) + '</pre>';
    el.innerHTML = html;
  }

  function escapeHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;');
  }

  function fillForm(formId, cfg) {
    const root = document.getElementById(formId);
    if (!root) return;
    root.querySelectorAll('[data-f]').forEach((input) => {
      const key = input.getAttribute('data-f');
      if (key === 'signature') return; // jangan auto-isi signature manual
      if (input.getAttribute('data-default')) return; // punya default sendiri, jangan ditimpa config
      if (cfg[key] !== undefined && cfg[key] !== null && input.value === '') {
        input.value = cfg[key];
      }
    });
  }

  function readForm(formId) {
    const root = document.getElementById(formId);
    const out = {};
    root.querySelectorAll('[data-f]').forEach((input) => {
      const key = input.getAttribute('data-f');
      if (input.value !== '') out[key] = input.value;
    });
    return out;
  }

  function updateStatusBar(cfg) {
    document.getElementById('statBaseUrl').textContent = cfg.baseUrl || '-';
    document.getElementById('statPartnerId').textContent = cfg.partnerId || '-';
    document.getElementById('statMerchantId').textContent = cfg.merchantId || '-';
    document.getElementById('statToken').textContent = cfg.accessToken ? 'tersimpan' : 'belum ada';
    document.getElementById('statSigMode').textContent = cfg.signatureMode || 'manual';
    document.querySelectorAll('.manual-sig').forEach((el) => {
      el.style.display = cfg.signatureMode === 'auto' ? 'none' : '';
    });
  }

  async function loadConfigIntoUI() {
    const cfg = await api('/api/config');
    currentConfig = cfg;
    Object.keys(cfg).forEach((key) => {
      const input = document.querySelector('#configForm [data-cfg="' + key + '"]');
      if (!input) return;
      if (input.type === 'checkbox') input.checked = !!cfg[key];
      else input.value = cfg[key] === undefined || cfg[key] === null ? '' : cfg[key];
    });
    ['form-access-token', 'form-generate', 'form-query', 'form-cancel'].forEach((id) => {
      document.querySelectorAll('#' + id + ' [data-f]').forEach((inp) => {
        inp.value = inp.getAttribute('data-default') || '';
      });
      fillForm(id, cfg);
    });
    updateStatusBar(cfg);
  }

  // ---------------- Navigation ----------------
  document.querySelectorAll('.nav-item').forEach((item) => {
    item.addEventListener('click', () => {
      document.querySelectorAll('.nav-item').forEach((i) => i.classList.remove('active'));
      document.querySelectorAll('.section').forEach((s) => s.classList.remove('active'));
      item.classList.add('active');
      document.getElementById('section-' + item.getAttribute('data-target')).classList.add('active');
      if (item.getAttribute('data-target') === 'logs') loadLogs();
      if (item.getAttribute('data-target') === 'notify') { loadNotifications(); loadNotifyUrl(); }
      if (item.getAttribute('data-target') === 'testcase') {
        document.getElementById('tcMsg').textContent = '';
      }
    });
  });

  // ---------------- Config ----------------
  document.getElementById('saveConfigBtn').addEventListener('click', async () => {
    const msgEl = document.getElementById('configMsg');
    msgEl.textContent = 'Menyimpan...';
    const payload = {};
    document.querySelectorAll('#configForm [data-cfg]').forEach((input) => {
      const key = input.getAttribute('data-cfg');
      payload[key] = input.type === 'checkbox' ? input.checked : input.value;
    });
    const pem = document.getElementById('privateKeyPem').value;
    if (pem.trim()) payload.privateKeyPem = pem;
    try {
      const res = await api('/api/config', { method: 'POST', body: JSON.stringify(payload) });
      currentConfig = res.config;
      updateStatusBar(currentConfig);
      msgEl.textContent = 'Konfigurasi tersimpan.';
      document.getElementById('privateKeyPem').value = '';
    } catch (e) {
      msgEl.textContent = 'Gagal menyimpan: ' + e.message;
    }
  });
  document.getElementById('reloadConfigBtn').addEventListener('click', loadConfigIntoUI);

  // ---------------- Generic run buttons ----------------
  document.querySelectorAll('.run-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const endpoint = btn.getAttribute('data-endpoint');
      const formId = btn.getAttribute('data-form');
      const resultId = 'result-' + formId.replace('form-', '');
      btn.disabled = true;
      btn.textContent = 'Mengirim...';
      try {
        const payload = readForm(formId);
        const data = await api(endpoint, { method: 'POST', body: JSON.stringify(payload) });
        renderResult(resultId, data, null);
        await loadConfigIntoUI();
      } catch (e) {
        renderResult(resultId, {}, e.message);
      } finally {
        btn.disabled = false;
        btn.textContent = 'Kirim Request';
      }
    });
  });

  // ---------------- Full flow ----------------
  document.getElementById('runFullFlowBtn').addEventListener('click', async () => {
    const btn = document.getElementById('runFullFlowBtn');
    const el = document.getElementById('result-full-flow');
    btn.disabled = true;
    btn.textContent = 'Menjalankan...';
    el.innerHTML = '<div class="meta-line">&#9654; Menjalankan Access Token &#8594; Generate &#8594; Query &#8594; Cancel...</div>';

    // Kumpulkan input override dari form Full Flow
    const ffPayload = {};
    const generateOverride = {};
    document.querySelectorAll('[data-ff]').forEach(function(inp) {
      const key = inp.getAttribute('data-ff');
      if (inp.value && inp.value.trim()) generateOverride[key] = inp.value.trim();
    });
    if (Object.keys(generateOverride).length > 0) ffPayload.generate = generateOverride;

    try {
      const data = await api('/api/full-flow', { method: 'POST', body: JSON.stringify(ffPayload) });
      let html = '';
      if (data.message) {
        html += '<div class="meta-line" style="color:var(--red);font-weight:bold;">&#9888; ' + escapeHtml(data.message) + '</div>';
      }

      // Tampilkan semua step termasuk accessToken
      const stepLabels = { accessToken: 'ACCESS TOKEN', generate: 'GENERATE', query: 'QUERY', cancel: 'CANCEL' };
      ['accessToken', 'generate', 'query', 'cancel'].forEach(function(step) {
        if (data.steps && data.steps[step]) {
          const s = data.steps[step];
          const isPass = s.httpCode && String(s.httpCode)[0] === '2';
          html += '<h4 style="color:var(--cyan);margin:18px 0 6px;text-transform:uppercase;font-size:12px;border-top:1px solid var(--border);padding-top:12px;">' + (stepLabels[step] || step) + '</h4>';
          html += '<span class="badge ' + (isPass ? 'pass' : 'fail') + '">' + (isPass ? 'PASS' : 'FAIL') + '</span>';
          html += '<span class="badge info">HTTP ' + s.httpCode + '</span>';
          if (s.logFile) html += '<span class="meta-line" style="display:inline">&nbsp;log: ' + escapeHtml(s.logFile) + '</span>';
          if (s.url) html += '<div class="meta-line"><b>URL:</b> ' + escapeHtml(s.url) + '</div>';
          if (s.referenceNo) html += '<div class="meta-line" style="color:var(--green);"><b>&#10003; referenceNo tersimpan:</b> ' + escapeHtml(s.referenceNo) + '</div>';
          html += renderHeadersTable(s.headers);
          html += '<div class="meta-line"><b>Request Body:</b></div><pre class="code-block">' + escapeHtml(fmtJson(s.requestBody)) + '</pre>';
          html += '<div class="meta-line"><b>Response Body:</b></div><pre class="code-block">' + escapeHtml(fmtJson(s.responseBody)) + '</pre>';
        }
      });

      // Tampilkan ringkasan hasil
      if (data.success) {
        html = '<div class="meta-line" style="color:var(--green);font-weight:bold;">&#10003; Full Flow berhasil! Semua step PASS.</div>' + html;
      }

      el.innerHTML = html || '<div class="meta-line">Tidak ada hasil.</div>';
      await loadConfigIntoUI();
    } catch (e) {
      el.innerHTML = '<span class="badge fail">ERROR</span><div class="meta-line">' + escapeHtml(e.message) + '</div>';
    } finally {
      btn.disabled = false;
      btn.textContent = '&#9654; Jalankan Full Flow';
    }
  });

  // ---------------- Logs ----------------
  async function loadLogs() {
    const data = await api('/api/logs');
    const list = document.getElementById('logsList');
    list.innerHTML = '';
    (data.files || []).forEach((f) => {
      const li = document.createElement('li');
      li.textContent = f;
      li.addEventListener('click', async () => {
        const res = await fetch('/api/logs/' + encodeURIComponent(f));
        const text = await res.text();
        document.getElementById('logDetail').innerHTML = '<pre class="code-block">' + escapeHtml(text) + '</pre>';
      });
      list.appendChild(li);
    });
  }
  document.getElementById('refreshLogsBtn').addEventListener('click', loadLogs);

  document.getElementById('clearLogsBtn').addEventListener('click', async () => {
    const msgEl = document.getElementById('clearLogsMsg');
    if (!confirm('Hapus semua file log? Tindakan ini tidak dapat dibatalkan.')) return;
    msgEl.textContent = 'Menghapus...';
    try {
      const data = await api('/api/logs', { method: 'DELETE', body: JSON.stringify({}) });
      msgEl.textContent = `✓ ${data.deleted} file log berhasil dihapus.`;
      document.getElementById('logsList').innerHTML = '';
      document.getElementById('logDetail').innerHTML = '';
    } catch (e) {
      msgEl.textContent = 'Gagal: ' + e.message;
    }
  });

  // ---------------- Download Test Case ----------------
  document.getElementById('downloadTCBtn').addEventListener('click', function (e) {
    const msgEl = document.getElementById('tcMsg');
    msgEl.textContent = 'Memproses dan mengunduh file...';
    // Lakukan fetch manual agar bisa deteksi error (non-200 response)
    fetch('/api/download-testcase')
      .then(function (res) {
        if (!res.ok) {
          return res.json().then(function (d) { throw new Error(d.error || 'HTTP ' + res.status); });
        }
        // Ambil filename dari header Content-Disposition
        const cd = res.headers.get('Content-Disposition') || '';
        const match = cd.match(/filename="?([^"]+)"?/);
        const fname = match ? match[1] : 'QRISSNAPMPM_TestCase.xlsx';
        return res.blob().then(function (blob) { return { blob, fname }; });
      })
      .then(function ({ blob, fname }) {
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = fname;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
        msgEl.textContent = '✓ File berhasil diunduh: ' + fname;
      })
      .catch(function (err) {
        msgEl.textContent = 'Gagal: ' + err.message;
      });
    e.preventDefault();
  });

  // ---------------- Generate Key Pair ----------------
  const _generateKeyPairBtn = document.getElementById('generateKeyPairBtn');
  if (_generateKeyPairBtn) _generateKeyPairBtn.addEventListener('click', async function() {
    const msgEl    = document.getElementById('keypairMsg');
    const resultEl = document.getElementById('keypairResult');
    const outputEl = document.getElementById('publicKeyOutput');
    if (!confirm('Generate key pair RSA 2048-bit baru?\nJika sudah ada key sebelumnya, file lama akan ditimpa.')) return;
    msgEl.textContent = 'Membuat RSA 2048-bit key pair di server...';
    resultEl.style.display = 'none';
    _generateKeyPairBtn.disabled = true;
    try {
      const data = await api('/api/generate-keypair', { method: 'POST', body: JSON.stringify({}) });
      msgEl.textContent = '\u2713 Key pair berhasil dibuat! Private key path otomatis tersimpan di Konfigurasi.';
      outputEl.value = data.publicKey || '';
      resultEl.style.display = 'block';
      await loadConfigIntoUI(); // refresh agar privateKeyPath field terupdate
    } catch (e) {
      msgEl.textContent = 'Gagal: ' + e.message;
    } finally {
      _generateKeyPairBtn.disabled = false;
    }
  });

  const _copyPublicKeyBtn = document.getElementById('copyPublicKeyBtn');
  if (_copyPublicKeyBtn) _copyPublicKeyBtn.addEventListener('click', function() {
    const outputEl  = document.getElementById('publicKeyOutput');
    const copyMsgEl = document.getElementById('copyKeyMsg');
    if (!outputEl.value) return;
    function fallback() {
      outputEl.select();
      try { document.execCommand('copy'); copyMsgEl.textContent = '\u2713 Public key berhasil disalin.'; }
      catch(e) { copyMsgEl.textContent = 'Salin manual dari kotak di atas.'; }
    }
    if (navigator.clipboard) {
      navigator.clipboard.writeText(outputEl.value)
        .then(function() { copyMsgEl.textContent = '\u2713 Public key berhasil disalin ke clipboard.'; })
        .catch(fallback);
    } else { fallback(); }
    setTimeout(function() { copyMsgEl.textContent = ''; }, 3000);
  });

  // ---------------- Payment Notify ----------------
  async function loadNotifications() {
    const notifyList = document.getElementById('notifyList');
    const notifyCount = document.getElementById('notifyCount');
    const notifyDetail = document.getElementById('notifyDetail');
    if (!notifyList) return;
    try {
      const data = await api('/api/notifications');
      const items = data.notifications || [];
      notifyCount.textContent = items.length
        ? items.length + ' notifikasi diterima (terbaru di atas). Klik item untuk lihat detail.'
        : 'Belum ada notifikasi masuk. Daftarkan Callback URL ke BMRI, lalu lakukan QR Generate yang sukses di SIT Sandbox.';
      notifyList.innerHTML = '';
      notifyDetail.innerHTML = '';
      items.forEach(function(n) {
        const li = document.createElement('li');
        const refNo = (n.body && (n.body.originalReferenceNo || n.body.referenceNo || n.body.partnerReferenceNo)) || '';
        const amount = (n.body && n.body.amount && n.body.amount.value) || '';
        const respCode = (n.body && n.body.responseCode) || '';
        const label = [
          n.receivedAt,
          refNo ? 'ref: ' + refNo : '',
          amount ? 'Rp ' + amount : '',
          respCode ? 'rc: ' + respCode : ''
        ].filter(Boolean).join('  |  ');
        li.textContent = label || JSON.stringify(n.body).slice(0, 80);
        li.style.fontFamily = '"SF Mono", Menlo, monospace';
        li.addEventListener('click', function() {
          notifyDetail.innerHTML =
            '<div class="meta-line"><b>Diterima:</b> ' + escapeHtml(n.receivedAt) + '</div>' +
            '<div class="meta-line"><b>IP Pengirim:</b> ' + escapeHtml(n.ip || '-') + '</div>' +
            renderHeadersTable(n.headers) +
            '<div class="meta-line"><b>Body Notifikasi:</b></div>' +
            '<pre class="code-block">' + escapeHtml(JSON.stringify(n.body, null, 2)) + '</pre>';
        });
        notifyList.appendChild(li);
      });
    } catch (e) {
      if (notifyCount) notifyCount.textContent = 'Gagal memuat notifikasi: ' + e.message;
    }
  }

  // FIX: loadNotifyUrl sekarang fetch /api/panel-url dari server
  // sehingga Callback URL selalu menampilkan domain yang benar (bukan window.location.origin)
  async function loadNotifyUrl() {
    const el = document.getElementById('notifyCallbackUrl');
    const domainInput = document.getElementById('domainInput');
    const domainSourceBadge = document.getElementById('domainSourceBadge');
    if (!el) return;

    try {
      const data = await api('/api/panel-url');

      // Tampilkan callback URL yang sudah benar
      el.textContent = data.callbackUrl || (window.location.origin + '/qr/qr-mpm-notify');

      // Isi input domain dengan nilai yang tersimpan
      if (domainInput && data.domain) {
        domainInput.value = data.domain;
      }

      // Tampilkan badge sumber
      if (domainSourceBadge) {
        if (data.source === 'domain_file') {
          domainSourceBadge.textContent = '✓ Menggunakan domain tersimpan: ' + data.domain;
          domainSourceBadge.style.color = 'var(--green)';
        } else {
          domainSourceBadge.textContent = 'ⓘ Domain belum diset, menggunakan host dari request (' + (data.panelUrl || '-') + ')';
          domainSourceBadge.style.color = 'var(--yellow, #f0c040)';
        }
      }
    } catch(e) {
      // Fallback ke window.location.origin jika API gagal
      el.textContent = window.location.origin + '/qr/qr-mpm-notify';
      if (domainSourceBadge) {
        domainSourceBadge.textContent = 'Gagal memuat URL dari server, menggunakan browser URL.';
        domainSourceBadge.style.color = 'var(--red)';
      }
    }

    // Klik untuk salin ke clipboard
    el.onclick = function() {
      try {
        navigator.clipboard.writeText(el.textContent);
        const orig = el.style.outline;
        el.style.outline = '2px solid var(--green)';
        setTimeout(function() { el.style.outline = orig; }, 800);
      } catch(e) {
        // fallback untuk browser lama
        const range = document.createRange();
        range.selectNodeContents(el);
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
        try { document.execCommand('copy'); } catch(e2) {}
      }
    };
  }

  // FIX: Handler tombol Simpan Domain
  const _saveDomainBtn = document.getElementById('saveDomainBtn');
  if (_saveDomainBtn) _saveDomainBtn.addEventListener('click', async function() {
    const domainInput = document.getElementById('domainInput');
    const domainMsg = document.getElementById('domainMsg');
    const domainVal = domainInput ? domainInput.value.trim() : '';
    domainMsg.textContent = 'Menyimpan...';
    try {
      const data = await api('/api/set-domain', { method: 'POST', body: JSON.stringify({ domain: domainVal }) });
      domainMsg.style.color = 'var(--green)';
      domainMsg.textContent = '✓ ' + (data.message || 'Domain berhasil disimpan.');
      // Refresh Callback URL
      await loadNotifyUrl();
    } catch(e) {
      domainMsg.style.color = 'var(--red)';
      domainMsg.textContent = 'Gagal: ' + e.message;
    }
    setTimeout(function() { if (domainMsg) domainMsg.textContent = ''; }, 4000);
  });

  // FIX: Handler tombol Hapus Domain (kembali ke mode IP:PORT)
  const _clearDomainBtn = document.getElementById('clearDomainBtn');
  if (_clearDomainBtn) _clearDomainBtn.addEventListener('click', async function() {
    const domainMsg = document.getElementById('domainMsg');
    const domainInput = document.getElementById('domainInput');
    if (!confirm('Hapus domain? Callback URL akan kembali menggunakan IP:PORT dari browser.')) return;
    domainMsg.textContent = 'Menghapus...';
    try {
      const data = await api('/api/set-domain', { method: 'POST', body: JSON.stringify({ domain: '' }) });
      domainMsg.style.color = 'var(--green)';
      domainMsg.textContent = '✓ ' + (data.message || 'Domain dihapus.');
      if (domainInput) domainInput.value = '';
      await loadNotifyUrl();
    } catch(e) {
      domainMsg.style.color = 'var(--red)';
      domainMsg.textContent = 'Gagal: ' + e.message;
    }
    setTimeout(function() { if (domainMsg) domainMsg.textContent = ''; }, 4000);
  });

  const _refreshNotifyBtn = document.getElementById('refreshNotifyBtn');
  if (_refreshNotifyBtn) _refreshNotifyBtn.addEventListener('click', loadNotifications);

  const _clearNotifyBtn = document.getElementById('clearNotifyBtn');
  if (_clearNotifyBtn) _clearNotifyBtn.addEventListener('click', async function() {
    const msgEl = document.getElementById('notifyMsg');
    if (!confirm('Hapus semua notifikasi yang tersimpan? Tindakan ini tidak dapat dibatalkan.')) return;
    msgEl.textContent = 'Menghapus...';
    try {
      await api('/api/notifications', { method: 'DELETE', body: JSON.stringify({}) });
      msgEl.textContent = '\u2713 Semua notifikasi berhasil dihapus.';
      await loadNotifications();
    } catch (e) {
      msgEl.textContent = 'Gagal: ' + e.message;
    }
  });

  // ---------------- Account ----------------
  document.getElementById('changePassBtn').addEventListener('click', async () => {
    const msgEl = document.getElementById('accountMsg');
    const currentPassword = document.getElementById('curPass').value;
    const newPassword = document.getElementById('newPass').value;
    msgEl.textContent = 'Memproses...';
    try {
      await api('/api/change-password', { method: 'POST', body: JSON.stringify({ currentPassword, newPassword }) });
      msgEl.textContent = 'Password berhasil diubah.';
      document.getElementById('curPass').value = '';
      document.getElementById('newPass').value = '';
    } catch (e) {
      msgEl.textContent = 'Gagal: ' + e.message;
    }
  });

  // ---------------- Logout ----------------
  document.getElementById('logoutBtn').addEventListener('click', async () => {
    await api('/api/logout', { method: 'POST', body: JSON.stringify({}) });
    window.location.href = '/login.html';
  });

  // ---------------- Init ----------------
  (async function init() {
    try {
      await api('/api/me');
    } catch (e) {
      return; // sudah redirect ke login
    }
    loadConfigIntoUI().catch(() => {});
  })();
})();
APPJS_EOF

echo "Semua file Web Panel berhasil ditulis."

# -----------------------------------------------------------------------------
# 7. Install dependency Node.js untuk Web Panel (express, express-session, bcryptjs)
# -----------------------------------------------------------------------------
echo
echo "Menginstall dependency Node.js untuk Web Panel (butuh koneksi internet)..."
(cd "$WEB_DIR" && npm install --no-audit --no-fund)
echo "Dependency Web Panel terinstall."

# -----------------------------------------------------------------------------
# 8. Setup kredensial admin Web Panel (auth.json) - hanya dibuat sekali
# -----------------------------------------------------------------------------
ADMIN_USER_DISPLAY=""
ADMIN_PASS_DISPLAY=""
AUTH_ALREADY_EXISTS=0

setup_auth() {
  if [ -f "$AUTH_JSON" ]; then
    AUTH_ALREADY_EXISTS=1
    echo "auth.json sudah ada, kredensial admin Web Panel TIDAK diubah."
    return
  fi

  local admin_user="admin"
  local admin_pass=""

  if [ -t 0 ]; then
    read -r -p "Username admin Web Panel [admin]: " input_user
    [ -n "$input_user" ] && admin_user="$input_user"
    read -r -p "Password admin Web Panel (ENTER = generate random): " input_pass
    [ -n "$input_pass" ] && admin_pass="$input_pass"
  fi

  if [ -z "$admin_pass" ]; then
    admin_pass=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c14)
  fi

  local hash
  hash=$(cd "$WEB_DIR" && node -e "const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync(process.argv[1],10));" "$admin_pass")

  jq -n --arg u "$admin_user" --arg h "$hash" '{username:$u, passwordHash:$h}' > "$AUTH_JSON"

  ADMIN_USER_DISPLAY="$admin_user"
  ADMIN_PASS_DISPLAY="$admin_pass"
  echo "Kredensial admin Web Panel berhasil dibuat."
}
setup_auth

# -----------------------------------------------------------------------------
# 9. Tentukan PORT Web Panel (default 3000, otomatis tanpa prompt)
# -----------------------------------------------------------------------------
EXISTING_PORT=""
[ -f "$WEB_DIR/.port" ] && EXISTING_PORT="$(cat "$WEB_DIR/.port")"
PORT_DEFAULT="${EXISTING_PORT:-3000}"
PORT_VALUE="$PORT_DEFAULT"

# Port otomatis 3000; override via: QRIS_PORT=xxxx ./install.sh
[ -n "${QRIS_PORT:-}" ] && PORT_VALUE="${QRIS_PORT}"
echo "$PORT_VALUE" > "$WEB_DIR/.port"

# -----------------------------------------------------------------------------
# 10. Jalankan Web Panel sebagai service systemd (jika root & systemctl ada),
#     atau berikan instruksi manual jika tidak.
# -----------------------------------------------------------------------------
SERVICE_NAME="qris-web.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
SERVICE_MODE="manual"

# systemctl bisa saja ADA sebagai binary tapi systemd TIDAK benar-benar jalan
# sebagai init (umum di sebagian VPS/container). Cek dulu sebelum dipakai,
# dan jangan biarkan kegagalan di sini menghentikan seluruh installer.
SYSTEMD_USABLE=0
if [ "$(id -u)" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
  if systemctl is-system-running >/dev/null 2>&1 || \
     systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded'; then
    SYSTEMD_USABLE=1
  fi
fi

if [ "$SYSTEMD_USABLE" -eq 1 ]; then
  NODE_BIN="$(command -v node)"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=QRIS SNAP MPM Web Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$WEB_DIR
ExecStart=$NODE_BIN $WEB_DIR/server.js
Environment=PORT=$PORT_VALUE
Environment=TZ=Asia/Jakarta
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  if systemctl daemon-reload 2>/dev/null \
     && systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 \
     && systemctl restart "$SERVICE_NAME" 2>/dev/null; then
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      SERVICE_MODE="systemd"
      echo "Web Panel berjalan sebagai service systemd: $SERVICE_NAME"
    else
      echo "Peringatan: service $SERVICE_NAME terpasang tapi gagal start."
      echo "Cek detail: systemctl status $SERVICE_NAME ; journalctl -u $SERVICE_NAME -n 50"
    fi
  else
    echo "Peringatan: gagal mendaftarkan service systemd, lanjut ke mode manual."
  fi
else
  echo "systemd tidak aktif/berjalan di sistem ini (atau bukan root)."
  echo "Web Panel TIDAK otomatis dijalankan sebagai service."
fi

if [ "$SERVICE_MODE" = "manual" ]; then
  echo "Mencoba menjalankan Web Panel secara langsung di background (nohup)..."
  ( cd "$WEB_DIR" && TZ=Asia/Jakarta PORT="$PORT_VALUE" nohup node server.js >> "$LOG_DIR/web-panel.out.log" 2>&1 & )
  sleep 1
  if curl -s --max-time 2 "http://127.0.0.1:$PORT_VALUE/" >/dev/null 2>&1; then
    echo "Web Panel berhasil dijalankan di background (PORT=$PORT_VALUE)."
    echo "Catatan: proses ini TIDAK otomatis restart jika VPS reboot. Gunakan pm2/systemd untuk produksi."
  else
    echo "Peringatan: belum bisa memverifikasi Web Panel berjalan. Jalankan manual:"
    echo "  cd $WEB_DIR && PORT=$PORT_VALUE node server.js"
  fi
fi

# -----------------------------------------------------------------------------
# 10b. Auto-restart semua layanan yang sudah berjalan sebelumnya
#      agar update kode (server.js, config) langsung aktif tanpa manual restart
# -----------------------------------------------------------------------------
echo
echo "Auto-restart layanan yang berjalan..."

# Restart systemd service jika aktif
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  systemctl restart "$SERVICE_NAME" 2>/dev/null &&     echo "[OK] $SERVICE_NAME di-restart via systemd." ||     echo "[WARN] Gagal restart $SERVICE_NAME via systemd."
fi

# Restart pm2 jika ada
if command -v pm2 >/dev/null 2>&1 && pm2 list 2>/dev/null | grep -q "qris-web"; then
  pm2 restart qris-web 2>/dev/null &&     echo "[OK] pm2 qris-web di-restart." ||     echo "[WARN] Gagal restart pm2 qris-web."
fi

# Restart nginx jika berjalan
if command -v nginx >/dev/null 2>&1 && pgrep nginx >/dev/null 2>&1; then
  nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || true
  echo "[OK] Nginx di-reload."
fi

# Restart nohup process jika ada (matikan lama, jalankan baru)
OLD_PIDS="$(pgrep -f "node.*server.js" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ] && [ "$SERVICE_MODE" != "systemd" ]; then
  echo "Menghentikan proses Web Panel lama (PID: $OLD_PIDS)..."
  kill $OLD_PIDS 2>/dev/null || true
  sleep 1
  ( cd "$WEB_DIR" && TZ=Asia/Jakarta PORT="$PORT_VALUE" nohup node server.js >> "$LOG_DIR/web-panel.out.log" 2>&1 & )
  sleep 1
  echo "[OK] Web Panel dijalankan ulang di background (PORT=$PORT_VALUE)."
fi

echo "Auto-restart selesai."

# -----------------------------------------------------------------------------
# 11. Ringkasan akhir
# -----------------------------------------------------------------------------
PUBLIC_IP="$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || true)"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="<IP-VPS-ANDA>"

echo
echo "=============================================="
echo " Instalasi selesai!"
echo "=============================================="
echo "Lokasi install      : $INSTALL_DIR"
echo "Config CLI (.env)   : $CONFIG_FILE"
echo "Config Web (.json)  : $CONFIG_JSON"
echo "Logs (dipakai bersama CLI & Web) : $LOG_DIR"
echo
echo "---- CLI ----"
echo "Jalankan via: cd $INSTALL_DIR && ./qris-test.sh"
echo "Atau cukup ketik: menu   (alias tersedia setelah source ~/.bashrc atau buka terminal baru)"
echo
echo "---- WEB PANEL ----"
echo "URL akses   : http://$PUBLIC_IP:$PORT_VALUE"
if [ "$AUTH_ALREADY_EXISTS" -eq 1 ]; then
  echo "Login       : kredensial admin sebelumnya tetap berlaku (tidak diubah)."
else
  echo "Login       : username = $ADMIN_USER_DISPLAY"
  echo "              password = $ADMIN_PASS_DISPLAY"
  echo "              (SIMPAN password ini, tidak ditampilkan lagi setelah ini)"
fi
if [ "$SERVICE_MODE" = "systemd" ]; then
  echo "Service     : systemctl status $SERVICE_NAME | restart $SERVICE_NAME | stop $SERVICE_NAME"
  echo "Log service : journalctl -u $SERVICE_NAME -f"
else
  echo "Mode        : dijalankan via nohup di background (lihat $LOG_DIR/web-panel.out.log)"
  echo "              TIDAK otomatis restart jika VPS reboot/crash."
  echo "Jalankan ulang manual jika perlu: cd $WEB_DIR && PORT=$PORT_VALUE node server.js"
  echo "Untuk produksi, disarankan pasang pm2: npm install -g pm2 && pm2 start server.js --name qris-web"
fi
echo
echo "PENTING - Keamanan:"
echo " 1. Pastikan port $PORT_VALUE terbuka di firewall jika perlu:"
echo "      ufw allow $PORT_VALUE/tcp"
echo " 2. Untuk akses lewat domain + HTTPS, gunakan menu CLI:"
echo "      Ketik 'menu' -> pilih 11) Kelola SSL & Domain"
echo "    atau jalankan manual: certbot --nginx -d yourdomain.com --email you@email.com --agree-tos"
echo " 3. Web Panel ini menyimpan Client Secret & Private Key di server (folder"
echo "    $KEYS_DIR dan $CONFIG_JSON) - jangan expose folder $INSTALL_DIR ke publik."
echo " 4. Ganti password admin lewat tab 'Akun' setelah login pertama kali."
echo
echo "Langkah selanjutnya:"
echo " 1. Buka http://$PUBLIC_IP:$PORT_VALUE di browser, login dengan kredensial di atas."
echo " 2. Isi tab 'Konfigurasi' (Client Key, Partner ID, Merchant ID, Secret/Private Key, dst)."
echo " 3. Jalankan 'Get Access Token', lalu coba 'QR-MPM-Generate' -> 'Query' -> 'Cancel'."
echo " 4. Atau gunakan 'Full Flow Test' jika Signature Mode sudah di-set ke 'auto'."
echo " 5. Semua hasil request/response tersimpan di folder logs/ (terlihat di tab 'Riwayat Log')."
echo " 6. Untuk pasang SSL/HTTPS: ketik 'menu' di terminal, pilih opsi 11."
echo
