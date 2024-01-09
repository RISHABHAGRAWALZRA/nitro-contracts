// Copyright 2023, Offchain Labs, Inc.

// solhint-disable-next-line compiler-version
pragma solidity >=0.6.9 <0.9.0;
pragma experimental ABIEncoderV2;

import "./IBridge.sol";

interface ILegacySequencerInbox {
    event SequencerBatchDelivered(
        uint256 indexed batchSequenceNumber,
        bytes32 indexed beforeAcc,
        bytes32 indexed afterAcc,
        bytes32 delayedAcc,
        uint256 afterDelayedMessagesRead,
        IBridge.TimeBounds timeBounds,
        IBridge.BatchDataLocation dataLocation
    );
}
