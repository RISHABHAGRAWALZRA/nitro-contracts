// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

// solhint-disable-next-line compiler-version
pragma solidity >=0.6.9 <0.9.0;
pragma experimental ABIEncoderV2;

import "./IOwnable.sol";
import "./IBridge.sol";

interface IBridgeExtended is IBridge {
    function getFirstDelayedAcc() external view returns (bytes32, uint256);
}
