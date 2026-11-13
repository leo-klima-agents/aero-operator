// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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

    struct Prepared {
        Discovery.Claims claims;
        address feeRecipient;
        address clone;
        address factory;
        address implementation;
        uint256[] held;
        uint256[] feesHeld;
    }

    error LeftBehind(address token, address account, uint256 amount);

    function build(address create2Deployer, bytes calldata saltAndInitCode)
        external
        returns (address factory, bytes memory factoryCode, address implementation, bytes memory implementationCode)
    {
        (bool ok, bytes memory deployed) = create2Deployer.call(saltAndInitCode);
        require(ok && deployed.length == 20, "CREATE2 deploy failed");
        factory = address(bytes20(deployed));
        implementation = ImmutableClaimOperatorFactory(factory).implementation();
        return (factory, factory.code, implementation, implementation.code);
    }

    function gasLeft() external view returns (uint256) {
        return gasleft();
    }

    function passesOnAllButOne64thOfItsGas() external view returns (bool) {
        uint256 held = gasleft();
        uint256 passedOn = this.gasLeft();
        uint256 allButOne64th = held - held / 64;
        uint256 asked = this.gasLeft{gas: 100_000}();
        return passedOn <= allButOne64th && passedOn + 5_000 > allButOne64th && asked <= 100_000 && asked > 99_000;
    }

    function claimAsOperator(address leafVoter, uint256 tokenId, address recipient, uint256 maxGauges, bool feesOnly)
        external
        returns (uint256[] memory)
    {
        Discovery.Claims memory claims = _claims(leafVoter, tokenId, maxGauges, feesOnly);
        uint256[] memory before = Discovery.balances(claims.tokens, recipient);
        ILeafVoter(leafVoter).claimRewards(tokenId, recipient, claims.fees, claims.incentives);
        return Discovery.gained(claims.tokens, recipient, before);
    }

    function prepare(
        ImmutableClaimOperatorFactory factory,
        address leafVoter,
        address feeRecipient,
        uint256 tokenId,
        address recipient,
        uint256 maxGauges,
        bool feesOnly
    ) external view returns (bytes memory) {
        Prepared memory p;
        p.claims = _claims(leafVoter, tokenId, maxGauges, feesOnly);
        p.feeRecipient = feeRecipient;
        p.clone = factory.operatorOf(recipient);
        p.factory = address(factory);
        p.implementation = factory.implementation();
        p.held = Discovery.balances(p.claims.tokens, recipient);
        p.feesHeld = Discovery.balances(p.claims.tokens, feeRecipient);
        return abi.encode(p);
    }

    function claimThroughClone(
        uint256 tokenId,
        address recipient,
        uint256 entryGas,
        uint256 entriesPerCall,
        uint256 gasPerCall,
        uint256[] calldata paidByAero,
        bytes calldata prepared
    ) external returns (Outcome outcome, uint256 entries, uint256 calls, uint256 mostGas, uint256 unreadPrograms) {
        Prepared memory p = abi.decode(prepared, (Prepared));
        entries = p.claims.fees.length + p.claims.incentives.length;
        unreadPrograms = p.claims.unreadPrograms;

        for (uint256 from; from < entries; from += entriesPerCall) {
            (ILeafVoter.FeeClaim[] memory fees, ILeafVoter.IncentiveClaim[] memory incentives) =
                _feesThenIncentives(p.claims, from, entriesPerCall);
            uint256 used = gasleft();
            try ImmutableClaimOperatorFactory(p.factory).claim{gas: gasPerCall}(
                recipient, tokenId, fees, incentives, entryGas
            ) {}
            catch {
                return (Outcome.Reverted, entries, calls, mostGas, unreadPrograms);
            }
            used -= gasleft();
            if (used > mostGas) mostGas = used;
            ++calls;
        }

        uint256[] memory paid = Discovery.gained(p.claims.tokens, recipient, p.held);
        uint256[] memory taken = Discovery.gained(p.claims.tokens, p.feeRecipient, p.feesHeld);
        address[3] memory ours = [p.clone, p.factory, p.implementation];
        bool inFull = true;
        bool nothing = true;
        uint256 maxRounding = 2 * entries;
        for (uint256 i; i < paidByAero.length; ++i) {
            uint256 onePercent = paidByAero[i] / 100;
            bool feeIsOnePercentRoundedDown = taken[i] <= onePercent && taken[i] + maxRounding >= onePercent;
            if (paid[i] + taken[i] != paidByAero[i] || !feeIsOnePercentRoundedDown) inFull = false;
            if (paid[i] + taken[i] != 0) nothing = false;
            for (uint256 j; j < ours.length; ++j) {
                uint256 left = Discovery.balance(p.claims.tokens[i], ours[j]);
                if (left != 0) revert LeftBehind(p.claims.tokens[i], ours[j], left);
            }
        }
        outcome = nothing ? Outcome.PaidNothing : inFull ? Outcome.PaidInFull : Outcome.PaidInPart;
    }

    function _claims(address leafVoter, uint256 tokenId, uint256 maxGauges, bool feesOnly)
        private
        view
        returns (Discovery.Claims memory claims)
    {
        claims = Discovery.claims(leafVoter, tokenId, maxGauges, false);
        if (feesOnly) claims.incentives = new ILeafVoter.IncentiveClaim[](0);
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
