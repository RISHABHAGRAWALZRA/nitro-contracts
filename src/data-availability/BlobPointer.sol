pragma solidity ^0.8.0;

import "./BlobProof.sol";
struct BlobPointer {
    uint32 blockHeight;
    uint32 extrinsicIndex;
    bytes32 dasTreeRootHash;
    BlobProof blobProof;
}
