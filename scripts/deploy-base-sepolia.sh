#!/usr/bin/env bash
# Deploy VerticesAttestationRegistry to Base Sepolia using Base Foundry.
#
# Required environment variables:
#   BASE_SEPOLIA_RPC_URL   HTTPS RPC endpoint for Base Sepolia
#   DEPLOYER_PRIVATE_KEY   private key for the funded deployment wallet
# Optional:
#   INITIAL_OWNER          registry owner (defaults to the deployment wallet)
#   DEPLOYMENT_OUTPUT_PATH file to receive the deployment JSON
set -euo pipefail

for command in base-cast base-forge jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command" >&2
    printf 'Install Base Foundry with: base-foundryup --install v1.1.0\n' >&2
    exit 1
  fi
done

for required_var in BASE_SEPOLIA_RPC_URL DEPLOYER_PRIVATE_KEY; do
  if [[ -z "${!required_var:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$required_var" >&2
    exit 1
  fi
done

deployer_address="$(base-cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
initial_owner="${INITIAL_OWNER:-$deployer_address}"
chain_id="$(base-cast chain-id --rpc-url "$BASE_SEPOLIA_RPC_URL")"

if [[ "$chain_id" != "84532" ]]; then
  printf 'Refusing deployment: RPC endpoint reports chain ID %s, expected Base Sepolia (84532).\n' "$chain_id" >&2
  exit 1
fi

if ! base-cast to-check-sum-address "$initial_owner" >/dev/null 2>&1; then
  printf 'INITIAL_OWNER must be a valid EVM address: %s\n' "$initial_owner" >&2
  exit 1
fi

printf 'Deploying VerticesAttestationRegistry to Base Sepolia\n'
printf 'Deployer: %s\nInitial owner: %s\n' "$deployer_address" "$initial_owner"

base-forge build --root contracts
bytecode="$(jq -er '.bytecode.object' contracts/out/VerticesAttestationRegistry.sol/VerticesAttestationRegistry.json)"
constructor_args="$(base-cast abi-encode 'constructor(address)' "$initial_owner")"
receipt="$(base-cast send \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --create "${bytecode}${constructor_args#0x}" \
  --json)"
deployment="$(jq -ce '{deployedTo: .contractAddress, transactionHash: .transactionHash}' <<<"$receipt")"

contract_address="$(jq -er '.deployedTo' <<<"$deployment")"
transaction_hash="$(jq -er '.transactionHash' <<<"$deployment")"

if [[ -n "${DEPLOYMENT_OUTPUT_PATH:-}" ]]; then
  mkdir -p "$(dirname "$DEPLOYMENT_OUTPUT_PATH")"
  printf '%s\n' "$deployment" > "$DEPLOYMENT_OUTPUT_PATH"
fi

printf '\nDeployment complete\nContract: %s\nTransaction: %s\n' "$contract_address" "$transaction_hash"
