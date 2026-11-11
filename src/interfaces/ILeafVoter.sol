// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface ILeafVoter {
    struct FeeClaim {
        address votingRewardsManager;
        uint256 maxCheckpoints;
    }

    struct IncentiveClaim {
        address votingRewardsManager;
        uint256 programId;
        uint256 maxCheckpoints;
    }

    function FACTORY_REGISTRY() external view returns (address);
    function claimRewards(
        uint256 tokenId,
        address recipient,
        FeeClaim[] calldata feeClaims,
        IncentiveClaim[] calldata incentiveClaims
    ) external;
}
