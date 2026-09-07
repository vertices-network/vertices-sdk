# Vertices SDK

The Vertices SDK is a security and safety layer for device observations. This Rust SDK and reference protocol makes each observation independently verifiable: a device creates a compact, deterministic observation envelope, signs it with Ed25519, and anchors its SHA-256 commitment on-chain (Base) through an authorized EVM account.

The chain is used as a durable, ordered public record—not as an Ed25519 verifier. Anyone with the original envelope can verify the device signature locally, confirm the envelope hash matches the on-chain event, and see which authorized EVM account submitted it.

## What this repository provides

- `vertices-core`: allocation-free canonical-CBOR observation envelopes and hashing primitives for constrained devices.
- `vertices-crypto`: hardware-agnostic signing interfaces, with a software signer for local development.
- `VerticesAttestationRegistry`: a Solidity registry for device authorization, contiguous observation sequencing, key rotation, and commitment events.
- `vertices-sim` and `vertices-verify`: a deterministic reference device and an independent verification CLI.

This is a reference implementation and development SDK for the Vertices security and safety layer. The simulator uses a fixed test key and must never be deployed or funded as a real device.

## Development environment

This project uses a Nix flake to provide Rust, Solidity, and supporting tools reproducibly. Contract work uses Base's Foundry build (`base-forge`, `base-cast`, `base-anvil`) so Base precompiles behave locally as they do on-chain.

```sh
nix develop
just check
```

The host requires Nix with flakes enabled. The flake pins and installs Base Foundry (`base-forge`, `base-cast`, and `base-anvil`) alongside Rust and Solidity, so no machine-level Foundry installation is required. On macOS, install Nix using your organization’s approved installer, then restart the terminal before running the commands above.

`just check` also starts a disposable local Base node, deploys a fresh registry to it, and runs the full device lifecycle: registration, state reads, observation commitment, both key rotations, and revocation. This gives CI a real deploy-and-interact check without spending testnet funds.

## Run the reference flow

```sh
nix develop
cargo run -p vertices-sim
```

The command prints a signed envelope, its commitment hash, and the values needed for on-chain anchoring. See [the Base Sepolia execution guide](docs/base-sepolia.md) for deployment and independent verification, and [the observation publication and verification flow](docs/observation-flow.md) for the high-level architecture.
