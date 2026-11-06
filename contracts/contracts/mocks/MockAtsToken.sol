// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IAtsHold } from "../interfaces/IAtsHold.sol";

/// @notice Test double that mimics ATS hold-by-partition semantics (escrow-gated execute/release).
contract MockAtsToken {
    struct Hold {
        uint256 amount;
        uint256 expiry;
        address escrow;
        address to;
    }

    mapping(bytes32 => mapping(address => uint256)) public balanceOfByPartition;
    mapping(bytes32 => mapping(address => Hold[])) private _holds;

    function mint(bytes32 partition, address to, uint256 amount) external {
        balanceOfByPartition[partition][to] += amount;
    }

    function createHoldByPartition(
        bytes32 partition,
        uint256 amount,
        uint256 expiry,
        address escrow,
        address to
    ) external returns (uint256 holdId) {
        require(balanceOfByPartition[partition][msg.sender] >= amount, "balance");
        balanceOfByPartition[partition][msg.sender] -= amount;
        _holds[partition][msg.sender].push(Hold(amount, expiry, escrow, to));
        holdId = _holds[partition][msg.sender].length; // ids start at 1 like ATS
    }

    function getHoldForByPartition(
        IAtsHold.HoldIdentifier calldata id
    ) external view returns (uint256, uint256, address, address, bytes memory, bytes memory, uint8) {
        if (id.holdId == 0 || id.holdId > _holds[id.partition][id.tokenHolder].length) return (0, 0, address(0), address(0), "", "", 0);
        Hold storage h = _holds[id.partition][id.tokenHolder][id.holdId - 1];
        return (h.amount, h.expiry, h.escrow, h.to, "", "", 0);
    }

    function executeHoldByPartition(
        IAtsHold.HoldIdentifier calldata id,
        address to,
        uint256 amount
    ) external returns (bool, bytes32) {
        Hold storage h = _holds[id.partition][id.tokenHolder][id.holdId - 1];
        require(msg.sender == h.escrow, "not escrow");
        require(h.amount >= amount, "amount");
        h.amount -= amount;
        balanceOfByPartition[id.partition][to] += amount;
        return (true, id.partition);
    }

    function releaseHoldByPartition(IAtsHold.HoldIdentifier calldata id, uint256 amount) external returns (bool) {
        Hold storage h = _holds[id.partition][id.tokenHolder][id.holdId - 1];
        require(msg.sender == h.escrow, "not escrow");
        require(h.amount >= amount, "amount");
        h.amount -= amount;
        balanceOfByPartition[id.partition][id.tokenHolder] += amount;
        return true;
    }
}
