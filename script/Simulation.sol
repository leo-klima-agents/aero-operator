// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
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

// Runs inside one eth_call on a live node, placed at an address by a state override: see script/simulate.sh.
contract Simulation {
    uint256 internal constant MAX_CHECKPOINTS = 500;

    struct Deployment {
        address leafVoter;
        address escrow;
        uint256 baseChainId;
        address feeRecipient;
    }

    struct Claims {
        ILeafVoter.FeeClaim[] fees;
        ILeafVoter.IncentiveClaim[] incentives;
        address[] tokens;
    }

    error Mismatch(address token, uint256 direct, uint256 recipient, uint256 fee);
    error LeftBehind(address token, address account, uint256 amount);
    error NothingClaimed();

    receive() external payable {}

    // The recipient's clone, for the factory this contract deploys first in every call.
    function operatorOf(Deployment calldata dep, address recipient) external returns (address) {
        return _factory(dep).operatorOf(recipient);
    }

    // What Aero's own route pays the recipient, with this contract as the stake's operator.
    function direct(Deployment calldata dep, uint256 tokenId, address recipient, uint256 limit)
        external
        returns (uint256[] memory gained)
    {
        _factory(dep);
        Claims memory claims = _claims(dep.leafVoter, tokenId, limit);
        uint256[] memory before = _balances(claims.tokens, recipient);
        ILeafVoter(dep.leafVoter).claimRewards(tokenId, recipient, claims.fees, claims.incentives);
        return _gained(claims.tokens, recipient, before);
    }

    // The same claim through the recipient's clone, as the stake's operator, checked against `direct`.
    function claim(
        Deployment calldata dep,
        uint256 tokenId,
        address recipient,
        uint256 limit,
        uint256 entryGas,
        uint256[] calldata expected
    ) external returns (uint256 entries, uint256 gas, address[] memory tokens, uint256[] memory paid) {
        ImmutableClaimOperatorFactory factory = _factory(dep);
        Claims memory claims = _claims(dep.leafVoter, tokenId, limit);
        tokens = claims.tokens;
        entries = claims.fees.length + claims.incentives.length;
        uint256[] memory before = _balances(tokens, recipient);
        uint256[] memory feesBefore = _balances(tokens, dep.feeRecipient);

        gas = gasleft();
        factory.claim(recipient, tokenId, claims.fees, claims.incentives, entryGas);
        gas -= gasleft();

        paid = _gained(tokens, recipient, before);
        uint256[] memory fees = _gained(tokens, dep.feeRecipient, feesBefore);
        address[3] memory ours = [factory.operatorOf(recipient), address(factory), factory.implementation()];
        uint256 total;
        for (uint256 i; i < tokens.length; ++i) {
            if (
                paid[i] + fees[i] != expected[i] || fees[i] > expected[i] / 100
                    || fees[i] + 2 * entries < expected[i] / 100
            ) revert Mismatch(tokens[i], expected[i], paid[i], fees[i]);
            for (uint256 j; j < ours.length; ++j) {
                uint256 left = _balance(tokens[i], ours[j]);
                if (left != 0) revert LeftBehind(tokens[i], ours[j], left);
            }
            total += expected[i];
        }
        if (total == 0) revert NothingClaimed();
    }

    function _factory(Deployment calldata dep) private returns (ImmutableClaimOperatorFactory) {
        return new ImmutableClaimOperatorFactory(dep.leafVoter, dep.escrow, dep.baseChainId, dep.feeRecipient);
    }

    // Every gauge the stake is allocated to, up to `limit` if it is not 0: its fees, and the programs that owe it.
    // Where rewards managers pay native tokens, the last token is the zero address, for those.
    function _claims(address leafVoter, uint256 tokenId, uint256 limit) private view returns (Claims memory claims) {
        address registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        address[] memory gauges = ILeafVoterViews(leafVoter).allocatedGauges(tokenId);
        uint256 n = limit != 0 && limit < gauges.length ? limit : gauges.length;
        claims.fees = new ILeafVoter.FeeClaim[](n);
        ILeafVoter.IncentiveClaim[] memory incentives = new ILeafVoter.IncentiveClaim[](64 * n);
        address[] memory tokens = new address[](66 * n + 1);
        uint256 programs;
        uint256 count;
        bool paysNative;
        for (uint256 i; i < n; ++i) {
            address manager = IFactoryRegistryViews(registry).gaugeToRewards(gauges[i]);
            address native = IVotingRewardsManager(manager).wrappedNative();
            if (native != address(0)) paysNative = true;
            claims.fees[i] = ILeafVoter.FeeClaim(manager, MAX_CHECKPOINTS);
            count = _track(tokens, count, IVotingRewardsManager(manager).token0(), native);
            count = _track(tokens, count, IVotingRewardsManager(manager).token1(), native);
            uint256 last = IVotingRewardsManagerViews(manager).incentiveCount();
            for (uint256 id = last > 64 ? last - 63 : 1; id <= last; ++id) {
                if (IVotingRewardsManagerViews(manager).earnedIncentives(tokenId, id, MAX_CHECKPOINTS) == 0) continue;
                incentives[programs++] = ILeafVoter.IncentiveClaim(manager, id, MAX_CHECKPOINTS);
                (address token,,,,,) = IVotingRewardsManager(manager).incentive(id);
                count = _track(tokens, count, token, native);
            }
        }
        if (paysNative) ++count;
        assembly ("memory-safe") {
            mstore(incentives, programs)
            mstore(tokens, count)
        }
        claims.incentives = incentives;
        claims.tokens = tokens;
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

    function _balance(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _balances(address[] memory tokens, address account) private view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = _balance(tokens[i], account);
        }
    }

    function _gained(address[] memory tokens, address account, uint256[] memory before)
        private
        view
        returns (uint256[] memory gained)
    {
        gained = _balances(tokens, account);
        for (uint256 i; i < gained.length; ++i) {
            gained[i] -= before[i];
        }
    }
}
