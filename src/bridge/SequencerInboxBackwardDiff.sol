// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {
    AlreadyInit,
    HadZeroInit,
    NotOrigin,
    DataTooLarge,
    NotRollup,
    DelayedBackwards,
    DelayedTooFar,
    ForceIncludeBlockTooSoon,
    ForceIncludeTimeTooSoon,
    IncorrectMessagePreimage,
    NotBatchPoster,
    BadSequencerNumber,
    DataNotAuthenticated,
    AlreadyValidDASKeyset,
    NoSuchKeyset,
    NotForked,
    NotOwner,
    RollupNotChanged
} from "../libraries/Error.sol";
import "./IBridge.sol";
import "./IInboxBase.sol";
import "./ISequencerInboxBackwardDiff.sol";
import "../rollup/IRollupLogic.sol";
import "./Messages.sol";
import "../precompiles/ArbGasInfo.sol";
import "../precompiles/ArbSys.sol";

import {L1MessageType_batchPostingReport} from "../libraries/MessageTypes.sol";
import {GasRefundEnabled, IGasRefunder} from "../libraries/IGasRefunder.sol";
import "../libraries/ArbitrumChecker.sol";

/**
 * @title Accepts batches from the sequencer and adds them to the rollup inbox.
 * @notice Contains the inbox accumulator which is the ordering of all data and transactions to be processed by the rollup.
 * As part of submitting a batch the sequencer is also expected to include items enqueued
 * in the delayed inbox (Bridge.sol). If items in the delayed inbox are not included by a
 * sequencer within a time limit they can be force included into the rollup inbox by anyone.
 */
contract SequencerInboxBackwardDiff is GasRefundEnabled, ISequencerInboxBackwardDiff {
    IBridge public immutable bridge;

    /// @inheritdoc ISequencerInboxBackwardDiff
    uint256 public constant HEADER_LENGTH = 40;

    /// @inheritdoc ISequencerInboxBackwardDiff
    bytes1 public constant DATA_AUTHENTICATED_FLAG = 0x40;

    IOwnable public rollup;
    mapping(address => BatchPosterData) public batchPosterData;
    // see ISequencerInbox.MaxTimeVariation
    uint256 internal immutable delayBlocks;
    uint256 internal immutable futureBlocks;
    uint256 internal immutable delaySeconds;
    uint256 internal immutable futureSeconds;

    uint256 internal immutable delayThresholdSeconds; // O(expected delay seconds)
    uint256 internal immutable delayThresholdBlocks; // O(expected delay blocks)
    uint256 internal immutable maxDelayBufferSeconds;
    uint256 internal immutable maxDelayBufferBlocks;

    uint256 public immutable replenishSecondsPerPeriod;
    uint256 public immutable replenishBlocksPerPeriod;
    uint256 public immutable replenishSecondsPeriod;
    uint256 public immutable replenishBlocksPeriod;

    mapping(bytes32 => DasKeySetInfo) public dasKeySetInfo;

    modifier onlyRollupOwner() {
        if (msg.sender != rollup.owner()) revert NotOwner(msg.sender, address(rollup));
        _;
    }

    DelayData public delayData;
    DelayHistory public delayHistory;
    SequencerStatus public sequencerStatus;

    mapping(address => bool) public isSequencer;

    // On L1 this should be set to 117964: 90% of Geth's 128KB tx size limit, leaving ~13KB for proving
    uint256 public immutable maxDataSize;
    uint256 internal immutable deployTimeChainId = block.chainid;
    // If the chain this SequencerInbox is deployed on is an Arbitrum chain.
    bool internal immutable hostChainIsArbitrum = ArbitrumChecker.runningOnArbitrum();

    constructor(
        IBridge bridge_,
        ISequencerInboxBackwardDiff.MaxTimeVariation memory maxTimeVariation_,
        uint256 _maxDataSize,
        uint256 _delayThresholdSeconds,
        uint256 _delayThresholdBlocks,
        uint256 _replenishSecondsPerPeriod,
        uint256 _replenishBlocksPerPeriod,
        uint256 _replenishSecondsPeriod,
        uint256 _replenishBlocksPeriod,
        uint256 _maxDelayBufferSeconds,
        uint256 _maxDelayBufferBlocks
    ) {
        if (bridge_ == IBridge(address(0))) revert HadZeroInit();
        bridge = bridge_;
        rollup = bridge_.rollup();
        if (address(rollup) == address(0)) revert RollupNotChanged();
        delayBlocks = maxTimeVariation_.delayBlocks;
        futureBlocks = maxTimeVariation_.futureBlocks;
        delaySeconds = maxTimeVariation_.delaySeconds;
        futureSeconds = maxTimeVariation_.futureSeconds;
        delayThresholdSeconds = _delayThresholdSeconds;
        delayThresholdBlocks = _delayThresholdBlocks;
        replenishSecondsPerPeriod = _replenishSecondsPerPeriod;
        replenishBlocksPerPeriod = _replenishBlocksPerPeriod;
        replenishSecondsPeriod = _replenishSecondsPeriod;
        replenishBlocksPeriod = _replenishBlocksPeriod;
        maxDelayBufferSeconds = _maxDelayBufferSeconds;
        maxDelayBufferBlocks = _maxDelayBufferBlocks;
        maxDataSize = _maxDataSize;
        delayData = DelayData({
            delayBufferBlocks: uint64(_maxDelayBufferBlocks),
            delayBufferSeconds: uint64(_maxDelayBufferSeconds),
            happyPathValidUntilTimestamp: 0,
            happyPathValidUntilBlockNumber: 0
        });
        sequencerStatus.happyPathTimestampSeqIndex = uint64(bridge.sequencerMessageCount());
        sequencerStatus.happyPathBlockNumberSeqIndex = uint64(bridge.sequencerMessageCount());
    }

    function _chainIdChanged() internal view returns (bool) {
        return deployTimeChainId != block.chainid;
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function updateRollupAddress() external {
        if (msg.sender != IOwnable(rollup).owner()) {
            revert NotOwner(msg.sender, IOwnable(rollup).owner());
        }
        IOwnable newRollup = bridge.rollup();
        if (rollup == newRollup) revert RollupNotChanged();
        rollup = newRollup;
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function totalDelayedMessagesRead() public view returns (uint256) {
        return bridge.totalDelayedMessagesRead();
    }

    function getTimeBounds(uint256 delayBufferBlocks, uint256 delayBufferSeconds)
        internal
        view
        virtual
        returns (IBridge.TimeBounds memory)
    {
        IBridge.TimeBounds memory bounds;
        ISequencerInboxBackwardDiff.MaxTimeVariation memory maxTimeVariation_ =
            maxTimeVariation(delayBufferBlocks, delayBufferSeconds);
        if (block.timestamp > maxTimeVariation_.delaySeconds) {
            bounds.minTimestamp = uint64(block.timestamp - maxTimeVariation_.delaySeconds);
        }
        bounds.maxTimestamp = uint64(block.timestamp + maxTimeVariation_.futureSeconds);
        if (block.number > maxTimeVariation_.delayBlocks) {
            bounds.minBlockNumber = uint64(block.number - maxTimeVariation_.delayBlocks);
        }
        bounds.maxBlockNumber = uint64(block.number + maxTimeVariation_.futureBlocks);
        return (bounds);
    }

    function maxTimeVariation(uint256 delayBufferBlocks, uint256 delayBufferSeconds)
        internal
        view
        returns (ISequencerInboxBackwardDiff.MaxTimeVariation memory)
    {
        if (_chainIdChanged()) {
            return ISequencerInboxBackwardDiff.MaxTimeVariation({
                delayBlocks: 1,
                futureBlocks: 1,
                delaySeconds: 1,
                futureSeconds: 1
            });
        } else {
            return (
                ISequencerInboxBackwardDiff.MaxTimeVariation({
                    delayBlocks: delayBlocks < delayBufferBlocks ? delayBlocks : delayBufferBlocks,
                    futureBlocks: futureBlocks,
                    delaySeconds: delaySeconds < delayBufferSeconds ? delaySeconds : delayBufferSeconds,
                    futureSeconds: futureSeconds
                })
            );
        }
    }

    function maxTimeVariation()
        external
        view
        returns (ISequencerInboxBackwardDiff.MaxTimeVariation memory)
    {
        return maxTimeVariation(delayData.delayBufferBlocks, delayData.delayBufferSeconds);
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function forceInclusion(
        uint64 _totalDelayedMessagesRead,
        uint8 kind,
        uint64[2] calldata l1BlockAndTime,
        uint256 baseFeeL1,
        address sender,
        bytes32 messageDataHash
    ) external {
        if (_totalDelayedMessagesRead <= totalDelayedMessagesRead()) revert DelayedBackwards();
        DelayData memory _delayData = delayData;
        {
            DelayHistory memory _delayHistory = delayHistory;

            _delayData.delayBufferSeconds = uint64(
                calculateBuffer(
                    _delayHistory.timestamp,
                    uint64(l1BlockAndTime[0]),
                    _delayHistory.delaySeconds,
                    uint64(delayThresholdSeconds),
                    _delayData.delayBufferSeconds
                )
            );

            _delayData.delayBufferBlocks = uint64(
                calculateBuffer(
                    _delayHistory.blockNumber,
                    uint64(l1BlockAndTime[1]),
                    _delayHistory.delayBlocks,
                    uint64(delayThresholdBlocks),
                    _delayData.delayBufferBlocks
                )
            );
            delayData = _delayData;
            _delayHistory.timestamp = uint64(l1BlockAndTime[0]);
            _delayHistory.blockNumber = uint64(l1BlockAndTime[1]);
            _delayHistory.delaySeconds = uint64(block.timestamp) - l1BlockAndTime[0];
            _delayHistory.delayBlocks = uint64(block.number) - l1BlockAndTime[1];
            delayHistory = _delayHistory;
        }
        bytes32 messageHash = Messages.messageHash(
            kind,
            sender,
            l1BlockAndTime[0],
            l1BlockAndTime[1],
            _totalDelayedMessagesRead - 1,
            baseFeeL1,
            messageDataHash
        );

        // Verify that message hash represents the last message sequence of delayed message to be included
        bytes32 prevDelayedAcc = 0;
        if (_totalDelayedMessagesRead > 1) {
            prevDelayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead - 2);
        }
        if (
            bridge.delayedInboxAccs(_totalDelayedMessagesRead - 1)
                != Messages.accumulateInboxMessage(prevDelayedAcc, messageHash)
        ) revert IncorrectMessagePreimage();

        ISequencerInboxBackwardDiff.MaxTimeVariation memory maxTimeVariation_ =
            maxTimeVariation(_delayData.delayBufferBlocks, _delayData.delayBufferSeconds);
        // Can only force-include after the Sequencer-only window has expired.
        if (l1BlockAndTime[0] + maxTimeVariation_.delayBlocks >= block.number) {
            revert ForceIncludeBlockTooSoon();
        }
        if (l1BlockAndTime[1] + maxTimeVariation_.delaySeconds >= block.timestamp) {
            revert ForceIncludeTimeTooSoon();
        }

        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formEmptyDataHash(
            _totalDelayedMessagesRead, _delayData.delayBufferBlocks, _delayData.delayBufferSeconds
        );

        uint256 prevSeqMsgCount = bridge.sequencerReportedSubMessageCount();
        uint256 newSeqMsgCount =
            prevSeqMsgCount + _totalDelayedMessagesRead - bridge.totalDelayedMessagesRead();
        addSequencerL2BatchImpl(
            dataHash,
            _totalDelayedMessagesRead,
            0,
            prevSeqMsgCount,
            newSeqMsgCount,
            timeBounds,
            IBridge.BatchDataLocation.NoData
        );
    }

    // unhappy path
    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint64 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint64 prevMessageCount,
        uint64 newMessageCount,
        DelayAccPreimage calldata pData
    ) external refundsGas(gasRefunder) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        {
            uint256 _totalDelayedMessagesRead = bridge.totalDelayedMessagesRead();
            bytes32 delayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead);
            require(
                afterDelayedMessagesRead > _totalDelayedMessagesRead,
                "Must sequence atleast one delayed message."
            );
            require(
                isValidDelayedAccPreimage(pData, delayedAcc), "Invalid next delayed acc preimage."
            );
        }
        DelayData memory _delayData = delayData;

        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formDataHash(
            data,
            afterDelayedMessagesRead,
            _delayData.delayBufferBlocks,
            _delayData.delayBufferSeconds
        );

        (uint256 seqMessageIndex,) = addSequencerL2BatchImpl(
            dataHash,
            afterDelayedMessagesRead,
            data.length,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.TxInput
        );
        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        DelayHistory memory _delayHistory = delayHistory;
        SequencerStatus memory _sequencerStatus = sequencerStatus;

        if (uint256(_delayHistory.delaySeconds) > delayThresholdSeconds) {
            // unhappy path: prev batch is late
            // decrease delay buffers from pending delayHistory
            _delayData.delayBufferSeconds = uint64(
                calculateBuffer(
                    uint256(_delayHistory.timestamp),
                    uint256(pData.blockTimestamp),
                    uint256(_delayHistory.delaySeconds),
                    delayThresholdSeconds,
                    uint256(_delayData.delayBufferSeconds)
                )
            );
            if (block.timestamp - uint256(pData.blockTimestamp) <= delayThresholdSeconds) {
                // unhappy path -> happy path: prev batch is late and this batch is timely
                // reset replenish pool
                _sequencerStatus.replenishPooledSeconds = uint64(0);
                _sequencerStatus.happyPathTimestampSeqIndex = uint64(seqMessageIndex);
            }
        } else if (block.timestamp - uint256(pData.blockTimestamp) <= delayThresholdSeconds) {
            // happy path: prev batch is timely AND this batch is timely
            if (uint256(_delayData.delayBufferSeconds) < maxDelayBufferSeconds) {
                (_delayData.delayBufferSeconds, _sequencerStatus.replenishPooledSeconds) =
                calculateReplenish(
                    uint256(_delayHistory.timestamp),
                    uint256(pData.blockTimestamp),
                    uint256(_sequencerStatus.replenishPooledSeconds),
                    replenishSecondsPeriod,
                    replenishSecondsPerPeriod,
                    uint256(_delayData.delayBufferSeconds),
                    maxDelayBufferSeconds
                );
            }
            // store timewindow during which no proof is required
            _delayData.happyPathValidUntilTimestamp =
                uint64(uint256(pData.blockTimestamp) + delayThresholdSeconds);
            if (uint256(_delayData.delayBufferSeconds) == maxDelayBufferSeconds) {
                // store timewindow locally for batchPoster, so that it can be used cheaply for future batches
                batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilTimestamp =
                    uint64(uint256(pData.blockTimestamp) + delayThresholdSeconds);
            }
        } else {
            // happy path -> unhappy path: prev batch is timely and this batch is late
            // do nothing, delay buffer will be decreased in next batch
        }

        if (uint256(_delayHistory.delayBlocks) > delayThresholdBlocks) {
            // unhappy path: prev batch is late
            // decrease delay buffers from pending delayHistory
            _delayData.delayBufferBlocks = uint64(
                calculateBuffer(
                    uint256(_delayHistory.blockNumber),
                    uint256(pData.blockNumber),
                    uint256(_delayHistory.delayBlocks),
                    delayThresholdBlocks,
                    uint256(_delayData.delayBufferBlocks)
                )
            );
            if (block.number - uint256(pData.blockNumber) <= delayThresholdBlocks) {
                // unhappy path -> happy path: prev batch is late and this batch is timely
                // reset replenish pool
                _sequencerStatus.replenishPooledBlocks = uint64(0);
                _sequencerStatus.happyPathBlockNumberSeqIndex = uint64(seqMessageIndex);
            }
        } else if (block.number - uint256(pData.blockNumber) <= delayThresholdBlocks) {
            // happy path: prev batch is timely AND this batch is timely
            if (uint256(_delayData.delayBufferBlocks) < maxDelayBufferBlocks) {
                (_delayData.delayBufferBlocks, _sequencerStatus.replenishPooledBlocks) =
                calculateReplenish(
                    uint256(_delayHistory.blockNumber),
                    uint256(pData.blockNumber),
                    uint256(_sequencerStatus.replenishPooledBlocks),
                    replenishBlocksPeriod,
                    replenishBlocksPerPeriod,
                    uint256(_delayData.delayBufferBlocks),
                    maxDelayBufferBlocks
                );
            }
            // store blockwindow during which no proof is required
            _delayData.happyPathValidUntilBlockNumber =
                uint64(uint256(pData.blockNumber) + delayThresholdBlocks);
            if (uint256(_delayData.delayBufferBlocks) == maxDelayBufferBlocks) {
                // store blockwindow locally for batchPoster, so that it can be used cheaply for future batches
                batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilBlockNumber =
                    uint64(uint256(pData.blockNumber) + delayThresholdBlocks);
            }
        } else {
            // happy path -> unhappy path: prev batch is timely and this batch is late
            // do nothing, delay buffer will be decreased in next batch
        }

        delayData = _delayData;
        sequencerStatus = _sequencerStatus;

        _delayHistory.blockNumber = pData.blockNumber;
        _delayHistory.timestamp = pData.blockTimestamp;
        _delayHistory.delaySeconds = uint64(block.timestamp - uint256(pData.blockTimestamp));
        _delayHistory.delayBlocks = uint64(block.number - uint256(pData.blockNumber));
        delayHistory = _delayHistory;
    }

    // renew parole
    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint64 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        InboxAccPreimage calldata pData
    ) external refundsGas(gasRefunder) {
        bytes32 beforeAcc = addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            afterDelayedMessagesRead,
            gasRefunder,
            prevMessageCount,
            newMessageCount
        );
        if (beforeAcc != bytes32(0)) {
            require(
                beforeAcc
                    == keccak256(
                        abi.encodePacked(
                            pData.beforeAccBeforeAcc, pData.beforeAccDataHash, pData.beforeAccDelayedAcc
                        )
                    ),
                "Invalid inbox acc preimage."
            );
            require(
                isValidDelayedAccPreimage(pData.delayedAccPreimage, pData.beforeAccDelayedAcc),
                "Invalid delayed acc preimage."
            );

            delayData.happyPathValidUntilBlockNumber =
                uint64(pData.delayedAccPreimage.blockNumber + delayThresholdBlocks);
            delayData.happyPathValidUntilTimestamp =
                uint64(pData.delayedAccPreimage.blockTimestamp + delayThresholdSeconds);
            if (uint256(delayData.delayBufferBlocks) == maxDelayBufferBlocks) {
                batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilBlockNumber =
                    uint64(uint256(pData.delayedAccPreimage.blockNumber) + delayThresholdBlocks);
            }
            if (uint256(delayData.delayBufferSeconds) == maxDelayBufferSeconds) {
                batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilTimestamp =
                    uint64(uint256(pData.delayedAccPreimage.blockTimestamp) + delayThresholdSeconds);
            }
        }
    }

    // on parole
    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) public refundsGas(gasRefunder) returns (bytes32) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        bytes32 dataHash;
        IBridge.TimeBounds memory timeBounds;
        if (
            uint256(batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilBlockNumber)
                > block.number
                && uint256(batchPosterData[msg.sender].maxBufferAndHappyPathValidUntilTimestamp)
                    > block.timestamp
        ) {
            (dataHash, timeBounds) = formDataHash(
                data, afterDelayedMessagesRead, maxDelayBufferBlocks, maxDelayBufferSeconds
            );
        } else {
            DelayData memory _delayData = delayData;
            require(
                block.timestamp < _delayData.happyPathValidUntilTimestamp,
                "Must be within safe timelimt."
            );
            require(
                block.number < _delayData.happyPathValidUntilBlockNumber,
                "Must be within safe blocklimit."
            );

            (dataHash, timeBounds) = formDataHash(
                data,
                afterDelayedMessagesRead,
                uint256(_delayData.delayBufferBlocks),
                uint256(_delayData.delayBufferSeconds)
            );
        }

        (uint256 seqMessageIndex, bytes32 beforeAcc) = addSequencerL2BatchImpl(
            dataHash,
            afterDelayedMessagesRead,
            data.length,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.TxInput
        );

        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        return beforeAcc;
    }

    function isValidDelayedAccPreimage(DelayAccPreimage memory preimage, bytes32 delayedAcc)
        internal
        pure
        returns (bool)
    {
        return delayedAcc
            == Messages.accumulateInboxMessage(
                preimage.beforeDelayedAcc,
                Messages.messageHash(
                    preimage.kind,
                    preimage.sender,
                    preimage.blockNumber,
                    preimage.blockTimestamp,
                    preimage.count,
                    preimage.baseFeeL1,
                    preimage.messageDataHash
                )
            );
    }

    function calculateBuffer(
        uint256 start,
        uint256 end,
        uint256 delay,
        uint256 threshold,
        uint256 buffer
    ) internal pure returns (uint256) {
        uint256 elapsed = end > start ? end - start : 0;
        uint256 unexpectedDelay = delay > threshold ? delay - threshold : 0;
        uint256 decrease = unexpectedDelay > elapsed ? elapsed : unexpectedDelay;
        buffer = decrease > buffer ? 0 : buffer - decrease;
        buffer = buffer > threshold ? buffer : threshold;
        return buffer;
    }

    function calculateReplenish(
        uint256 start,
        uint256 end,
        uint256 repelenishPool,
        uint256 replenishPeriod,
        uint256 replenishPerPeriod,
        uint256 buffer,
        uint256 maxBuffer
    ) internal pure returns (uint64, uint64) {
        uint256 elapsed = end > start ? end - start + repelenishPool : 0;
        uint256 replenish = (elapsed / replenishPeriod) * replenishPerPeriod;
        repelenishPool = elapsed % replenishPeriod;
        buffer += replenish;
        if (buffer > maxBuffer) {
            buffer = maxBuffer;
            repelenishPool = 0;
        }
        return (uint64(buffer), uint64(repelenishPool));
    }

    modifier validateBatchData(bytes calldata data) {
        uint256 fullDataLen = HEADER_LENGTH + data.length;
        if (fullDataLen > maxDataSize) revert DataTooLarge(fullDataLen, maxDataSize);
        if (data.length > 0 && (data[0] & DATA_AUTHENTICATED_FLAG) == DATA_AUTHENTICATED_FLAG) {
            revert DataNotAuthenticated();
        }
        // the first byte is used to identify the type of batch data
        // das batches expect to have the type byte set, followed by the keyset (so they should have at least 33 bytes)
        if (data.length >= 33 && data[0] & 0x80 != 0) {
            // we skip the first byte, then read the next 32 bytes for the keyset
            bytes32 dasKeysetHash = bytes32(data[1:33]);
            if (!dasKeySetInfo[dasKeysetHash].isValidKeyset) revert NoSuchKeyset(dasKeysetHash);
        }
        _;
    }

    function packHeader(
        uint256 afterDelayedMessagesRead,
        uint256 delayBufferBlocks,
        uint256 delayBufferSeconds
    ) internal view returns (bytes memory, IBridge.TimeBounds memory) {
        (IBridge.TimeBounds memory timeBounds) =
            getTimeBounds(delayBufferBlocks, delayBufferSeconds);
        bytes memory header = abi.encodePacked(
            timeBounds.minTimestamp,
            timeBounds.maxTimestamp,
            timeBounds.minBlockNumber,
            timeBounds.maxBlockNumber,
            uint64(afterDelayedMessagesRead)
        );
        // This must always be true from the packed encoding
        assert(header.length == HEADER_LENGTH);
        return (header, timeBounds);
    }

    function formDataHash(
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        uint256 delayBufferBlocks,
        uint256 delayBufferSeconds
    ) internal view validateBatchData(data) returns (bytes32, IBridge.TimeBounds memory) {
        (bytes memory header, IBridge.TimeBounds memory timeBounds) =
            packHeader(afterDelayedMessagesRead, delayBufferBlocks, delayBufferSeconds);
        bytes32 dataHash = keccak256(bytes.concat(header, data));
        return (dataHash, timeBounds);
    }

    function formEmptyDataHash(
        uint64 afterDelayedMessagesRead,
        uint64 delayBufferBlocks,
        uint64 delayBufferSeconds
    ) internal view returns (bytes32, IBridge.TimeBounds memory) {
        (bytes memory header, IBridge.TimeBounds memory timeBounds) =
            packHeader(afterDelayedMessagesRead, delayBufferBlocks, delayBufferSeconds);
        return (keccak256(header), timeBounds);
    }

    function addSequencerL2BatchImpl(
        bytes32 dataHash,
        uint256 afterDelayedMessagesRead,
        uint256 calldataLengthPosted,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        IBridge.TimeBounds memory timeBounds,
        IBridge.BatchDataLocation batchDataLocation
    ) internal returns (uint256 seqMessageIndex, bytes32 beforeAcc) {
        (seqMessageIndex, beforeAcc,,) = bridge.enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            batchDataLocation
        );

        if (calldataLengthPosted > 0) {
            // this msg isn't included in the current sequencer batch, but instead added to
            // the delayed messages queue that is yet to be included
            address batchPoster = msg.sender;
            bytes memory spendingReportMsg;
            if (hostChainIsArbitrum) {
                // Include extra gas for the host chain's L1 gas charging
                uint256 l1Fees = ArbGasInfo(address(0x6c)).getCurrentTxL1GasFees();
                uint256 extraGas = l1Fees / block.basefee;
                require(extraGas <= type(uint64).max, "L1_GAS_NOT_UINT64");
                spendingReportMsg = abi.encodePacked(
                    block.timestamp,
                    batchPoster,
                    dataHash,
                    seqMessageIndex,
                    block.basefee,
                    uint64(extraGas)
                );
            } else {
                spendingReportMsg = abi.encodePacked(
                    block.timestamp, batchPoster, dataHash, seqMessageIndex, block.basefee
                );
            }
            uint256 msgNum =
                bridge.submitBatchSpendingReport(batchPoster, keccak256(spendingReportMsg));
            // this is the same event used by Inbox.sol after including a message to the delayed message accumulator
            emit InboxMessageDelivered(msgNum, spendingReportMsg);
        }
    }

    function inboxAccs(uint256 index) external view returns (bytes32) {
        return bridge.sequencerInboxAccs(index);
    }

    function batchCount() external view returns (uint256) {
        return bridge.sequencerMessageCount();
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function setIsBatchPoster(address addr, bool isBatchPoster_) external onlyRollupOwner {
        batchPosterData[addr].isBatchPoster = isBatchPoster_;
        // we used to have OwnerFunctionCalled(0) for setting the maxTimeVariation
        // so we dont use index = 0 here, even though this is the first owner function
        // to stay compatible with legacy events
        emit OwnerFunctionCalled(1);
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function setValidKeyset(bytes calldata keysetBytes) external onlyRollupOwner {
        uint256 ksWord = uint256(keccak256(bytes.concat(hex"fe", keccak256(keysetBytes))));
        bytes32 ksHash = bytes32(ksWord ^ (1 << 255));
        require(keysetBytes.length < 64 * 1024, "keyset is too large");

        if (dasKeySetInfo[ksHash].isValidKeyset) revert AlreadyValidDASKeyset(ksHash);
        uint256 creationBlock = block.number;
        if (hostChainIsArbitrum) {
            creationBlock = ArbSys(address(100)).arbBlockNumber();
        }
        dasKeySetInfo[ksHash] =
            DasKeySetInfo({isValidKeyset: true, creationBlock: uint64(creationBlock)});
        emit SetValidKeyset(ksHash, keysetBytes);
        emit OwnerFunctionCalled(2);
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function invalidateKeysetHash(bytes32 ksHash) external onlyRollupOwner {
        if (!dasKeySetInfo[ksHash].isValidKeyset) revert NoSuchKeyset(ksHash);
        // we don't delete the block creation value since its used to fetch the SetValidKeyset
        // event efficiently. The event provides the hash preimage of the key.
        // this is still needed when syncing the chain after a keyset is invalidated.
        dasKeySetInfo[ksHash].isValidKeyset = false;
        emit InvalidateKeyset(ksHash);
        emit OwnerFunctionCalled(3);
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function setIsSequencer(address addr, bool isSequencer_) external onlyRollupOwner {
        isSequencer[addr] = isSequencer_;
        emit OwnerFunctionCalled(4);
    }

    function isValidKeysetHash(bytes32 ksHash) external view returns (bool) {
        return dasKeySetInfo[ksHash].isValidKeyset;
    }

    function isBatchPoster(address addr) public view returns (bool) {
        return batchPosterData[addr].isBatchPoster;
    }

    /// @inheritdoc ISequencerInboxBackwardDiff
    function getKeysetCreationBlock(bytes32 ksHash) external view returns (uint256) {
        DasKeySetInfo memory ksInfo = dasKeySetInfo[ksHash];
        if (ksInfo.creationBlock == 0) revert NoSuchKeyset(ksHash);
        return uint256(ksInfo.creationBlock);
    }
}
