// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

interface IFactoryRegistry {
    function rewardsToGauge(address rewards) external view returns (address gauge);
}
