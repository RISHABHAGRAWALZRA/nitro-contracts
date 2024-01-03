// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.4;

import "./AbsBridgeExtended.sol";
import "./Bridge.sol";

/**
 * @title Staging ground for incoming and outgoing messages
 * @notice It is also the ETH escrow for value sent with these messages.
 */
contract BridgeExtended is AbsBridgeExtended, Bridge {}
