// Copyright 2023-2025, Avail
// For license information, see https://github.com/availproject/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.4;
import "./IDABridge.sol";

//import "hardhat/console.sol";
contract AvailDABridge is IDABridge {
    struct BlobProof {
        bytes32 dataRoot;
        // blob root to check proof against, or reconstruct the data root
        bytes32 blobRoot;
        // bridge root to check proof against, or reconstruct the data root
        bytes32 bridgeRoot;
        // proof of inclusion of leaf within blob/bridge root
        bytes32[] leafProof;
        uint256 numberOfLeaves;
        // index of the leaf in the blob/bridge root tree
        uint256 leafIndex;
        // leaf being proven
        bytes32 leaf;
    }
    struct BlobPointer {
        uint8 version;
        uint32 blockHeight;
        uint32 extrinsicIndex;
        bytes32 dasTreeRootHash;
        bytes32 blobDataKeccak256H;
        BlobProof blobProof;
    }

    // struct MerkleProofInput {
    //     // proof of inclusion for the data root
    //     bytes32[] dataRootProof;
    //     // proof of inclusion of leaf within blob/bridge root
    //     bytes32[] leafProof;
    //     // abi.encodePacked(startBlock, endBlock) of header range commitment on vectorx
    //     bytes32 rangeHash;
    //     // index of the data root in the commitment tree
    //     uint256 dataRootIndex;
    //     // blob root to check proof against, or reconstruct the data root
    //     bytes32 blobRoot;
    //     // bridge root to check proof against, or reconstruct the data root
    //     bytes32 bridgeRoot;
    //     // leaf being proven
    //     bytes32 leaf;
    //     // index of the leaf in the blob/bridge root tree
    //     uint256 leafIndex;
    // }

    bytes1 public constant AVAIL_MESSAGE_HEADER_FLAG = 0x0a;

    // solhint-disable-next-line func-name-mixedcase
    function DA_MESSAGE_HEADER_FLAG() external pure returns (bytes1) {
        return AVAIL_MESSAGE_HEADER_FLAG;
    }

    function verifyBatchAttestation(bytes calldata data) external view returns (bool) {
        uint8 blobPointerVersion = abi.decode(data[1:], (uint8));
        if (blobPointerVersion == 2) {
            BlobPointer memory blobPointer;
            (
                blobPointer.version,
                blobPointer.blockHeight,
                blobPointer.extrinsicIndex,
                blobPointer.dasTreeRootHash,
                blobPointer.blobDataKeccak256H,
                blobPointer.blobProof
            ) = abi.decode(data[1:], (uint8, uint32, uint32, bytes32, bytes32, BlobProof));
            require(
                blobPointer.blobDataKeccak256H == blobPointer.blobProof.leaf,
                "Squencer batch data keccak256H preimage is not matching with the blobProof commitment"
            );
        }
        // console.logString("Avail header found");

        // For Phase 1 of Optimistic DA verification, the blobProof is not getting verified
        return false;

        // bytes32 leaf = keccak256(abi.encode(blobPointer.blobProof.leaf));

        // // console.logBytes32(blobPointer.blobProof.blobRoot);
        // // console.logBytes32(blobPointer.blobProof.leaf);
        // // for (uint256 i = 0; i < blobPointer.blobProof.leafProof.length; i++) {
        // //     console.logBytes32(blobPointer.blobProof.leafProof[i]);
        // // }
        // // console.logBytes32(leaf);

        // bool res = verifyMemory(
        //     blobPointer.blobProof.leafProof,
        //     blobPointer.blobProof.blobRoot,
        //     blobPointer.blobProof.leafIndex,
        //     blobPointer.blobProof.leaf
        // );

        //console.logBool(res);
        //return !res;

        // Not included this event as this function declared as view
        //emit validatedBatchAttestationOverDA(blobPointer.blobProof.leaf);
    }

    // function verifyMerkleProof(BlobProof memory proof) internal view returns (bool) {
    //     return true;
    // }

    function verifySha2Memory(
        bytes32[] memory proof,
        bytes32 root,
        uint256 index,
        bytes32 leaf
    ) internal view returns (bool isValid) {
        assembly {
            if mload(proof) {
                // initialize iterator to the offset of proof elements in memory
                let i := add(proof, 32)
                // left shift by 5 is equivalent to multiplying by 32
                let end := add(i, shl(5, mload(proof)))
                // prettier-ignore
                // solhint-disable-next-line no-empty-blocks
                for {} 1 {} {
                    // if index is odd, leaf slot is at 0x20, else 0x0
                    let leafSlot := shl(5, and(0x1, index))
                    // store the leaf at the calculated slot
                    mstore(leafSlot, leaf)
                    // store proof element in whichever slot is not occupied by the leaf
                    mstore(xor(leafSlot, 32), mload(i))
                    // hash the first 64 bytes in memory with sha2-256 and store in scratch space
                    if iszero(staticcall(gas(), 0x02, 0, 64, 0, 32)) { break }
                    // store for next iteration
                    leaf := mload(0)
                    // shift index right by 1 bit to divide by 2
                    index := shr(1, index)
                    // increment iterator by 32 bytes
                    i := add(i, 32)
                    // break if iterator is at the end of the proof array
                    if iszero(lt(i, end)) { break }
                }
            }
            // check if index is zeroed out (because tree is balanced) and leaf is equal to root
            isValid := and(eq(leaf, root), iszero(index))
        }
    }

    function verifyMemory(
        bytes32[] memory proof,
        bytes32 root,
        uint256 index,
        bytes32 leaf
    ) internal view returns (bool isValid) {
        assembly {
            if mload(proof) {
                // initialize iterator to the offset of proof elements in memory
                let i := add(proof, 32)
                // left shift by 5 is equivalent to multiplying by 32
                let end := add(i, shl(5, mload(proof)))
                // prettier-ignore
                // solhint-disable-next-line no-empty-blocks
                for {} 1 {} {
                    // if index is odd, leaf slot is at 0x20, else 0x0
                    let leafSlot := shl(5, and(0x1, index))
                    // store the leaf at the calculated slot
                    mstore(leafSlot, leaf)
                    // store proof element in whichever slot is not occupied by the leaf
                    mstore(xor(leafSlot, 32), mload(i))
                    
                    // hash the first 64 bytes in memory
                    leaf := keccak256(0, 64)
                    
                    // shift index right by 1 bit to divide by 2
                    index := shr(1, index)
                    // increment iterator by 32 bytes
                    i := add(i, 32)
                    // break if iterator is at the end of the proof array
                    if iszero(lt(i, end)) { break }
                }
            }
            // check if index is zeroed out (because tree is balanced) and leaf is equal to root
            isValid := and(eq(leaf, root), iszero(index))
        }
    }

    function verify(
        bytes32[] calldata proof,
        bytes32 root,
        uint256 index,
        bytes32 leaf
    ) internal pure returns (bool isValid) {
        assembly {
            if proof.length {
                // set end to be the end of the proof array, shl(5, proof.length) is equivalent to proof.length * 32
                let end := add(proof.offset, shl(5, proof.length))
                // set iterator to the start of the proof array
                let i := proof.offset
                // prettier-ignore
                // solhint-disable-next-line no-empty-blocks
                for {} 1 {} {
                    // if index is odd, leaf slot is at 0x20, else 0x0
                    let leafSlot := shl(5, and(0x1, index))
                    // store the leaf at the calculated slot
                    mstore(leafSlot, leaf)
                    // store proof element in whichever slot is not occupied by the leaf
                    mstore(xor(leafSlot, 32), calldataload(i))
                    // hash the first 64 bytes in memory
                    leaf := keccak256(0, 64)
                    // shift index right by 1 bit to divide by 2
                    index := shr(1, index)
                    // increment iterator by 32 bytes
                    i := add(i, 32)
                    // break if iterator is at the end of the proof array
                    if iszero(lt(i, end)) { break }
                }
            }
            // check if index is zeroed out (because tree is balanced) and leaf is equal to root
            isValid := and(eq(leaf, root), iszero(index))
        }
    }
}
