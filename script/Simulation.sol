// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";
import {Discovery} from "./Discovery.sol";

// Runs inside one eth_call on a live node, placed at an address by a state override: see script/simulate.sh.
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

    // What Base and Ethereum allow a transaction.
    uint256 internal constant TRANSACTION_GAS = 16_777_216;

    error Mismatch(address token, uint256 direct, uint256 recipient, uint256 fee);
    error LeftBehind(address token, address account, uint256 amount);
    error NothingClaimed();

    // The recipient's clone, for the factory this contract deploys first in a call.
    function operatorOf(Deployment calldata dep, address recipient) external returns (address) {
        return _factory(dep).operatorOf(recipient);
    }

    // What Aero's own route pays the recipient, with this contract as the stake's operator.
    function direct(address leafVoter, uint256 tokenId, address recipient, uint256 limit)
        external
        returns (uint256[] memory)
    {
        Discovery.Claims memory claims = Discovery.claims(leafVoter, tokenId, limit, false);
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        ILeafVoter(leafVoter).claimRewards(tokenId, recipient, claims.fees, claims.incentives);
        return Discovery.gained(claims.tokens, recipient, before);
    }

    // The same claim through the recipient's clone, as the stake's operator, in calls of `chunk` entries that each
    // get a transaction's gas, checked against `direct`. `gas` is what the heaviest call used.
    function claim(
        Deployment calldata dep,
        uint256 tokenId,
        address recipient,
        uint256 limit,
        uint256 entryGas,
        uint256 chunk,
        uint256[] calldata expected
    ) external returns (uint256 entries, uint256 calls, uint256 gas, uint256 unread, uint256[] memory paid) {
        ImmutableClaimOperatorFactory factory = _factory(dep);
        Discovery.Claims memory claims = Discovery.claims(dep.leafVoter, tokenId, limit, false);
        entries = claims.fees.length + claims.incentives.length;
        unread = claims.unread;
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        uint256[] memory feesBefore = Discovery.balances(claims.tokens, dep.feeRecipient);

        for (uint256 from; from < entries; from += chunk) {
            (ILeafVoter.FeeClaim[] memory fees, ILeafVoter.IncentiveClaim[] memory incentives) =
                _slice(claims, from, chunk);
            uint256 used = gasleft();
            factory.claim{gas: TRANSACTION_GAS}(recipient, tokenId, fees, incentives, entryGas);
            used -= gasleft();
            if (used > gas) gas = used;
            ++calls;
        }

        paid = Discovery.gained(claims.tokens, recipient, before);
        uint256[] memory taken = Discovery.gained(claims.tokens, dep.feeRecipient, feesBefore);
        _checkNothingLeft(factory, recipient, claims.tokens);
        uint256 total;
        for (uint256 i; i < expected.length; ++i) {
            if (!_inFull(expected[i], paid[i], taken[i], entries)) {
                revert Mismatch(claims.tokens[i], expected[i], paid[i], taken[i]);
            }
            total += expected[i];
        }
        if (total == 0) revert NothingClaimed();
    }

    // One claim through the clone with `gas`, to see how this node's gas rules treat it.
    function attempt(
        Deployment calldata dep,
        uint256 tokenId,
        address recipient,
        uint256 limit,
        uint256 entryGas,
        uint256 gas,
        uint256[] calldata expected
    ) external returns (Outcome) {
        ImmutableClaimOperatorFactory factory = _factory(dep);
        Discovery.Claims memory claims = Discovery.claims(dep.leafVoter, tokenId, limit, false);
        uint256 entries = claims.fees.length + claims.incentives.length;
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        uint256[] memory feesBefore = Discovery.balances(claims.tokens, dep.feeRecipient);

        try factory.claim{gas: gas}(recipient, tokenId, claims.fees, claims.incentives, entryGas) {}
        catch {
            return Outcome.Reverted;
        }

        uint256[] memory paid = Discovery.gained(claims.tokens, recipient, before);
        uint256[] memory taken = Discovery.gained(claims.tokens, dep.feeRecipient, feesBefore);
        _checkNothingLeft(factory, recipient, claims.tokens);
        bool inFull = true;
        bool nothing = true;
        for (uint256 i; i < expected.length; ++i) {
            if (!_inFull(expected[i], paid[i], taken[i], entries)) inFull = false;
            if (paid[i] + taken[i] != 0) nothing = false;
        }
        return nothing ? Outcome.PaidNothing : inFull ? Outcome.PaidInFull : Outcome.PaidInPart;
    }

    function _factory(Deployment calldata dep) private returns (ImmutableClaimOperatorFactory) {
        return new ImmutableClaimOperatorFactory(dep.leafVoter, dep.escrow, dep.baseChainId, dep.feeRecipient);
    }

    // Entries `from` to `from + chunk` of the claims, counting the fees first.
    function _slice(Discovery.Claims memory claims, uint256 from, uint256 chunk)
        private
        pure
        returns (ILeafVoter.FeeClaim[] memory fees, ILeafVoter.IncentiveClaim[] memory incentives)
    {
        uint256 feeCount = claims.fees.length;
        uint256 to = from + chunk;
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

    // The recipient and the fee recipient share what Aero's own route pays, the fee being 1% of each payment,
    // rounded down.
    function _inFull(uint256 expected, uint256 paid, uint256 taken, uint256 entries) private pure returns (bool) {
        return paid + taken == expected && taken <= expected / 100 && taken + 2 * entries >= expected / 100;
    }

    function _checkNothingLeft(ImmutableClaimOperatorFactory factory, address recipient, address[] memory tokens)
        private
        view
    {
        address[3] memory ours = [factory.operatorOf(recipient), address(factory), factory.implementation()];
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < ours.length; ++j) {
                uint256 left = Discovery.balance(tokens[i], ours[j]);
                if (left != 0) revert LeftBehind(tokens[i], ours[j], left);
            }
        }
    }
}
