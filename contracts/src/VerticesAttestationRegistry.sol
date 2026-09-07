// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title Vertices Attestation Registry
/// @notice Public Base registry contract for anchoring Vertices device observation commitments on-chain.
/// @dev ARCHITECTURE & DESIGN CHOICES:
///
///      1. Dual-Key Identity Model:
///         - Devices are identified on-chain by a 16-byte `deviceId`.
///         - `ed25519PublicKey`: Off-chain identity key used by hardware devices to sign observation envelopes.
///         - `evmAddress`: On-chain submission key authorized to call `commitObservation` for the device.
///
///      2. Off-Chain Signature Verification (Optimistic Emission):
///         - Ed25519 signatures are NOT verified on-chain to save substantial gas (~500k+ gas per transaction).
///         - Instead, signatures are emitted in the `ObservationCommitted` event log for off-chain indexers and
///           verifiers to inspect.
///         - The EVM sender check (`msg.sender == device.evmAddress`) acts as on-chain authorization proof.
///
///      3. Strict Sequence Monotonicity:
///         - `sequence` numbers must strictly increase (`sequence > lastSequence`) per device.
///         - This prevents replay attacks and guarantees linear ordering of observation commitments.
///
///      4. Centralized Identity Management:
///         - Only the contract `owner` can register devices or rotate device keys.
///         - This simplifies security governance, though it creates a centralized dependency on the owner key.
contract VerticesAttestationRegistry {
    // =========================================================================
    // Custom Errors
    // =========================================================================

    /// @notice Thrown when an unauthorized caller attempts an administrative or device commitment action.
    error Unauthorized();

    /// @notice Thrown when attempting to register a device ID that has already been registered.
    error DeviceAlreadyRegistered();

    /// @notice Thrown when operating on a device ID that does not exist in the registry.
    error UnknownDevice();

    /// @notice Thrown when a zero-address (`address(0)`) is supplied where a valid EVM address is required.
    error InvalidAddress();

    /// @notice Thrown when a submitted sequence number is not exactly one greater than the device's last recorded sequence.
    /// @param previous The previous sequence number recorded on-chain for this device.
    /// @param submitted The sequence number provided in the failing `commitObservation` call.
    error InvalidSequence(uint64 previous, uint64 submitted);

    /// @notice Thrown when a device has exhausted the uint64 sequence space.
    error SequenceExhausted();

    // =========================================================================
    // Data Structures & Storage Layout
    // =========================================================================

    /// @notice Represents a registered device and its operational state.
    /// @dev STORAGE LAYOUT (EVM Slot Packing Optimization):
    ///      - Slot 0: `ed25519PublicKey` (32 bytes) -> Fills Slot 0 completely.
    ///      - Slot 1: `evmAddress` (20 bytes) + `lastSequence` (8 bytes) + `registered` (1 byte) = 29 bytes.
    ///        Fits entirely within Slot 1 (32 bytes max).
    ///      This structure requires exactly 2 SLOAD/SSTORE storage slots per device lookup.
    struct Device {
        /// @notice The 32-byte Ed25519 public key used off-chain by the device to sign observations.
        bytes32 ed25519PublicKey;
        /// @notice The EVM address authorized to submit `commitObservation` transactions for this device.
        address evmAddress;
        /// @notice The highest sequence number committed so far for this device (monotonically increasing).
        uint64 lastSequence;
        /// @notice Flag indicating whether this device has been registered in the system.
        bool registered;
    }

    /// @notice Contract owner address set at deployment (immutable to save gas on reads).
    address public immutable owner;

    /// @notice Mapping from unique 16-byte `deviceId` to its `Device` state record.
    mapping(bytes16 deviceId => Device) private devices;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new device is registered in the registry.
    /// @param deviceId The unique 16-byte identifier assigned to the device (indexed for fast topic filtering).
    /// @param ed25519PublicKey The 32-byte Ed25519 public key of the device.
    /// @param evmAddress The EVM address authorized to submit commitments for this device (indexed).
    event DeviceRegistered(bytes16 indexed deviceId, bytes32 ed25519PublicKey, address indexed evmAddress);

    /// @notice Emitted when a device's off-chain Ed25519 public key is updated by the registry owner.
    /// @param deviceId The unique 16-byte identifier of the device (indexed).
    /// @param previousEd25519PublicKey The previously active 32-byte Ed25519 public key.
    /// @param ed25519PublicKey The new 32-byte Ed25519 public key.
    /// @param activationSequence The first observation sequence that must use the new key.
    event Ed25519KeyRotated(
        bytes16 indexed deviceId, bytes32 previousEd25519PublicKey, bytes32 ed25519PublicKey, uint64 activationSequence
    );

    /// @notice Emitted when a device's authorized EVM submission address is updated by the registry owner.
    /// @param deviceId The unique 16-byte identifier of the device (indexed).
    /// @param evmAddress The new authorized EVM address (indexed).
    event EvmAddressRotated(bytes16 indexed deviceId, address indexed evmAddress);

    /// @notice Emitted when a device is revoked by the registry owner.
    /// @param deviceId The unique 16-byte identifier of the revoked device (indexed).
    event DeviceRevoked(bytes16 indexed deviceId);

    /// @notice Emitted when a valid observation commitment is anchored on-chain.
    /// @dev Off-chain verifiers listen to this event log to obtain observation hashes and Ed25519 signatures.
    /// @param deviceId The unique 16-byte identifier of the device (indexed topic 1).
    /// @param contentHash SHA-256 digest of the canonical-CBOR observation envelope (indexed topic 2).
    /// @param ed25519PublicKey The device key active at this commitment, retained for historical verification.
    /// @param metadataUri Off-chain URI pointing to metadata or raw observation payloads (e.g. IPFS/HTTPS).
    /// @param sequence Monotonically increasing sequence number of this observation.
    /// @param timestamp Unix timestamp (seconds) reported by the device or submitter.
    /// @param ed25519Signature Raw Ed25519 signature bytes over the observation envelope.
    /// @param evmSender The EVM address that executed the `commitObservation` transaction (indexed topic 3).
    event ObservationCommitted(
        bytes16 indexed deviceId,
        bytes32 indexed contentHash,
        bytes32 ed25519PublicKey,
        string metadataUri,
        uint64 sequence,
        uint64 timestamp,
        bytes ed25519Signature,
        address indexed evmSender
    );

    // =========================================================================
    // Constructor & External Administrative Functions
    // =========================================================================

    /// @notice Initializes the registry contract with an owner address.
    /// @param initialOwner Address granted exclusive administrative privileges (device registration & key rotation).
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidAddress();
        owner = initialOwner;
    }

    /// @notice Registers a new device with its Ed25519 public key and authorized EVM address.
    /// @dev Can only be called by the contract owner.
    /// @param deviceId Unique 16-byte device identifier.
    /// @param ed25519PublicKey 32-byte Ed25519 public key used for off-chain signature verification.
    /// @param evmAddress EVM address authorized to submit commitments for this `deviceId`.
    function registerDevice(bytes16 deviceId, bytes32 ed25519PublicKey, address evmAddress) external {
        if (msg.sender != owner) revert Unauthorized();
        if (devices[deviceId].registered) revert DeviceAlreadyRegistered();
        if (evmAddress == address(0)) revert InvalidAddress();
        devices[deviceId] = Device(ed25519PublicKey, evmAddress, 0, true);
        emit DeviceRegistered(deviceId, ed25519PublicKey, evmAddress);
    }

    /// @notice Rotates the authorized EVM submission address for an existing device.
    /// @dev Can only be called by the contract owner. Prevents setting `newEvmAddress` to `address(0)`.
    /// @param deviceId The unique 16-byte identifier of the target device.
    /// @param newEvmAddress The new EVM address authorized to submit commitments.
    function rotateEvmAddress(bytes16 deviceId, address newEvmAddress) external {
        if (msg.sender != owner) revert Unauthorized();
        Device storage device = _registeredDevice(deviceId);
        if (newEvmAddress == address(0)) revert InvalidAddress();
        device.evmAddress = newEvmAddress;
        emit EvmAddressRotated(deviceId, newEvmAddress);
    }

    /// @notice Rotates the off-chain Ed25519 public key for an existing device.
    /// @dev Can only be called by the contract owner.
    /// @param deviceId The unique 16-byte identifier of the target device.
    /// @param newEd25519PublicKey The new 32-byte Ed25519 public key.
    function rotateEd25519Key(bytes16 deviceId, bytes32 newEd25519PublicKey) external {
        if (msg.sender != owner) revert Unauthorized();
        Device storage device = _registeredDevice(deviceId);
        if (device.lastSequence == type(uint64).max) revert SequenceExhausted();
        bytes32 previousEd25519PublicKey = device.ed25519PublicKey;
        uint64 activationSequence = device.lastSequence + 1;
        device.ed25519PublicKey = newEd25519PublicKey;
        emit Ed25519KeyRotated(deviceId, previousEd25519PublicKey, newEd25519PublicKey, activationSequence);
    }

    /// @notice Revokes a device by clearing its authorized EVM address to `address(0)`.
    /// @dev Can only be called by the contract owner. Permanently prevents future observation commitments.
    /// @param deviceId The unique 16-byte identifier of the target device.
    function revokeDevice(bytes16 deviceId) external {
        if (msg.sender != owner) revert Unauthorized();
        Device storage device = _registeredDevice(deviceId);
        device.evmAddress = address(0);
        emit DeviceRevoked(deviceId);
    }

    // =========================================================================
    // Core Observation Commitment Functionality
    // =========================================================================

    /// @notice Anchors an observation commitment on-chain by emitting an `ObservationCommitted` event log.
    /// @dev Authorization check: `msg.sender` MUST match the device's registered `evmAddress`.
    ///      Sequence check: `sequence` MUST be exactly one greater than the recorded `device.lastSequence`.
    ///      Gas optimization: Uses `calldata` for `metadataUri` and `ed25519Signature` to avoid copying data to memory.
    /// @param deviceId Unique 16-byte device identifier emitting the observation.
    /// @param contentHash SHA-256 digest of the canonical-CBOR observation envelope.
    /// @param metadataUri URI string referencing external payload storage (e.g. IPFS hash).
    /// @param sequence Contiguous counter that must increment by one for each observation.
    /// @param timestamp Unix timestamp for the observation commitment.
    /// @param ed25519Signature Raw signature bytes generated by the device's Ed25519 private key.
    function commitObservation(
        bytes16 deviceId,
        bytes32 contentHash,
        string calldata metadataUri,
        uint64 sequence,
        uint64 timestamp,
        bytes calldata ed25519Signature
    ) external {
        Device storage device = _authorizedDevice(deviceId);
        if (device.lastSequence == type(uint64).max || sequence != device.lastSequence + 1) {
            revert InvalidSequence(device.lastSequence, sequence);
        }
        device.lastSequence = sequence;
        emit ObservationCommitted(
            deviceId,
            contentHash,
            device.ed25519PublicKey,
            metadataUri,
            sequence,
            timestamp,
            ed25519Signature,
            msg.sender
        );
    }

    // =========================================================================
    // View & Helper Functions
    // =========================================================================

    /// @notice Retrieves the full `Device` record for a given `deviceId`.
    /// @param deviceId The 16-byte identifier to look up.
    /// @return Device struct containing public key, EVM address, last sequence, and registration status.
    function getDevice(bytes16 deviceId) external view returns (Device memory) {
        return devices[deviceId];
    }

    /// @notice Internal helper verifying that a device is registered AND `msg.sender` is its authorized EVM address.
    /// @param deviceId Unique identifier of the device.
    /// @return device Storage pointer to the `Device` record.
    function _authorizedDevice(bytes16 deviceId) private view returns (Device storage device) {
        device = _registeredDevice(deviceId);
        if (msg.sender != device.evmAddress) revert Unauthorized();
    }

    /// @notice Internal helper verifying that a device exists in the registry.
    /// @param deviceId Unique identifier of the device.
    /// @return device Storage pointer to the `Device` record.
    function _registeredDevice(bytes16 deviceId) private view returns (Device storage device) {
        device = devices[deviceId];
        if (!device.registered) revert UnknownDevice();
    }
}
