#!/usr/bin/env bash
# Deploy and exercise VerticesAttestationRegistry on a local Base node or Base Sepolia.
set -euo pipefail

verbose="${INTEGRATION_VERBOSE:-0}"
network='anvil'

usage() {
  cat <<'EOF'
Usage: scripts/smoke-test-base-anvil.sh [--anvil | --base-sepolia]

  --anvil         Run against a fresh local Base Anvil node (default).
  --base-sepolia  Deploy a fresh test registry and run the same lifecycle on Base Sepolia.
                  Requires BASE_SEPOLIA_RPC_URL and DEPLOYER_PRIVATE_KEY.
  -h, --help      Show this help text.
EOF
}

while (($# > 0)); do
  case "$1" in
    --anvil) network='anvil' ;;
    --base-sepolia) network='base-sepolia' ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() {
  if [[ "$verbose" == '1' ]]; then
    printf '[integration] %s\n' "$*" >&2
  fi
}

format_device() {
  local tuple="$1"
  local ed25519_public_key evm_address last_sequence registered
  tuple="${tuple#\(}"
  tuple="${tuple%\)}"
  IFS=',' read -r ed25519_public_key evm_address last_sequence registered <<<"$tuple"
  printf 'Device{ed25519PublicKey=%s, evmAddress=%s, lastSequence=%s, registered=%s}' \
    "${ed25519_public_key# }" \
    "${evm_address# }" \
    "${last_sequence# }" \
    "${registered# }"
}

required_commands=(base-cast base-forge jq)
if [[ "$network" == 'anvil' ]]; then
  required_commands+=(base-anvil)
fi
for command in "${required_commands[@]}"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command" >&2
    printf 'Install Base Foundry with: base-foundryup --install v1.1.0\n' >&2
    exit 1
  fi
done

if [[ "$network" == 'anvil' ]]; then
  rpc_url="${BASE_ANVIL_RPC_URL:-http://127.0.0.1:8545}"
  sender_private_key="${BASE_ANVIL_PRIVATE_KEY:-ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
  anvil_log="$(mktemp "${TMPDIR:-/tmp}/vertices-base-anvil.XXXXXX.log")"

  base-anvil --host 127.0.0.1 --port 8545 --chain-id 84532 >"$anvil_log" 2>&1 &
  anvil_pid=$!
  cleanup() {
    kill "$anvil_pid" 2>/dev/null || true
    wait "$anvil_pid" 2>/dev/null || true
    if [[ "$verbose" == '1' ]]; then
      printf '[integration] Anvil log:\n'
      cat "$anvil_log"
    fi
    rm -f "$anvil_log"
  }
  trap cleanup EXIT
else
  for required_var in BASE_SEPOLIA_RPC_URL DEPLOYER_PRIVATE_KEY; do
    if [[ -z "${!required_var:-}" ]]; then
      printf 'Missing required environment variable for Base Sepolia: %s\n' "$required_var" >&2
      exit 1
    fi
  done
  rpc_url="$BASE_SEPOLIA_RPC_URL"
  sender_private_key="$DEPLOYER_PRIVATE_KEY"
fi

for _ in $(seq 1 30); do
  if chain_id="$(base-cast chain-id --rpc-url "$rpc_url" 2>/dev/null)"; then
    break
  fi
  sleep 1
done

if [[ "${chain_id:-}" != "84532" ]]; then
  printf '%s RPC endpoint reports chain ID %s, expected Base Sepolia (84532).\n' "$network" "${chain_id:-unavailable}" >&2
  exit 1
fi

owner="$(base-cast wallet address --private-key "$sender_private_key")"
next_nonce="$(base-cast nonce "$owner" --rpc-url "$rpc_url")"
log "${network} is ready on chain ID $chain_id"
if [[ "$network" == 'base-sepolia' ]]; then
  printf 'Running integration test on Base Sepolia: this deploys a new registry and spends test ETH.\n'
fi
log "Deploying registry with owner $owner"
log "Using deployment nonce $next_nonce"
base-forge build --root contracts
bytecode="$(jq -er '.bytecode.object' contracts/out/VerticesAttestationRegistry.sol/VerticesAttestationRegistry.json)"
constructor_args="$(base-cast abi-encode 'constructor(address)' "$owner")"
receipt="$(base-cast send \
  --rpc-url "$rpc_url" \
  --private-key "$sender_private_key" \
  --nonce "$next_nonce" \
  --create "${bytecode}${constructor_args#0x}" \
  --json)"
contract_address="$(jq -er '.contractAddress' <<<"$receipt")"
last_transaction_block="$(jq -er '.blockNumber' <<<"$receipt")"
next_nonce=$((next_nonce + 1))
log "Registry deployed at $contract_address (tx $(jq -er '.transactionHash' <<<"$receipt"), block $last_transaction_block)"

call_contract() {
  local function_signature="$1"
  shift
  local call_args=("$contract_address" "$function_signature" "$@" --rpc-url "$rpc_url")
  local call_output
  local attempt
  # Query the exact block containing the preceding transaction. Public RPC endpoints
  # are often load-balanced, so an unpinned `latest` call can briefly hit a lagging node.
  if [[ -n "${last_transaction_block:-}" ]]; then
    call_args+=(--block "$last_transaction_block")
  fi

  # Some gateways return a receipt before every backend can serve the corresponding
  # historical block. Retrying the pinned call prevents reading stale `latest` state.
  for attempt in $(seq 1 30); do
    if call_output="$(base-cast call "${call_args[@]}" 2>&1)"; then
      printf '%s\n' "$call_output"
      return 0
    fi
    if ((attempt == 1)); then
      log "Waiting for RPC to serve block $last_transaction_block for $function_signature"
    fi
    sleep 1
  done

  printf 'RPC did not serve block %s after 30 seconds while calling %s:\n%s\n' \
    "$last_transaction_block" "$function_signature" "$call_output" >&2
  return 1
}

reported_owner="$(call_contract 'owner()(address)')"

if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$reported_owner")" != "$(tr '[:upper:]' '[:lower:]' <<<"$owner")" ]]; then
  printf 'Deployed contract owner does not match the deployer.\n' >&2
  exit 1
fi

device_id='0x76657274696365732d31323334000000'
initial_ed25519_key='0x0000000000000000000000000000000000000000000000000000000000000007'
rotated_ed25519_key='0x0000000000000000000000000000000000000000000000000000000000000008'
content_hash='0x0000000000000000000000000000000000000000000000000000000000000001'
successor_address='0x000000000000000000000000000000000000dEaD'

send() {
  local function_signature="$1"
  shift
  local raw_transaction_output transaction_receipt transaction_status transaction_hash
  raw_transaction_output="$(base-cast send "$contract_address" "$function_signature" "$@" \
    --rpc-url "$rpc_url" \
    --private-key "$sender_private_key" \
    --nonce "$next_nonce" \
    --json)"
  # Base Cast normally emits one-line JSON. Some public RPC gateways prepend a
  # human-readable warning, so decode the final line while retaining the full
  # response for useful diagnostics on a genuine RPC failure.
  transaction_receipt="${raw_transaction_output##*$'\n'}"
  if ! transaction_status="$(jq -er '.status' <<<"$transaction_receipt")"; then
    printf 'Could not parse the transaction response for %s:\n%s\n' \
      "$function_signature" "$raw_transaction_output" >&2
    return 1
  fi
  if [[ "$transaction_status" != '0x1' ]]; then
    log "$function_signature reverted"
    return 1
  fi
  last_transaction_block="$(jq -er '.blockNumber' <<<"$transaction_receipt")"
  transaction_hash="$(jq -er '.transactionHash' <<<"$transaction_receipt")"
  log "$function_signature → $transaction_hash (nonce $next_nonce, block $last_transaction_block)"
  next_nonce=$((next_nonce + 1))
}

# Use the funded deployment account as the device signer. This lets the test cover
# the complete authorized lifecycle without relying on a second hard-coded Anvil key.
log "registerDevice(deviceId=$device_id, ed25519PublicKey=$initial_ed25519_key, evmAddress=$owner)"
send 'registerDevice(bytes16,bytes32,address)' "$device_id" "$initial_ed25519_key" "$owner"
registered_device="$(call_contract 'getDevice(bytes16)((bytes32,address,uint64,bool))' "$device_id")"
log "getDevice(deviceId=$device_id) after registration: $(format_device "$registered_device")"
if [[ "${registered_device,,}" != *"${owner,,}"* || "$registered_device" != *', 0, true)'* ]]; then
  printf 'Registered device state was not returned as expected.\n' >&2
  exit 1
fi

log "commitObservation(deviceId=$device_id, contentHash=$content_hash, metadataUri=ipfs://bafy-integration-test, sequence=1, timestamp=1725000000, ed25519Signature=0x01)"
send 'commitObservation(bytes16,bytes32,string,uint64,uint64,bytes)' \
  "$device_id" "$content_hash" 'ipfs://bafy-integration-test' 1 1725000000 '0x01'
committed_device="$(call_contract 'getDevice(bytes16)((bytes32,address,uint64,bool))' "$device_id")"
log "getDevice(deviceId=$device_id) after commitment: $(format_device "$committed_device")"
if [[ "$committed_device" != *', 1, true)'* ]]; then
  printf 'Committed sequence was not recorded.\n' >&2
  exit 1
fi

log "rotateEd25519Key(deviceId=$device_id, newEd25519PublicKey=$rotated_ed25519_key)"
send 'rotateEd25519Key(bytes16,bytes32)' "$device_id" "$rotated_ed25519_key"
log "rotateEvmAddress(deviceId=$device_id, newEvmAddress=$successor_address)"
send 'rotateEvmAddress(bytes16,address)' "$device_id" "$successor_address"
rotated_device="$(call_contract 'getDevice(bytes16)((bytes32,address,uint64,bool))' "$device_id")"
log "getDevice(deviceId=$device_id) after rotations: $(format_device "$rotated_device")"
if [[ "${rotated_device,,}" != *"${rotated_ed25519_key,,}"* || "${rotated_device,,}" != *"${successor_address,,}"* ]]; then
  printf 'Rotated device state was not returned as expected.\n' >&2
  exit 1
fi

# Rotate the submitter back so the same test wallet can demonstrate revocation.
log "rotateEvmAddress(deviceId=$device_id, newEvmAddress=$owner)"
send 'rotateEvmAddress(bytes16,address)' "$device_id" "$owner"
log "revokeDevice(deviceId=$device_id)"
send 'revokeDevice(bytes16)' "$device_id"
revoked_device="$(call_contract 'getDevice(bytes16)((bytes32,address,uint64,bool))' "$device_id")"
log "getDevice(deviceId=$device_id) after revocation: $(format_device "$revoked_device")"
if [[ "${revoked_device,,}" != *'0x0000000000000000000000000000000000000000'* || "$revoked_device" != *', 1, true)'* ]]; then
  printf 'Revoked device state was not returned as expected.\n' >&2
  exit 1
fi

log "commitObservation(deviceId=$device_id, contentHash=$content_hash, metadataUri=ipfs://bafy-integration-test, sequence=2, timestamp=1725000001, ed25519Signature=0x02) [expected revert]"
if send 'commitObservation(bytes16,bytes32,string,uint64,uint64,bytes)' \
  "$device_id" "$content_hash" 'ipfs://bafy-integration-test' 2 1725000001 '0x02' 2>/dev/null; then
  printf 'Revoked device was able to commit an observation.\n' >&2
  exit 1
fi
log 'Post-revocation commitment correctly reverted'

printf '%s integration test passed: %s\n' "$network" "$contract_address"
