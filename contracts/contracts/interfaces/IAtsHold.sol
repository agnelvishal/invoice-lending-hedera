// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal subset of Asset Tokenization Studio's hold-by-partition facet
///         (see ATS IHoldByPartition / IHoldTypes). The invoice token is an ATS diamond
///         that exposes these selectors.
interface IAtsHold {
    struct HoldIdentifier {
        bytes32 partition;
        address tokenHolder;
        uint256 holdId;
    }

    /// @dev Only the hold's `escrow` may call. Moves `_amount` of held tokens to `_to`.
    function executeHoldByPartition(
        HoldIdentifier calldata _holdIdentifier,
        address _to,
        uint256 _amount
    ) external returns (bool success_, bytes32 partition_);

    /// @dev Only the hold's `escrow` may call. Returns `_amount` to the holder.
    function releaseHoldByPartition(
        HoldIdentifier calldata _holdIdentifier,
        uint256 _amount
    ) external returns (bool success_);

    function getHoldForByPartition(
        HoldIdentifier calldata _holdIdentifier
    )
        external
        view
        returns (
            uint256 amount_,
            uint256 expirationTimestamp_,
            address escrow_,
            address destination_,
            bytes memory data_,
            bytes memory operatorData_,
            uint8 thirdPartyType_
        );
}
