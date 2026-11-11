// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IVotingEscrow {
    function ownerOf(uint256 tokenId) external view returns (address);
}
