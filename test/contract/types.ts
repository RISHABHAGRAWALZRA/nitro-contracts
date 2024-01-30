export type DelayedMsgHeader = {
    kind: number;
    sender: string; 
    blockNumber: number;
    timestamp: number;
    totalDelayedMessagesRead: number;
    baseFee: number;
    messageDataHash: string;
}

export type DelayedMsg = {
    header: DelayedMsgHeader;
    messageData: string;
}

export type DelayedMsgDelivered = {
    delayedMessage: DelayedMsg;
    delayedAcc: string;
    delayedCount: number;
}