// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IVotingRewardsManager {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function wrappedNative() external view returns (address);
    function incentive(uint256 programId) external view returns (address token);
}
