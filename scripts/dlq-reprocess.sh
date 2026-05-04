#!/usr/bin/env bash
# =============================================================================
# dlq-reprocess.sh
# Reprocesses messages from the Dead Letter Queue (orders.dlq) back to the
# main orders queue. Used by:
#   - Argo CronWorkflow (every 5 minutes in production)
#   - Manual operator invocation for emergency reprocessing
#
# Usage:
#   ./scripts/dlq-reprocess.sh [--max N] [--dry-run] [--parking-lot-only]
#
# Environment variables:
#   RABBIT_HOST   — RabbitMQ hostname (default: localhost)
#   RABBIT_PORT   — Management API port (default: 15672)
#   RABBIT_USER   — Username (default: admin)
#   RABBIT_PASS   — Password (default: admin123)
#   MAX_RETRIES   — Max retry count before parking lot (default: 5)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
RABBIT_HOST="${RABBIT_HOST:-localhost}"
RABBIT_PORT="${RABBIT_PORT:-15672}"
RABBIT_USER="${RABBIT_USER:-admin}"
RABBIT_PASS="${RABBIT_PASS:-admin123}"
MAX_RETRIES="${MAX_RETRIES:-5}"
MAX_MESSAGES=100
DRY_RUN=false
PARKING_LOT_ONLY=false

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️${NC}  $*"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ❌${NC} $*"; }

# ── Arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)           MAX_MESSAGES="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true;      shift   ;;
    --parking-lot-only) PARKING_LOT_ONLY=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
BASE_URL="http://${RABBIT_HOST}:${RABBIT_PORT}/api"
AUTH="${RABBIT_USER}:${RABBIT_PASS}"

rabbit_get() {
  curl -sf -u "$AUTH" "$BASE_URL/$1"
}

queue_depth() {
  local queue="$1"
  rabbit_get "queues/%2F/${queue}" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('messages',0))" 2>/dev/null || echo "0"
}

publish_to_queue() {
  local queue="$1"
  local payload="$2"
  local retry_count="$3"
  local reason="${4:-reprocessed}"

  if [ "$DRY_RUN" = "true" ]; then
    warn "[DRY RUN] Would publish to ${queue} (retry #${retry_count}): ${payload:0:80}..."
    return 0
  fi

  local body
  body=$(python3 -c "
import json, sys
payload = sys.argv[1]
queue   = sys.argv[2]
retry   = int(sys.argv[3])
reason  = sys.argv[4]
doc = {
  'routing_key':      queue,
  'payload':          payload,
  'payload_encoding': 'string',
  'properties': {
    'delivery_mode': 2,
    'headers': {
      'x-retry':          retry,
      'x-origin':         'dlq-reprocess-script',
      'x-reprocess-at':   '$(date -Iseconds)',
      'x-reprocess-reason': reason
    }
  }
}
print(json.dumps(doc))
" "$payload" "$queue" "$retry_count" "$reason")

  local status
  status=$(curl -sf -o /dev/null -w "%{http_code}" \
    -u "$AUTH" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$BASE_URL/exchanges/%2F/amq.default/publish")

  [ "$status" = "200" ]
}

get_dlq_message() {
  curl -sf -u "$AUTH" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto","truncate":50000}' \
    "$BASE_URL/queues/%2F/orders.dlq/get"
}

# ── Main ───────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  🔁  DLQ Reprocessor"
echo "  Host:     ${RABBIT_HOST}:${RABBIT_PORT}"
echo "  Batch:    ${MAX_MESSAGES} messages"
echo "  Dry-run:  ${DRY_RUN}"
echo "════════════════════════════════════════════════"
echo ""

# Check connectivity
if ! rabbit_get "overview" > /dev/null 2>&1; then
  err "Cannot reach RabbitMQ at ${RABBIT_HOST}:${RABBIT_PORT}"
  err "Check RABBIT_HOST / RABBIT_PORT / credentials"
  exit 1
fi
ok "RabbitMQ reachable"

# Queue depth snapshot
DLQ_DEPTH=$(queue_depth "orders.dlq")
PARKING_DEPTH=$(queue_depth "orders.parking-lot")
MAIN_DEPTH=$(queue_depth "orders")

log "Queue snapshot:"
log "  orders         : ${MAIN_DEPTH}"
log "  orders.dlq     : ${DLQ_DEPTH}  ← reprocessing"
log "  orders.parking-lot: ${PARKING_DEPTH}"
echo ""

if [ "$DLQ_DEPTH" = "0" ]; then
  ok "DLQ is empty — nothing to reprocess"
  exit 0
fi

# ── Reprocess loop ────────────────────────────────────────────────────────────
PROCESSED=0
PARKED=0
ERRORS=0

for i in $(seq 1 "$MAX_MESSAGES"); do
  # Fetch one message
  MSG_JSON=$(get_dlq_message)

  if [ -z "$MSG_JSON" ] || [ "$MSG_JSON" = "[]" ]; then
    log "DLQ empty after ${i} iterations"
    break
  fi

  # Parse message
  PAYLOAD=$(echo "$MSG_JSON" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
if not msgs: sys.exit(1)
print(msgs[0]['payload'])
")

  ORDER_ID=$(echo "$PAYLOAD" | python3 -c "
import sys, json
try:
  d = json.loads(sys.stdin.read())
  print(d.get('orderId','unknown'))
except:
  print('unknown')
")

  RETRY_COUNT=$(echo "$MSG_JSON" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
headers = msgs[0].get('properties',{}).get('headers',{})
print(headers.get('x-retry', 0))
" 2>/dev/null || echo "0")

  log "Message ${i}: order=${ORDER_ID}  retry=${RETRY_COUNT}"

  # Route: too many retries → parking lot
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    warn "Poison message — routing to parking lot: ${ORDER_ID}"
    if publish_to_queue "orders.parking-lot" "$PAYLOAD" "$RETRY_COUNT" "max-retries-exceeded"; then
      warn "Parked: ${ORDER_ID}"
      PARKED=$((PARKED + 1))
    else
      err "Failed to park: ${ORDER_ID}"
      ERRORS=$((ERRORS + 1))
    fi
    continue
  fi

  if [ "$PARKING_LOT_ONLY" = "true" ]; then
    log "Skipping (--parking-lot-only mode): ${ORDER_ID}"
    continue
  fi

  # Exponential backoff delay (preview only — actual TTL handled by retry queues)
  NEW_RETRY=$((RETRY_COUNT + 1))

  # Re-queue to main orders queue
  if publish_to_queue "orders" "$PAYLOAD" "$NEW_RETRY" "dlq-reprocessed"; then
    ok "Re-queued: ${ORDER_ID} (now retry #${NEW_RETRY})"
    PROCESSED=$((PROCESSED + 1))
  else
    err "Failed to re-queue: ${ORDER_ID}"
    ERRORS=$((ERRORS + 1))
  fi

  # Rate limiting: 100ms between messages
  sleep 0.1
done

echo ""
echo "════════════════════════════════════════════════"
echo "  📊  Reprocess Summary"
echo "  ✅  Re-queued  : ${PROCESSED}"
echo "  🅿️   Parked     : ${PARKED}"
echo "  ❌  Errors     : ${ERRORS}"

# Final snapshot
DLQ_AFTER=$(queue_depth "orders.dlq")
echo "  DLQ remaining : ${DLQ_AFTER}"
echo "════════════════════════════════════════════════"

if [ "$ERRORS" -gt "0" ]; then
  exit 1
fi
