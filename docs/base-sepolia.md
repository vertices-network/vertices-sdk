# Base Sepolia execution guide

`vertices-sim` creates a deterministic, signed observation envelope and prints the exact values needed to anchor it. It is deliberately a desktop reference device; never fund or deploy with its fixed test seed.

All contract commands in this project use Base Foundry (`base-forge` and `base-cast`), not standard Foundry. The repository's Nix flake provides a pinned Base Foundry release; run `nix develop` before invoking contract commands.

## Local protocol proof

```sh
nix develop
cargo run -p vertices-sim
```

For a contract integration check, run a disposable Base-compatible node and deploy the registry to it:

```sh
just contract-integration
```

The command starts `base-anvil` using the Base Sepolia chain ID (`84532`), deploys the registry with an Anvil-funded development account, then exercises every public registry function in a complete device lifecycle: `owner`, `registerDevice`, `getDevice`, `commitObservation`, both rotation functions, and `revokeDevice`. It also confirms a revoked device can no longer commit, then stops the node. It never uses a real wallet or external RPC endpoint. `just contract-smoke` remains an equivalent compatibility alias.

For transaction hashes and state reads while it runs, use either:

```sh
just contract-integration-verbose
# or
INTEGRATION_VERBOSE=1 just contract-integration
```

The simulator verifies the Ed25519 signature before printing:

- the registered device ID and Ed25519 public key;
- the canonical-CBOR envelope;
- its SHA-256 content hash;
- metadata URI, sequence, timestamp, and signature.

## Testnet deployment

Set a deployment wallet and Base Sepolia RPC endpoint outside of source control:

```sh
export BASE_SEPOLIA_RPC_URL='https://…'
export DEPLOYER_PRIVATE_KEY='0x…'
```

Deploy the registry with the funded deployment wallet as owner (or set `INITIAL_OWNER` to use a separate owner address):

```sh
just deploy-base-sepolia
```

The script compiles with `base-forge`, broadcasts the constructor bytecode with `base-cast`, prints the deployed address and transaction hash, and can write its deployment JSON when `DEPLOYMENT_OUTPUT_PATH` is set.

## Base Sepolia integration test

To exercise the same complete lifecycle used by the local integration test on Base Sepolia, deploy a new disposable registry and run:

```sh
just contract-integration-base-sepolia
```

This requires the same `BASE_SEPOLIA_RPC_URL` and `DEPLOYER_PRIVATE_KEY` variables as deployment. It spends test ETH and creates a new contract and test events on Base Sepolia; it does not call or alter an existing registry. Add `INTEGRATION_VERBOSE=1` to log named function arguments, transaction hashes, and state reads.

## GitHub Actions deployment

The [Contracts workflow](../.github/workflows/contracts.yml) runs the full test suite on pull requests and `main`. It only deploys when manually started using **Run workflow** with **Deploy VerticesAttestationRegistry to Base Sepolia** enabled. This prevents a push from automatically spending funds or creating a new registry.

Before the first deployment, create a GitHub Environment named `base-sepolia` and configure its approval rules. Add these environment secrets:

- `BASE_SEPOLIA_RPC_URL`: Base Sepolia HTTPS RPC endpoint.
- `DEPLOYER_PRIVATE_KEY`: private key for a dedicated, funded testnet deployment wallet.

Optionally supply `initial_owner` in the workflow dispatch form. If omitted, the deployment wallet owns the registry. The workflow summary and the `base-sepolia-deployment` artifact contain the deployed address and transaction hash.

Register the simulator’s printed `device_id`, `ed25519_public_key`, and the funded device EVM address using `registerDevice`. Then submit `commitObservation` from that device EVM address, passing the simulator’s `content_hash`, metadata URI, sequence, timestamp, and signature.

## Independent verification

An independent verifier must obtain the original canonical-CBOR envelope, recompute its SHA-256 digest, verify the Ed25519 signature over `CBOR-bytes("vertices.network/observation/v1") || 0x00 || signing-CBOR`, and compare the result with the registry event. Each `ObservationCommitted` event snapshots the active Ed25519 public key, so verifiers must use that event key rather than the current `getDevice` key. `Ed25519KeyRotated` records the previous key, new key, and its activation sequence for auditability. The contract deliberately does not verify Ed25519; its EVM sender check proves who authorized the public anchor.

The Rust `vertices-verify` CLI performs those checks locally:

```sh
cargo run -p vertices-verify -- --public-key <event-ed25519-public-key> --canonical-cbor <envelope> \
  --metadata-uri <event-uri> --event-device-id <event-device-id> \
  --event-content-hash <event-content-hash> --event-sequence <event-sequence> \
  --event-timestamp <event-timestamp> --event-signature <event-signature>
```
