// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "../src/interfaces/IERC20.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";
import {IVotingRewardsManager} from "../src/interfaces/IVotingRewardsManager.sol";

interface ILeafVoterViews {
    function allocatedGauges(uint256 tokenId) external view returns (address[] memory);
}

interface IFactoryRegistryViews {
    function gaugeToRewards(address gauge) external view returns (address);
}

interface IVotingRewardsManagerViews {
    function incentiveCount() external view returns (uint256);
    function earnedIncentives(uint256 tokenId, uint256 programId, uint256 maxCheckpoints)
        external
        view
        returns (uint256);
}

library Discovery {
    uint256 internal constant MAX_CHECKPOINTS = 500;
    uint256 internal constant MAX_PROGRAMS = 64;
    address internal constant NATIVE = address(0);

    struct Claims {
        ILeafVoter.FeeClaim[] fees;
        ILeafVoter.IncentiveClaim[] incentives;
        address[] tokens;
        address wrappedNative;
        uint256 unreadPrograms;
        uint256 leftOut;
    }

    function claims(address leafVoter, uint256 tokenId, uint256 maxGauges, bool onlyWhatAForkRuns)
        internal
        view
        returns (Claims memory found)
    {
        address registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        address[] memory gauges = ILeafVoterViews(leafVoter).allocatedGauges(tokenId);
        uint256 n = maxGauges != 0 && maxGauges < gauges.length ? maxGauges : gauges.length;
        ILeafVoter.FeeClaim[] memory fees = new ILeafVoter.FeeClaim[](n);
        ILeafVoter.IncentiveClaim[] memory incentives = new ILeafVoter.IncentiveClaim[](MAX_PROGRAMS * n);
        address[] memory tokens = new address[]((MAX_PROGRAMS + 2) * n + 2);
        uint256 managers;
        uint256 programs;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            IVotingRewardsManager manager =
                IVotingRewardsManager(IFactoryRegistryViews(registry).gaugeToRewards(gauges[i]));
            (address token0, address token1) = (manager.token0(), manager.token1());
            if (onlyWhatAForkRuns && !(_runsInAFork(token0) && _runsInAFork(token1))) {
                ++found.leftOut;
                continue;
            }
            address native = manager.wrappedNative();
            if (managers == 0) found.wrappedNative = native;
            require(native == found.wrappedNative, "rewards managers differ on the wrapped native token");
            fees[managers++] = ILeafVoter.FeeClaim(address(manager), MAX_CHECKPOINTS);
            count = _track(tokens, count, token0, native);
            count = _track(tokens, count, token1, native);

            IVotingRewardsManagerViews views = IVotingRewardsManagerViews(address(manager));
            uint256 last = views.incentiveCount();
            if (last > MAX_PROGRAMS) found.unreadPrograms += last - MAX_PROGRAMS;
            for (uint256 id = last > MAX_PROGRAMS ? last - MAX_PROGRAMS + 1 : 1; id <= last; ++id) {
                try views.earnedIncentives(tokenId, id, MAX_CHECKPOINTS) returns (uint256 earned) {
                    if (earned == 0) continue;
                } catch {
                    ++found.unreadPrograms;
                    continue;
                }
                address token = manager.incentive(id);
                if (onlyWhatAForkRuns && !_runsInAFork(token)) {
                    ++found.leftOut;
                    continue;
                }
                incentives[programs++] = ILeafVoter.IncentiveClaim(address(manager), id, MAX_CHECKPOINTS);
                count = _track(tokens, count, token, native);
            }
        }
        if (found.wrappedNative != address(0)) {
            tokens[count++] = NATIVE;
            tokens[count++] = found.wrappedNative;
        }
        assembly ("memory-safe") {
            mstore(fees, managers)
            mstore(incentives, programs)
            mstore(tokens, count)
        }
        found.fees = fees;
        found.incentives = incentives;
        found.tokens = tokens;
    }

    function balance(address token, address account) internal view returns (uint256) {
        return token == NATIVE ? account.balance : IERC20(token).balanceOf(account);
    }

    function balances(address[] memory tokens, address account) internal view returns (uint256[] memory held) {
        held = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            held[i] = balance(tokens[i], account);
        }
    }

    function gained(address[] memory tokens, address account, uint256[] memory before)
        internal
        view
        returns (uint256[] memory gains)
    {
        gains = balances(tokens, account);
        for (uint256 i; i < gains.length; ++i) {
            gains[i] -= before[i];
        }
    }

    function _runsInAFork(address token) private view returns (bool) {
        return keccak256(token.code) != keccak256(hex"ef");
    }

    function _track(address[] memory tokens, uint256 count, address token, address native)
        private
        pure
        returns (uint256)
    {
        if (token == native) return count;
        for (uint256 i; i < count; ++i) {
            if (tokens[i] == token) return count;
        }
        tokens[count] = token;
        return count + 1;
    }
}
