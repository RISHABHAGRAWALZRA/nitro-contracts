// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @author  @rishabhagrawalzra (Avail)
 * @title   DABridge
 * @notice  An DA on-chain data attestation verification interface
 * @custom:security security@availproject.org
 */
interface IDABridge {
    /// @dev If the first data byte after the header has this bit set,
    ///      then the batch data is a DA blobpointer message
    // solhint-disable-next-line func-name-mixedcase
    function DA_MESSAGE_HEADER_FLAG() external view returns (bytes1);

    /**
     * @notice  Takes a Merkle tree proof of inclusion for a blob leaf and verifies it
     * @dev     This function is used for data attestation on Ethereum
     * @param   data  Merkle tree proof of inclusion for the blob leaf
     * @return  bool  Returns true if the blob leaf is valid, else false
     */
    function verifyBatchAttestation(bytes calldata data) external returns (bool);

    event ValidatedBatchAttestationOverDA(bytes32 indexed blobHash);
}
