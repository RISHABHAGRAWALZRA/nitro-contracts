/*
 * Copyright 2019-2020, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* eslint-env node, mocha */

import { ethers, network } from 'hardhat'
import { BigNumber } from '@ethersproject/bignumber'
import { Block, TransactionReceipt } from '@ethersproject/providers'
import { expect } from 'chai'
import {
  Bridge,
  Bridge__factory,
  Inbox,
  Inbox__factory,
  MessageTester,
  RollupMock__factory,
  SequencerInbox,
  SequencerInboxBackwardDiff,
  SequencerInbox__factory,
  SequencerInboxBackwardDiff__factory,
  TransparentUpgradeableProxy__factory,
} from '../../build/types'
import { applyAlias, initializeAccounts } from './utils'
import { Event } from '@ethersproject/contracts'
import { Interface } from '@ethersproject/abi'
import {
  BridgeInterface,
  MessageDeliveredEvent,
} from '../../build/types/src/bridge/Bridge'
import {
  InboxInterface,
  InboxMessageDeliveredEvent
} from '../../build/types/src/bridge/Inbox'
import { Signer } from 'ethers'
import { data } from './batchData.json'
import { solidityKeccak256, solidityPack } from 'ethers/lib/utils'
import { SequencerBatchDeliveredEvent } from '../../build/types/src/bridge/AbsBridge'
import { DelayedMsg, DelayedMsgDelivered } from './types'

const mineBlocks = async (count: number, timeDiffPerBlock = 14) => {
  const block = (await network.provider.send('eth_getBlockByNumber', [
    'latest',
    false,
  ])) as Block
  let timestamp = BigNumber.from(block.timestamp).toNumber()
  for (let i = 0; i < count; i++) {
    timestamp = timestamp + timeDiffPerBlock
    await network.provider.send('evm_mine', [timestamp])
  }
}

describe('SequencerInboxForceInclude', async () => {
  const findMatchingLogs = <TInterface extends Interface, TEvent extends Event>(
    receipt: TransactionReceipt,
    iFace: TInterface,
    eventTopicGen: (i: TInterface) => string
  ): TEvent['args'][] => {
    const logs = receipt.logs.filter(
      log => log.topics[0] === eventTopicGen(iFace)
    )
    return logs.map(l => iFace.parseLog(l).args as TEvent['args'])
  }

  const getMessageDeliveredEvents = (receipt: TransactionReceipt) => {
    const bridgeInterface = Bridge__factory.createInterface()
    return findMatchingLogs<BridgeInterface, MessageDeliveredEvent>(
      receipt,
      bridgeInterface,
      i => i.getEventTopic(i.getEvent('MessageDelivered'))
    )
  }

  const getBatchSpendingReport = (receipt: TransactionReceipt): DelayedMsgDelivered => {
    const res = getMessageDeliveredEvents(receipt)
    return {
      delayedMessage: {
        header: {
          kind: res[0].kind,
          sender: res[0].sender,
          blockNumber: receipt.blockNumber,
          timestamp: Number(res[0].timestamp),
          totalDelayedMessagesRead: Number(res[0].messageIndex),
          baseFee: Number(res[0].baseFeeL1),
          messageDataHash: res[0].messageDataHash
        },
        //spendingReportMsg = abi.encodePacked(block.timestamp, batchPoster, dataHash, seqMessageIndex, block.basefee  );
        messageData: solidityPack(['uint256', 'address', 'bytes32', 'uint256', 'uint256'], 
        [res[0].timestamp, res[0].sender, res[0].messageDataHash, res[0].messageIndex, res[0].baseFeeL1])
      },
      delayedAcc: res[0].beforeInboxAcc,
      delayedCount: Number(res[0].messageIndex)
    }
  }

  const getInboxMessageDeliveredEvents = (receipt: TransactionReceipt) => {
    const inboxInterface = Inbox__factory.createInterface()
    return findMatchingLogs<InboxInterface, InboxMessageDeliveredEvent>(
      receipt,
      inboxInterface,
      i => i.getEventTopic(i.getEvent('InboxMessageDelivered'))
    )
  }

  const getSequencerBatchDeliveredEvents = (receipt: TransactionReceipt) => {
    const bridgeInterface = Bridge__factory.createInterface()
    return findMatchingLogs<BridgeInterface, SequencerBatchDeliveredEvent>(
      receipt,
      bridgeInterface,
      i => i.getEventTopic(i.getEvent('SequencerBatchDelivered'))
    )
  }

  const sendDelayedTx = async (
    sender: Signer,
    inbox: Inbox,
    bridge: Bridge,
    messageTester: MessageTester,
    l2Gas: number,
    l2GasPrice: number,
    nonce: number,
    destAddr: string,
    amount: BigNumber,
    data: string
  ) => {
    const countBefore = (
      await bridge.functions.delayedMessageCount()
    )[0].toNumber()
    // hardcoding a limit since hardhat doesn't estimate gas correctly

    const sendUnsignedTx = await inbox
      .connect(sender)
      .sendUnsignedTransaction(l2Gas, l2GasPrice, nonce, destAddr, amount, data, {gasLimit: 15000000})
    const sendUnsignedTxReceipt = await sendUnsignedTx.wait()

    const countAfter = (
      await bridge.functions.delayedMessageCount()
    )[0].toNumber()
    expect(countAfter, 'Unexpected inbox count').to.eq(countBefore + 1)

    const senderAddr = applyAlias(await sender.getAddress())

    const messageDeliveredEvent = getMessageDeliveredEvents(
      sendUnsignedTxReceipt
    )[0]
    const InboxMessageDeliveredEvent = getInboxMessageDeliveredEvents(
      sendUnsignedTxReceipt
    )[0]
    const l1BlockNumber = sendUnsignedTxReceipt.blockNumber
    const blockL1 = await sender.provider!.getBlock(l1BlockNumber)
    const baseFeeL1 = blockL1.baseFeePerGas!.toNumber()
    const l1BlockTimestamp = blockL1.timestamp
    const delayedAcc = await bridge.delayedInboxAccs(countBefore)

    // need to hex pad the address

    const msgData = ethers.utils.solidityPack(
      ['uint8', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'bytes'],
      [
        0,
        l2Gas,
        l2GasPrice,
        nonce,
        ethers.utils.hexZeroPad(destAddr, 32),
        amount,
        data,
      ])

    const messageDataHash = ethers.utils.solidityKeccak256(
      ['bytes'],
      [msgData]
    )

    expect(
      messageDeliveredEvent.messageDataHash,
      'Incorrect messageDataHash'
    ).to.eq(messageDataHash)

    expect(
      ethers.utils.solidityKeccak256(['bytes'], [InboxMessageDeliveredEvent.data]),
      'Incorrect messageData'
    ).to.eq(messageDataHash)

    const messageHash = (
      await messageTester.functions.messageHash(
        3,
        senderAddr,
        l1BlockNumber,
        l1BlockTimestamp,
        countBefore,
        baseFeeL1,
        messageDataHash
      )
    )[0]

    const prevAccumulator = messageDeliveredEvent.beforeInboxAcc
    expect(prevAccumulator, 'Incorrect prev accumulator').to.eq(
      countBefore === 0
        ? ethers.utils.hexZeroPad('0x', 32)
        : await bridge.delayedInboxAccs(countBefore - 1)
    )

    const nextAcc = (
      await messageTester.functions.accumulateInboxMessage(
        prevAccumulator,
        messageHash
      )
    )[0]

    expect(delayedAcc, 'Incorrect delayed acc').to.eq(nextAcc)

    const delayedMsg: DelayedMsg = {
      header: {
        kind: 3,
        sender: senderAddr,
        blockNumber: l1BlockNumber,
        timestamp: l1BlockTimestamp,
        totalDelayedMessagesRead: countBefore,
        baseFee: baseFeeL1,
        messageDataHash: messageDataHash,
      },
      messageData: msgData,
    }

    return {
      countBefore,
      delayedMsg,
      prevAccumulator,
      inboxAccountLength: countAfter,
    }
  }

  
  const forceIncludeMessages = async (
    sequencerInbox: SequencerInbox,
    newTotalDelayedMessagesRead: number,
    delayedMessage: DelayedMsg,
    expectedErrorType?: string
  ) => {
    const inboxLengthBefore = (await sequencerInbox.batchCount()).toNumber()

    const forceInclusionTx = sequencerInbox.forceInclusion(
      newTotalDelayedMessagesRead,
      delayedMessage.header.kind,
      [delayedMessage.header.blockNumber, delayedMessage.header.timestamp],
      delayedMessage.header.baseFee,
      delayedMessage.header.sender,
      delayedMessage.header.messageDataHash,
    )
    if (expectedErrorType) {
      await expect(forceInclusionTx).to.be.revertedWith(
        `reverted with custom error '${expectedErrorType}()'`
      )
    } else {
      await (await forceInclusionTx).wait()

      const totalDelayedMessagsReadAfter = (
        await sequencerInbox.totalDelayedMessagesRead()
      ).toNumber()
      expect(
        totalDelayedMessagsReadAfter,
        'Incorrect totalDelayedMessagesRead after.'
      ).to.eq(newTotalDelayedMessagesRead)
      const inboxLengthAfter = (await sequencerInbox.batchCount()).toNumber()
      expect(
        inboxLengthAfter - inboxLengthBefore,
        'Inbox not incremented'
      ).to.eq(1)
    }
  }

  const setupSequencerInbox = async (
    maxDelayBlocks = 7200,
    maxDelayTime = 86400,
    deployOpt = false
  ) => {
    const accounts = await initializeAccounts()
    const admin = accounts[0]
    const adminAddr = await admin.getAddress()
    const user = accounts[1]
    const rollupOwner = accounts[2]
    const batchPoster = accounts[3]

    const rollupMockFac = (await ethers.getContractFactory(
      'RollupMock'
    )) as RollupMock__factory
    const rollup = await rollupMockFac.deploy(await rollupOwner.getAddress())
    const inboxFac = (await ethers.getContractFactory(
      'Inbox'
    )) as Inbox__factory
    const inboxTemplate = await inboxFac.deploy(117964)
    const bridgeFac = await ethers.getContractFactory('Bridge')
    const bridgeTemplate = await bridgeFac.deploy()
    const transparentUpgradeableProxyFac = (await ethers.getContractFactory(
      'TransparentUpgradeableProxy'
    )) as TransparentUpgradeableProxy__factory

    const bridgeProxy = await transparentUpgradeableProxyFac.deploy(
      bridgeTemplate.address,
      adminAddr,
      '0x'
    )

    const inboxProxy = await transparentUpgradeableProxyFac.deploy(
      inboxTemplate.address,
      adminAddr,
      '0x'
    )
    const bridge = await bridgeFac.attach(bridgeProxy.address).connect(user)
    const bridgeAdmin = await bridgeFac
      .attach(bridgeProxy.address)
      .connect(rollupOwner)
    await bridge.initialize(rollup.address)

    const sequencerInboxFac = await ethers.getContractFactory(
      deployOpt ? 'SequencerInboxBackwardDiff' : 'SequencerInbox'
    )

    const delayThresholdSeconds = 3600
    const delayThresholdBlocks = 300
    const replenishSecondsPerPeriod = 1 // 48 hours in 2 weeks => 1/7
    const replenishBlocksPerPeriod = 1 // 14200 blocks in 2 weeks => 10/7
    const replenishSecondsPeriod = 7
    const replenishBlocksPeriod = 7
    const maxDelayBufferSeconds = 86400 * 2
    const maxDelayBufferBlocks = 7200 * 2

    const sequencerInbox = deployOpt
      ? await (sequencerInboxFac as SequencerInboxBackwardDiff__factory).deploy(
          bridgeProxy.address,
          {
            delayBlocks: maxDelayBlocks,
            delaySeconds: maxDelayTime,
            futureBlocks: 10,
            futureSeconds: 3000,
          },
          117964,
          delayThresholdSeconds,
          delayThresholdBlocks,
          replenishSecondsPerPeriod,
          replenishBlocksPerPeriod,
          replenishSecondsPeriod,
          replenishBlocksPeriod,
          maxDelayBufferSeconds,
          maxDelayBufferBlocks
        )
      : await (sequencerInboxFac as SequencerInbox__factory).deploy(
          bridgeProxy.address,
          {
            delayBlocks: maxDelayBlocks,
            delaySeconds: maxDelayTime,
            futureBlocks: 10,
            futureSeconds: 3000,
          },
          117964
        )

    const inbox = await inboxFac.attach(inboxProxy.address).connect(user)

    await inbox.initialize(bridgeProxy.address, sequencerInbox.address)

    await bridgeAdmin.setDelayedInbox(inbox.address, true)
    await (bridgeAdmin as Bridge).setSequencerInbox(sequencerInbox.address)

    await (
      await sequencerInbox
        .connect(rollupOwner)
        .setIsBatchPoster(await batchPoster.getAddress(), true)
    ).wait()

    const messageTester = (await (
      await ethers.getContractFactory('MessageTester')
    ).deploy()) as MessageTester

    return {
      user,
      bridge: bridge,
      inbox: inbox,
      sequencerInbox: sequencerInbox as SequencerInbox,
      messageTester,
      inboxProxy,
      inboxTemplate,
      bridgeProxy,
      rollup,
      rollupOwner,
      batchPoster,
    }
  }

  it.only('can add batch', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox, batchPoster } =
      await setupSequencerInbox()
    var delayedInboxPending: DelayedMsgDelivered[] = [];
    const setupOpt = await setupSequencerInbox(7200, 86400, true)
    
    await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    await sendDelayedTx(
      setupOpt.user,
      setupOpt.inbox,
      setupOpt.bridge as Bridge,
      setupOpt.messageTester,
      1000000,
      21000000000,
      0,
      await setupOpt.user.getAddress(),
      BigNumber.from(10),
      '0x1011'
    ).then((res) => {
      delayedInboxPending.push(
        {
          delayedMessage: res.delayedMsg,
          delayedAcc: res.prevAccumulator,
          delayedCount: res.countBefore
        }
      )
    })

    // read all messages
    const messagesRead = await bridge.delayedMessageCount()
    const seqReportedMessageSubCount =
      await bridge.sequencerReportedSubMessageCount()

    await (
      await sequencerInbox
        .connect(batchPoster)
        .addSequencerL2BatchFromOrigin(
          0,
          data,
          messagesRead,
          ethers.constants.AddressZero,
          seqReportedMessageSubCount,
          seqReportedMessageSubCount.add(10),
          { gasLimit: 10000000 }
        )
    ).wait()

    // read all delayed messages
    const messagesReadOpt = await setupOpt.bridge.delayedMessageCount()
    const totalDelayedMessagesRead = (
      await setupOpt.bridge.totalDelayedMessagesRead()
    ).toNumber()

    const beforeDelayedAcc =
      totalDelayedMessagesRead == 0
        ? ethers.constants.HashZero
        : await setupOpt.bridge.delayedInboxAccs(totalDelayedMessagesRead - 1)

    const seqReportedMessageSubCountOpt =
      await setupOpt.bridge.sequencerReportedSubMessageCount()

    // pass proof of the last read delayed message
    var delayedMsgLastRead = delayedInboxPending[delayedInboxPending.length - 1];
    delayedInboxPending = []
    await (
      await (setupOpt.sequencerInbox as unknown as SequencerInboxBackwardDiff)
        .connect(setupOpt.batchPoster)
        [
          'addSequencerL2BatchFromOrigin(uint256,bytes,uint64,address,uint64,uint64,(bytes32,uint8,address,uint64,uint64,uint256,uint256,bytes32))'
        ](
          0,
          data,
          messagesReadOpt,
          ethers.constants.AddressZero,
          seqReportedMessageSubCountOpt,
          seqReportedMessageSubCountOpt.add(10),
          {
            beforeDelayedAcc: beforeDelayedAcc,
            kind: 3,
            sender: delayedMsgLastRead!.delayedMessage.header.sender,
            blockNumber: delayedMsgLastRead!.delayedMessage.header.blockNumber,
            blockTimestamp: delayedMsgLastRead!.delayedMessage.header.timestamp,
            count: delayedMsgLastRead!.delayedCount,
            baseFeeL1: delayedMsgLastRead!.delayedMessage.header.baseFee,
            messageDataHash: delayedMsgLastRead!.delayedMessage.header.messageDataHash
          },
          { gasLimit: 10000000 }
        )
    ).wait().then((res) => {
      delayedInboxPending.push(getBatchSpendingReport(res))
    })
    const delayedMsgLastReadCopy = delayedMsgLastRead
    await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    await sendDelayedTx(
      setupOpt.user,
      setupOpt.inbox,
      setupOpt.bridge as Bridge,
      setupOpt.messageTester,
      1000000,
      21000000000,
      0,
      await setupOpt.user.getAddress(),
      BigNumber.from(10),
      '0x1011'
    ).then((res) => {
      delayedInboxPending.push(
        {
          delayedMessage: res.delayedMsg,
          delayedAcc: res.prevAccumulator,
          delayedCount: res.countBefore
        }
      )
    })


    // 2 delayed messages in the inbox, read 1 messages
    const messagesReadAdd1 = await bridge.delayedMessageCount()
    const seqReportedMessageSubCountAdd1 =
      await bridge.sequencerReportedSubMessageCount()

    const res11 = await (
      await sequencerInbox
        .connect(batchPoster)
        .addSequencerL2BatchFromOrigin(
          1,
          data,
          messagesReadAdd1 - 1,
          ethers.constants.AddressZero,
          seqReportedMessageSubCountAdd1,
          seqReportedMessageSubCountAdd1.add(10),
          { gasLimit: 10000000 }
        )
    ).wait()

    const messagesReadOpt2 = await setupOpt.bridge.delayedMessageCount()
    const seqReportedMessageSubCountOpt2 =
      await setupOpt.bridge.sequencerReportedSubMessageCount()

    // start parole
    // pass delayed message proof
    // read 1 message
    console.log(delayedInboxPending)
    delayedMsgLastRead = delayedInboxPending[delayedInboxPending.length - 2]
    console.log('delayedMsgLastRead', delayedMsgLastRead)
    delayedInboxPending = [delayedInboxPending[delayedInboxPending.length - 1]];
    const res3 = await (
      await (setupOpt.sequencerInbox as unknown as SequencerInboxBackwardDiff)
        .connect(setupOpt.batchPoster)
        .functions[
          'addSequencerL2BatchFromOrigin(uint256,bytes,uint64,address,uint64,uint64,(bytes32,uint8,address,uint64,uint64,uint256,uint256,bytes32))'
        ](
          1,
          data,
          Number(messagesReadOpt2)-1,
          ethers.constants.AddressZero,
          seqReportedMessageSubCountOpt2,
          seqReportedMessageSubCountOpt2.add(10),
          {
            beforeDelayedAcc: delayedMsgLastRead!.delayedAcc,
            kind: delayedMsgLastRead!.delayedMessage.header.kind,
            sender: delayedMsgLastRead!.delayedMessage.header.sender,
            blockNumber: delayedMsgLastRead!.delayedMessage.header.blockNumber,
            blockTimestamp: delayedMsgLastRead!.delayedMessage.header.timestamp,
            count: delayedMsgLastRead!.delayedCount,
            baseFeeL1: delayedMsgLastRead!.delayedMessage.header.baseFee,
            messageDataHash: delayedMsgLastRead!.delayedMessage.header.messageDataHash
          },
          { gasLimit: 10000000 }
        )
    ).wait()
    const lastRead = delayedInboxPending.pop()
    console.log(lastRead)
    delayedInboxPending.push(getBatchSpendingReport(res3))

    const res4 = await (
      await (setupOpt.sequencerInbox as unknown as SequencerInboxBackwardDiff)
        .connect(setupOpt.batchPoster)
        .functions[
          'addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'
        ](
          2,
          data,
          messagesReadOpt2,
          ethers.constants.AddressZero,
          seqReportedMessageSubCountOpt2.add(10),
          seqReportedMessageSubCountOpt2.add(20),
          { gasLimit: 10000000 }
        )
    ).wait()
    const batchSpendingReport = getBatchSpendingReport(res4)
    delayedInboxPending.push(batchSpendingReport)
    const batchDelivered = getSequencerBatchDeliveredEvents(res4)[0]
    const inboxMessageDelivered = getInboxMessageDeliveredEvents(res4)[0]
    console.log('batchDelivered!.delayedAcc', batchDelivered!.delayedAcc)

    const res5 = await (
      await (setupOpt.sequencerInbox as unknown as SequencerInboxBackwardDiff)
        .connect(setupOpt.batchPoster)
        .functions[
          'addSequencerL2BatchFromOrigin(uint256,bytes,uint64,address,uint256,uint256,(bytes32,bytes32,bytes32,(bytes32,uint8,address,uint64,uint64,uint256,uint256,bytes32)))'
        ](
          3,
          data,
          Number(messagesReadOpt2) + 1,
          ethers.constants.AddressZero,
          seqReportedMessageSubCountOpt2.add(20),
          seqReportedMessageSubCountOpt2.add(30),
          {
            beforeAccBeforeAcc: batchDelivered!.beforeAcc,
            beforeAccDataHash: '0x' + inboxMessageDelivered.data.slice(106, 170),
            beforeAccDelayedAcc: batchDelivered!.delayedAcc,
            delayedAccPreimage: {
               beforeDelayedAcc: lastRead!.delayedAcc,
               kind: lastRead!.delayedMessage.header.kind,
               sender: lastRead!.delayedMessage.header.sender,
               blockNumber: lastRead!.delayedMessage.header.blockNumber,
               blockTimestamp: lastRead!.delayedMessage.header.timestamp,
               count: lastRead!.delayedCount,
               baseFeeL1: lastRead!.delayedMessage.header.baseFee,
               messageDataHash: lastRead!.delayedMessage.header.messageDataHash
            }
          },
          { gasLimit: 10000000 }
        )).wait()

    console.log(
      'start parole',
      res11.gasUsed.toNumber() - res3.gasUsed.toNumber()
    )
    console.log('on parole', res11.gasUsed.toNumber() - res4.gasUsed.toNumber())
    console.log('renew parole', res11.gasUsed.toNumber() - res5.gasUsed.toNumber())
  })

  it('can add batch', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox, batchPoster } =
      await setupSequencerInbox()

    await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    const messagesRead = await bridge.delayedMessageCount()
    const seqReportedMessageSubCount =
      await bridge.sequencerReportedSubMessageCount()
    await (
      await sequencerInbox
        .connect(batchPoster)
        .addSequencerL2BatchFromOrigin(
          0,
          data,
          messagesRead,
          ethers.constants.AddressZero,
          seqReportedMessageSubCount,
          seqReportedMessageSubCount.add(10),
          { gasLimit: 10000000 }
        )
    ).wait()
  })

  it('can force-include', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox } =
      await setupSequencerInbox()

    const delayedTx = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )
    const [delayBlocks, , ,] = await sequencerInbox.maxTimeVariation()

    await mineBlocks(delayBlocks.toNumber())

    await forceIncludeMessages(
      sequencerInbox,
      delayedTx.inboxAccountLength,
      delayedTx.delayedMsg
    )
  })

  it('can force-include one after another', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox } =
      await setupSequencerInbox()
    const delayedTx = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    const delayedTx2 = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      1,
      await user.getAddress(),
      BigNumber.from(10),
      '0xdeadface'
    )

    const [delayBlocks, , ,] = await sequencerInbox.maxTimeVariation()

    await mineBlocks(delayBlocks.toNumber())

    await forceIncludeMessages(
      sequencerInbox,
      delayedTx.inboxAccountLength,
      delayedTx.delayedMsg
    )
    await forceIncludeMessages(
      sequencerInbox,
      delayedTx2.inboxAccountLength,
      delayedTx2.delayedMsg
    )
  })

  it('can force-include three at once', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox } =
      await setupSequencerInbox()
    await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )
    await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      1,
      await user.getAddress(),
      BigNumber.from(10),
      '0x101010'
    )
    const delayedTx3 = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      10,
      await user.getAddress(),
      BigNumber.from(10),
      '0x10101010'
    )

    const [delayBlocks, , ,] = await sequencerInbox.maxTimeVariation()
    await mineBlocks(delayBlocks.toNumber())

    await forceIncludeMessages(
      sequencerInbox,
      delayedTx3.inboxAccountLength,
      delayedTx3.delayedMsg
    )
  })

  it('cannot include before max block delay', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox } =
      await setupSequencerInbox(10, 100)
    const delayedTx = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    const [delayBlocks, , ,] = await sequencerInbox.maxTimeVariation()
    await mineBlocks(delayBlocks.toNumber() - 1, 5)

    await forceIncludeMessages(
      sequencerInbox,
      delayedTx.inboxAccountLength,
      delayedTx.delayedMsg,
      'ForceIncludeBlockTooSoon'
    )
  })

  it('cannot include before max time delay', async () => {
    const { user, inbox, bridge, messageTester, sequencerInbox } =
      await setupSequencerInbox(10, 100)
    const delayedTx = await sendDelayedTx(
      user,
      inbox,
      bridge as Bridge,
      messageTester,
      1000000,
      21000000000,
      0,
      await user.getAddress(),
      BigNumber.from(10),
      '0x1010'
    )

    const [delayBlocks, , ,] = await sequencerInbox.maxTimeVariation()
    // mine a lot of blocks - but use a short time per block
    // this should mean enough blocks have passed, but not enough time
    await mineBlocks(delayBlocks.toNumber() + 1, 5)

    await forceIncludeMessages(
      sequencerInbox,
      delayedTx.inboxAccountLength,
      delayedTx.delayedMsg,
      'ForceIncludeTimeTooSoon'
    )
  })

  it('should fail to call sendL1FundedUnsignedTransactionToFork', async function () {
    const { inbox } = await setupSequencerInbox()
    await expect(
      inbox.sendL1FundedUnsignedTransactionToFork(
        0,
        0,
        0,
        ethers.constants.AddressZero,
        '0x'
      )
    ).to.revertedWith('NotForked()')
  })

  it('should fail to call sendUnsignedTransactionToFork', async function () {
    const { inbox } = await setupSequencerInbox()
    await expect(
      inbox.sendUnsignedTransactionToFork(
        0,
        0,
        0,
        ethers.constants.AddressZero,
        0,
        '0x'
      )
    ).to.revertedWith('NotForked()')
  })

  it('should fail to call sendWithdrawEthToFork', async function () {
    const { inbox } = await setupSequencerInbox()
    await expect(
      inbox.sendWithdrawEthToFork(0, 0, 0, 0, ethers.constants.AddressZero)
    ).to.revertedWith('NotForked()')
  })

  it('can upgrade Inbox', async () => {
    const { inboxProxy, inboxTemplate, bridgeProxy } =
      await setupSequencerInbox()

    const currentStorage = []
    for (let i = 0; i < 1024; i++) {
      currentStorage[i] = await inboxProxy.provider!.getStorageAt(
        inboxProxy.address,
        i
      )
    }

    await expect(
      inboxProxy.upgradeToAndCall(
        inboxTemplate.address,
        (
          await inboxTemplate.populateTransaction.postUpgradeInit(
            bridgeProxy.address
          )
        ).data!
      )
    ).to.emit(inboxProxy, 'Upgraded')

    for (let i = 0; i < currentStorage.length; i++) {
      await expect(
        await inboxProxy.provider!.getStorageAt(inboxProxy.address, i)
      ).to.equal(currentStorage[i])
    }
  })
})
