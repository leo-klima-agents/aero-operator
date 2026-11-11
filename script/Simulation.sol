// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";
import {Discovery} from "./Discovery.sol";

// Runs inside one eth_call on a live node, placed at an address by a state override: see script/simulate.sh.
contract Simulation {
    struct Deployment {
        address leafVoter;
        address escrow;
        uint256 baseChainId;
        address feeRecipient;
    }

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
        Discovery.Claims memory claims = Discovery.claims(dep.leafVoter, tokenId, limit, false);
        tokens = claims.tokens;
        entries = claims.fees.length + claims.incentives.length;
        uint256[] memory before = Discovery.balances(tokens, recipient);
        uint256[] memory feesBefore = Discovery.balances(tokens, dep.feeRecipient);

        gas = gasleft();
        factory.claim(recipient, tokenId, claims.fees, claims.incentives, entryGas);
        gas -= gasleft();

        paid = Discovery.gained(tokens, recipient, before);
        uint256[] memory fees = Discovery.gained(tokens, dep.feeRecipient, feesBefore);
        address[3] memory ours = [factory.operatorOf(recipient), address(factory), factory.implementation()];
        uint256 total;
        for (uint256 i; i < tokens.length; ++i) {
            if (
                paid[i] + fees[i] != expected[i] || fees[i] > expected[i] / 100
                    || fees[i] + 2 * entries < expected[i] / 100
            ) revert Mismatch(tokens[i], expected[i], paid[i], fees[i]);
            for (uint256 j; j < ours.length; ++j) {
                uint256 left = Discovery.balance(tokens[i], ours[j]);
                if (left != 0) revert LeftBehind(tokens[i], ours[j], left);
            }
            total += expected[i];
        }
        if (total == 0) revert NothingClaimed();
    }

    function _factory(Deployment calldata dep) private returns (ImmutableClaimOperatorFactory) {
        return new ImmutableClaimOperatorFactory(dep.leafVoter, dep.escrow, dep.baseChainId, dep.feeRecipient);
    }
}
