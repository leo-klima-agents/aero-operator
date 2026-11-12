// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";
import {Discovery} from "./Discovery.sol";

contract Simulation {
    enum Outcome {
        Reverted,
        PaidInFull,
        PaidInPart,
        PaidNothing
    }

    struct Deployment {
        address leafVoter;
        address escrow;
        uint256 baseChainId;
        address feeRecipient;
    }

    error LeftBehind(address token, address account, uint256 amount);

    function operatorOf(Deployment calldata dep, address recipient) external returns (address) {
        return _factory(dep).operatorOf(recipient);
    }

    function claimAsOperator(address leafVoter, uint256 tokenId, address recipient, uint256 maxGauges)
        external
        returns (uint256[] memory)
    {
        Discovery.Claims memory claims = Discovery.claims(leafVoter, tokenId, maxGauges, false);
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        ILeafVoter(leafVoter).claimRewards(tokenId, recipient, claims.fees, claims.incentives);
        return Discovery.gained(claims.tokens, recipient, before);
    }

    function claimThroughClone(
        Deployment calldata dep,
        uint256 tokenId,
        address recipient,
        uint256 maxGauges,
        uint256 entryGas,
        uint256 entriesPerCall,
        uint256 gasPerCall,
        uint256[] calldata paidByAero
    ) external returns (Outcome outcome, uint256 entries, uint256 calls, uint256 mostGas, uint256 unreadPrograms) {
        ImmutableClaimOperatorFactory factory = _factory(dep);
        Discovery.Claims memory claims = Discovery.claims(dep.leafVoter, tokenId, maxGauges, false);
        entries = claims.fees.length + claims.incentives.length;
        unreadPrograms = claims.unreadPrograms;
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        uint256[] memory feesBefore = Discovery.balances(claims.tokens, dep.feeRecipient);

        for (uint256 from; from < entries; from += entriesPerCall) {
            (ILeafVoter.FeeClaim[] memory fees, ILeafVoter.IncentiveClaim[] memory incentives) =
                _feesThenIncentives(claims, from, entriesPerCall);
            uint256 used = gasleft();
            try factory.claim{gas: gasPerCall}(recipient, tokenId, fees, incentives, entryGas) {}
            catch {
                return (Outcome.Reverted, entries, calls, mostGas, unreadPrograms);
            }
            used -= gasleft();
            if (used > mostGas) mostGas = used;
            ++calls;
        }

        uint256[] memory paid = Discovery.gained(claims.tokens, recipient, before);
        uint256[] memory taken = Discovery.gained(claims.tokens, dep.feeRecipient, feesBefore);
        address[3] memory ours = [factory.operatorOf(recipient), address(factory), factory.implementation()];
        bool inFull = true;
        bool nothing = true;
        uint256 maxRounding = 2 * entries;
        for (uint256 i; i < paidByAero.length; ++i) {
            uint256 onePercent = paidByAero[i] / 100;
            bool feeIsOnePercentRoundedDown = taken[i] <= onePercent && taken[i] + maxRounding >= onePercent;
            if (paid[i] + taken[i] != paidByAero[i] || !feeIsOnePercentRoundedDown) inFull = false;
            if (paid[i] + taken[i] != 0) nothing = false;
            for (uint256 j; j < ours.length; ++j) {
                uint256 left = Discovery.balance(claims.tokens[i], ours[j]);
                if (left != 0) revert LeftBehind(claims.tokens[i], ours[j], left);
            }
        }
        outcome = nothing ? Outcome.PaidNothing : inFull ? Outcome.PaidInFull : Outcome.PaidInPart;
    }

    function _factory(Deployment calldata dep) private returns (ImmutableClaimOperatorFactory) {
        return new ImmutableClaimOperatorFactory(dep.leafVoter, dep.escrow, dep.baseChainId, dep.feeRecipient);
    }

    function _feesThenIncentives(Discovery.Claims memory claims, uint256 from, uint256 count)
        private
        pure
        returns (ILeafVoter.FeeClaim[] memory fees, ILeafVoter.IncentiveClaim[] memory incentives)
    {
        uint256 feeCount = claims.fees.length;
        uint256 to = from + count;
        if (to > feeCount + claims.incentives.length) to = feeCount + claims.incentives.length;
        uint256 feeEnd = to < feeCount ? to : feeCount;
        fees = new ILeafVoter.FeeClaim[](from < feeEnd ? feeEnd - from : 0);
        for (uint256 i; i < fees.length; ++i) {
            fees[i] = claims.fees[from + i];
        }
        uint256 start = from > feeCount ? from - feeCount : 0;
        incentives = new ILeafVoter.IncentiveClaim[](to > feeCount ? to - feeCount - start : 0);
        for (uint256 i; i < incentives.length; ++i) {
            incentives[i] = claims.incentives[start + i];
        }
    }
}
