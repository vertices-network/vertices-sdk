# Vertices Network: Product and Technical Plan

## Strategic objective

Vertices Network is building the foundations for **verifiable machine identity**: a constrained physical device can produce independently auditable observations and, eventually, participate autonomously in the internet economy under policy-controlled financial capabilities.

The first product is an **authenticated physical-observation protocol**:

> physical device → authenticated observation → public verification → economic identity

At the end of the project, Vertices should be able to say:

> We provide a Rust Zephyr-ready SDK that gives physical devices hardware-rooted, cryptographically verifiable observations and an economic identity anchored on public infrastructure.

The commercial question remains central: prove that a device manufacturer or DePIN operator will pay for this capability. The long-term path is deliberately staged: **open protocol → embedded identity SDK → machine-economy infrastructure**.

## v0.1 product definition

Build a greenfield Rust workspace for an ESP32-connected device that publishes authenticated sensor observations directly to Base Sepolia.

- `vertices-core` is strict `#![no_std]`, allocator-free, and fixed-buffer only.
- The signed observation **envelope** is deterministically encoded as CBOR and contains its protocol/encoding version, device ID, monotonic sequence, timestamp, payload hash, metadata-URI hash, and Ed25519 signature.
- The payload body is not part of the envelope encoding contract. It remains off-chain and may use an independently declared, versioned application format (for example compact binary, protobuf, CBOR, or JSON); the envelope signs its hash rather than re-encoding it.
- The device maintains two independently generated, independently rotatable hardware-backed credentials: an **Ed25519** to sign observation evidence and a separately managed **secp256k1** key to authorize Ethereum-compatible (Base EIP-1559) transactions.
- Observation bodies remain off-chain; Base records a commitment and a metadata reference.
- The initial deployment uses Base Sepolia and a funded device EOA. Mainnet follows field validation.

v0.1 explicitly excludes paid data purchases, gas sponsorship, and physical actuation. It reserves clean internal boundaries for future payment policy and action-intent flows without presenting them as finished product APIs.

## Architectural principles

### Separate evidence from authorization

Keep the two credentials independent and independently rotatable:

| Concern                  | Credential                  | Purpose                                                        |
| ------------------------ | --------------------------- | -------------------------------------------------------------- |
| Physical evidence        | Ed25519 key                 | Proves that a registered device signed a specific observation. |
| Blockchain authorization | secp256k1 key / EVM address | Authorizes the transaction that anchors a commitment on Base.  |

This separation answers two distinct questions:

- **What did the machine observe?** — verify the canonical observation and its Ed25519 signature.
- **Which blockchain account authorized the anchor?** — verify the Base transaction sender against the registered EVM address.

The Solidity contract does not verify Ed25519. It records the public evidence and enforces authorization through the registered EVM account, keeping on-device and on-chain cost predictable. The observation format can therefore remain useful beyond EVM chains.

### Envelope determinism and payload flexibility

Vertices must enforce one byte-level representation for each signed envelope version. For v0.1, that representation is **deterministic CBOR**. The version is part of the envelope and identifies the protocol and encoding rules used to produce the bytes that are hashed and signed.

This is a security and interoperability requirement: a verifier must be able to reproduce precisely the bytes the device signed. Accepting arbitrary or merely “valid” CBOR would permit differences in map order, integer representation, and optional-field handling that can yield different hashes for an apparently identical observation.

Flexibility belongs in the payload body, not in the signed envelope:

```text
versioned deterministic-CBOR observation envelope
  |- required protocol fields
  |- payload hash
  |- optional payload format / content type reference
  `- metadata URI hash

off-chain payload body
  `- independently selected and versioned application format
```

Human-facing APIs and metadata may use JSON or another convenient format. If Vertices later needs another envelope encoding, introduce a new explicit protocol/encoding version; do not accept multiple envelope encodings under one signature scheme.

### Proposed target architecture

```text
                              VERTICES PROTOCOL
                                      |
                +---------------------+---------------------+
                |                                           |
        Physical evidence                            Economic identity
                |                                           |
       Canonical CBOR observation                    Base / EVM account
                |                                           |
         Ed25519 signature                          secp256k1 authorization
                |                                           |
                +---------------------+---------------------+
                                      |
                               Machine identity
                                      |
                         +------------+------------+
                         |                         |
                 Hardware identity         Firmware measurement
                         |                         |
                         +------------+------------+
                                      |
                                Attestation
```

The implementation boundary beneath the protocol is hardware-neutral:

```text
vertices-crypto
  |- software test signer (std/test only)
  |- secure-element backend (first candidate: SE050)
  |- ESP32 secure backend where available
  `- future PSA / secure-MCU backends (for example STM32U5 or nRF54)
```

No private key material may cross into `vertices-*` application logic. Signer traits expose only public-key/address discovery and signing operations.

### Observation continuity and batching consideration

Before the wire format is frozen, evaluate adding `previous_observation_hash` to every observation. This forms a signed hash chain:

```text
O1 --> O2 --> O3 --> ... --> O1000 --> Merkle root --> Base anchor
```

In addition to the monotonic counter, chaining gives stronger evidence of deletion or reordering and opens a future path to periodic Merkle-root anchoring rather than one Base transaction per observation. The evaluation must weigh stronger continuity evidence against reset/recovery behavior, storage requirements, and protocol complexity. Do not make it mandatory until those trade-offs have been tested on real hardware.

## Core components and public interfaces

| Component                     | Responsibility                                                                                                                        |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `vertices-core`               | Allocator-free canonical CBOR, bounds checking, deterministic hashes, domain separation, observation validation, and replay controls. |
| `vertices-crypto`             | `Ed25519Signer` and `EvmSigner` traits; production code never receives raw private keys.                                              |
| `vertices-base`               | Minimal ABI encoder, EIP-1559 construction, and caller-supplied RPC transport; no full network client in the `no_std` core.           |
| ESP32 adapter                 | Traits for secure storage, monotonic counter, clock, Wi-Fi transport, and entropy.                                                    |
| `VerticesAttestationRegistry` | Device registration, key rotation, authorization, sequence enforcement, and complete commitment events on Base Sepolia.               |
| `vertices-sim`                | Desktop reference device that signs, submits, and independently verifies a complete flow.                                             |

Public interfaces for the first release:

- `Observation<const URI: usize>` — fixed-capacity signed device observation.
- `ObservationBuilder` — canonical construction; rejects invalid timestamps, URIs, and buffer overflows.
- `Ed25519Signer` and `EvmSigner` — hardware-agnostic signing traits.
- `BaseClient` — submits registry commitments using a caller-supplied `RpcTransport`.
- Registry functions — `registerDevice`, `rotateEvmAddress`, `rotateEd25519Key`, and `commitObservation`.

## Priority roadmap

### Foundation — Prove the protocol end to end

Build the complete flow on desktop before making hardware claims:

```text
Observation -> canonical CBOR -> SHA-256 -> Ed25519 signature
            -> EIP-1559 transaction -> Base Sepolia registry -> event verification
```

`vertices-sim` must generate a valid observation, sign it, construct and send the transaction, then verify the emitted registry event.

**Success gate:** an independent third party can use the device ID, observation, signature, registered public key, and Base transaction to answer: “Did device X sign this observation, and was it anchored by its authorized machine account?”

**Exit artifacts:** SDK skeleton, registry contract, published testnet deployment details, known EIP-1559 vectors, and an end-to-end integration guide covering funding, registration, RPC configuration, and metadata storage.

### P1 — Make the ESP32 real

Move the unchanged protocol to an ESP32 with Wi-Fi, a sensor, two keys, and a monotonic sequence source. This milestone validates constrained-device fitness, not production-grade key protection.

Measure and document:

- flash and RAM use;
- CBOR and transaction sizes;
- Ed25519 and secp256k1 signing latency;
- Wi-Fi/RPC overhead and retry behavior;
- energy per observation; and
- behavior across failure, reboot, and reconnect scenarios.

**Success gate:** a real sensor repeatedly produces valid, independently verifiable Base Sepolia commitments within agreed memory, timing, and reliability budgets. Production crates remain `no_std` and allocator-free under cross-compilation.

### P2 — Hardware-rooted security

Replace the abstraction-only security story with at least one production-like backend. Start with an SE050 secure element and compare the outcome with an ESP32-native secure design where relevant. Also prepare a path for a secure MCU / PSA backend.

The API remains stable; only the signer and storage backend changes.

**Success gate:** the observation and EVM credentials are generated or provisioned into protected hardware, can sign without export, and pass a documented threat-model review. The “no private key enters SDK logic” invariant is demonstrably enforced.

### P3 — Firmware-bound identity

Extend registration and evidence so identity means more than possession of a key:

```text
Device ID
  |- hardware identity
  |- Ed25519 public key
  |- EVM address
  |- firmware measurement
  `- provisioning state
```

The target assertion becomes: “This observation came from device X running firmware Y.” Firmware measurements and attestation material should be kept privacy-conscious, with hashes or references anchored publicly where appropriate.

**Success gate:** a verifier can link a valid observation to a registered hardware identity and an approved firmware measurement, with a tested update and rollback policy.

### P3a — Hardware-state attestation (stretch priority; after P3)

When P2 hardware protection and P3 firmware-bound identity are working, extend the protocol from “a device key signed this observation” to a verifiable claim about the device’s current protected state.

This is a versioned protocol extension. Do not change v1 signed bytes. Define a deterministic-CBOR `AttestationStatement` and a v2 observation envelope that references it by `attestation_hash`.

```text
hardware / manufacturer trust root
        ↓ certifies
hardware attestation key
        ↓ signs
AttestationStatement
  |- device ID
  |- observation Ed25519 public-key binding
  |- boot-chain measurement
  |- firmware measurement or hash, when distinct
  |- secure-boot and anti-rollback state
  |- security lifecycle state
  |- debug-lock state
  |- boot counter
  |- attestation-key certificate or trust reference
  `- optional verifier nonce
        ↓ referenced by hash
v2 Observation
  |- normal measurement evidence
  `- attestation_hash
```

The observation key remains separate from the hardware attestation key. The attestation statement binds the observation public key to protected hardware and its measured state; the observation signature then authenticates the individual measurement. This distinction is essential: an ordinary Ed25519 signature proves key possession, while a validated hardware attestation can prove the key was authorized by a device in a required state.

Use a verifier-provided nonce for challenge-response attestations (“prove your state now”), while retaining the persisted monotonic observation sequence for stream freshness, replay prevention, and ordering. A nonce is not a replacement for the sequence counter.

Implementation boundaries:

- Add `AttestationStatement` and a new explicit envelope version in `vertices-core`; canonical v1 remains unchanged.
- Add a hardware-neutral `HardwareAttester` trait in `vertices-crypto`. Production implementations keep attestation keys in protected hardware; a software implementation is test-only.
- Register an attestation-key/certificate reference with the registry, and emit the `attestation_hash` with v2 commitments. Keep vendor-specific attestation verification off-chain.
- Add a verifier policy layer that can require production lifecycle, debug disabled, approved boot measurement, current nonce, and a minimum anti-rollback version.

**Success gate:** an independent verifier can reject an otherwise valid observation when its referenced attestation is stale, untrusted, debug-enabled, running an unapproved firmware measurement, or not bound to the observation key; and accept it only when the required hardware-state policy is satisfied.

### P4 — Provisioning and lifecycle

Build the operational path from factory to field:

```text
factory -> generate/provision hardware identity -> register device -> assign operator -> operate/rotate/recover
```

Model ownership transfer separately from key rotation. Preserve distinct roles for manufacturer, current operator/economic account, device-held observation key, and firmware signer.

**Success gate:** a documented, repeatable provisioning flow supports registration, ownership transfer, Ed25519/EVM key rotation, device retirement, and audit history without conflating these lifecycle events.

### P5 — Optional smart-account architecture

The EOA design is correct for v0.1. Keep it as the default baseline, but define and prototype an optional Base smart-account route rather than making it permanent. The purpose is future support for session keys, recovery, sponsorship, and enforceable spending policy without forcing the MCU to implement every account feature.

**Success gate:** a clear architecture decision, backed by a small prototype and threat/cost comparison, shows whether account abstraction materially improves the chosen customer use case. Do not migrate the baseline EOA path merely for novelty.

### P6 — Gasless and relayed publishing

Remove the production requirement that every device hold and manage ETH. Evaluate relayers, batching, delegated authorization, ERC-4337, and paymasters.

```text
device -- signed observation --> relayer -- pays gas --> Base
```

The relayer must not be able to forge observations or silently change committed content.

**Success gate:** a fleet-oriented prototype publishes signed device evidence without per-device gas management, and documents authorization, replay protection, cost per observation, availability, and failure handling.

### P7 — First customer vertical

Stop adding generic platform features and choose one customer vertical. The initial preference is a DePIN sensor/device manufacturer because its workflow closely matches signed measurement → public proof → incentive or settlement.

Candidate demonstrations include weather, GNSS, energy, or other infrastructure sensors. The customer interview is not “Do you like blockchain?” It is: “What economic transaction does trustworthy proof from this device unlock?”

**Success gate:** at least one design partner runs real hardware and articulates a paid, repeatable use case. If no credible paid wedge emerges, pause or pivot rather than expanding the protocol.

### P8 — Machine-to-machine commerce

Only after observation verification is useful, give a device a narrow, policy-controlled way to buy an internet service. Integrate with x402 as an open payment standard rather than competing with it.

Create `vertices-x402`: an allocator-free, `no_std` Rust client-side x402 payment engine for constrained devices. Its conceptual boundary is:

```rust
trait X402Client {
    fn handle_payment_required(
        &self,
        requirements: &PaymentRequirements,
    ) -> Result<PaymentSignature>;
}
```

`vertices-x402` owns payment interpretation and authorization, not connectivity:

```text
vertices-x402
  |- HTTP 402 parsing
  |- payment requirements
  |- policy evaluation
  |- EVM signing
  `- PAYMENT-SIGNATURE construction
          |
          v
  caller-supplied RPC / HTTP abstraction
          |
          v
       ESP32 Wi-Fi
```

Keep HTTP transport separate from the payment engine so the protocol remains usable through ESP32 Wi-Fi today and other transports or gateways later. Private signing material remains behind `EvmSigner`; the x402 engine evaluates payment requirements against explicit device policy before it requests a signature.

The policy model can initially retain three distinct concepts:

| Concept        | Question answered            | Example                                      |
| -------------- | ---------------------------- | -------------------------------------------- |
| `Capability`   | What may the machine do?     | Request RTK correction.                      |
| `SpendLimit`   | How much may it spend?       | €0.10/request; €5/day.                       |
| `ActionIntent` | What is it asking to do now? | Purchase RTK service for observation #18372. |

**Success gate:** a real device completes one narrowly scoped x402-protected service purchase under an explicit capability and spend policy. The implementation remains a standards integration, not a general wallet or a replacement payment network.

## Cross-cutting quality gates

The following checks apply throughout the plan:

- Unit-test canonical CBOR bytes, hashes, signature verification, malformed/max-size inputs, timestamp validation, and replay rejection.
- Validate EIP-1559 serialization against known transaction vectors.
- Contract-test registration, unauthorized submission, duplicate/non-monotonic sequences, key rotation, and every emitted event field.
- Run a real Base Sepolia end-to-end test from `vertices-sim` and later from ESP32 hardware.
- Cross-compile the `no_std` core and ESP32 adapter; continuously enforce that production crates do not enable `std` or allocation.
- Maintain a concise threat model covering key extraction, replay, sequence rollback, firmware downgrade, transport tampering, registration abuse, and relayer misuse.

## Explicit non-goals for this project

- A general-purpose “crypto wallet for IoT.”
- Multi-chain support, including Solana or IoTeX integrations, before the Base path earns its place.
- On-chain storage of raw sensor bodies or sensitive device data.
- Solidity-based Ed25519 verification in v0.1.
- A fully featured smart-account stack before an EOA-based device flow is proven.
- Gas sponsorship or fleet-scale payment operations in the first end-to-end demo.
- Paid data purchases, x402 integration, stablecoin rails, or arbitrary machine payments before P8.
- Physical actuation or safety-critical control.
- Claiming production-grade hardware security before a real protected-key backend and firmware-bound identity are validated.

## Six end-of-project deliverables

1. **`rust-vertices-sdk`** — a production-quality, allocator-free `no_std` core with stable protocol, crypto, Base, and adapter boundaries.
2. **ESP32 reference implementation** — a real sensor producing signed observations and anchoring them on Base.
3. **Hardware-rooted implementation** — at least one secure-element backend and one secure-MCU/secure-hardware path, with non-exportable keys.
4. **Verifiable machine identity** — device identity, firmware measurement, and—when P3a is completed—hardware-state attestation combined into a publicly verifiable model.
5. **Gasless/relayed publishing** — a fleet-suitable route that does not require every device to manage ETH.
6. **Machine-to-machine commerce proof** — `vertices-x402` plus one real device purchase of a defined internet service under policy; this work is validated with a DePIN operator or device manufacturer using real hardware.

## Decision at project end

Use the evidence from the customer deployment, hardware security work, and operating economics to choose the next focus:

- **Open-source protocol** if adoption and interoperability are the strongest signals.
- **Embedded security and identity SDK** if manufacturers value the device-side implementation most.
- **Machine-economy infrastructure** if verified observations directly unlock high-value policy, payment, or settlement workflows.

The product remains successful only if it proves both sides of the thesis: a constrained device can produce meaningful public evidence, and a customer has a reason to pay for it.

## Company thesis

Vertices gives physical machines the identity, evidence, and financial capabilities required to participate autonomously in the internet economy.

```text
                              PHYSICAL MACHINE
                                      |
                    +-----------------+-----------------+
                    |                 |                 |
                 Identity           Evidence            Money
                    |                 |                 |
              “Who am I?”      “What did I        “What can I
                                  measure?”           buy?”
                    |                 |                 |
                    +-----------------+-----------------+
                                      |
                                  VERTICES
                                      |
                         +------------+------------+
                         |                         |
                       x402                       Base
                         |                         |
                 machine-to-machine      economic settlement
                   internet commerce
```

x402 is a standard Vertices integrates with. Vertices’ differentiated work is bringing standards-based commerce together with hardware-rooted identity, verifiable physical evidence, constrained-device policy, and reliable embedded implementation.
