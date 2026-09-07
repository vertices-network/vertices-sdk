// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {VerticesAttestationRegistry} from "../src/VerticesAttestationRegistry.sol";

contract DeviceActor {
    function commit(VerticesAttestationRegistry registry, bytes16 id, bytes32 contentHash, uint64 sequence) external {
        registry.commitObservation(id, contentHash, "ipfs://bafy-test", sequence, 1_725_000_000, hex"01");
    }

    function rotate(VerticesAttestationRegistry registry, bytes16 id, address next) external {
        registry.rotateEvmAddress(id, next);
    }

    function revoke(VerticesAttestationRegistry registry, bytes16 id) external {
        registry.revokeDevice(id);
    }
}

contract VerticesAttestationRegistryTest {
    // device id must be unique and never larger than 16 bytes
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes16 private constant DEVICE_ID = bytes16("vertices-1234");
    VerticesAttestationRegistry private registry;
    DeviceActor private device;
    DeviceActor private successor;

    function setUp() public {
        registry = new VerticesAttestationRegistry(address(this));
        device = new DeviceActor();
        successor = new DeviceActor();
        registry.registerDevice(DEVICE_ID, bytes32(uint256(7)), address(device));
    }

    function testCommitAndRotation() public {
        device.commit(registry, DEVICE_ID, bytes32(uint256(1)), 1);
        VerticesAttestationRegistry.Device memory registeredDevice = registry.getDevice(DEVICE_ID);
        require(registeredDevice.registered && registeredDevice.lastSequence == 1, "commit was not recorded");
        registry.rotateEvmAddress(DEVICE_ID, address(successor));
        successor.commit(registry, DEVICE_ID, bytes32(uint256(2)), 2);
        VerticesAttestationRegistry.Device memory rotatedDevice = registry.getDevice(DEVICE_ID);
        require(rotatedDevice.evmAddress == address(successor) && rotatedDevice.lastSequence == 2, "rotation failed");
    }

    function testRejectsRepeatedSequence() public {
        device.commit(registry, DEVICE_ID, bytes32(uint256(1)), 1);
        (bool ok,) =
            address(device).call(abi.encodeCall(DeviceActor.commit, (registry, DEVICE_ID, bytes32(uint256(2)), 1)));
        require(!ok, "repeated sequence accepted");
    }

    function testRejectsSkippedSequence() public {
        (bool ok,) =
            address(device).call(abi.encodeCall(DeviceActor.commit, (registry, DEVICE_ID, bytes32(uint256(1)), 2)));
        require(!ok, "skipped sequence accepted");
    }

    function testRejectsUnauthorizedCommit() public {
        (bool ok,) =
            address(successor).call(abi.encodeCall(DeviceActor.commit, (registry, DEVICE_ID, bytes32(uint256(1)), 1)));
        require(!ok, "unauthorized commitment accepted");
    }

    function testRejectsDeviceKeyRotation() public {
        (bool ok,) = address(device).call(abi.encodeCall(DeviceActor.rotate, (registry, DEVICE_ID, address(successor))));
        require(!ok, "device was allowed to rotate its identity");
    }

    function testRevokeDevice() public {
        registry.revokeDevice(DEVICE_ID);
        VerticesAttestationRegistry.Device memory revokedDevice = registry.getDevice(DEVICE_ID);
        require(revokedDevice.registered, "device should remain registered");
        require(revokedDevice.evmAddress == address(0), "evmAddress should be zeroed");

        (bool ok,) =
            address(device).call(abi.encodeCall(DeviceActor.commit, (registry, DEVICE_ID, bytes32(uint256(1)), 1)));
        require(!ok, "revoked device was allowed to commit observation");
    }

    function testRejectsUnauthorizedRevocation() public {
        (bool ok,) = address(device).call(abi.encodeCall(DeviceActor.revoke, (registry, DEVICE_ID)));
        require(!ok, "non-owner was allowed to revoke device");
    }
}
