// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/nitro/blob/master/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.4;

import "./IBridgeExtended.sol";
import "./AbsBridge.sol";
/**
 * @title Staging ground for incoming and outgoing messages
 * @notice Holds the inbox accumulator for sequenced and delayed messages.
 * Since the escrow is held here, this contract also contains a list of allowed
 * outboxes that can make calls from here and withdraw this escrow.
 */

abstract contract AbsBridgeExtended is AbsBridge, IBridgeExtended {
    function getFirstDelayedAcc() external view returns (bytes32, uint256) {
        return (delayedInboxAccs[totalDelayedMessagesRead], totalDelayedMessagesRead);
    }
}
