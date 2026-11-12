// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {ImmutableClaimOperator} from "../src/ImmutableClaimOperator.sol";
import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";

contract DeployTest is Test {
    Deploy internal d;

    function setUp() public {
        d = new Deploy();
        vm.etch(d.FEE_RECIPIENT(), hex"00");
    }

    function test_run_deploysAtThePredictedAddresses_onAnyChain() public {
        uint256[3] memory chains = [uint256(10), 1, 42161];
        address predicted = d.predict();
        for (uint256 i; i < chains.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            vm.chainId(chains[i]);
            assertEq(predicted.code.length, 0);

            assertEq(d.run(), predicted);

            ImmutableClaimOperatorFactory factory = ImmutableClaimOperatorFactory(predicted);
            ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));
            assertEq(address(implementation), d.predictImplementation());
            assertEq(implementation.leafVoter(), d.LEAF_VOTER());
            assertEq(implementation.escrow(), d.ESCROW());
            assertEq(implementation.baseChainId(), d.BASE_CHAIN_ID());
            assertEq(implementation.feeRecipient(), d.FEE_RECIPIENT());
            vm.revertToState(snapshot);
        }
    }

    function test_run_isIdempotent() public {
        address first = d.run();
        bytes32 codehash = first.codehash;

        assertEq(d.run(), first);
        assertEq(first.codehash, codehash);
    }

    function test_run_failsWithoutTheDeployer() public {
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert(bytes("CREATE2 deployer not present"));
        d.run();
    }

    function test_run_failsWithoutTheFeeRecipient() public {
        vm.etch(d.FEE_RECIPIENT(), "");
        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NoCode.selector, d.FEE_RECIPIENT()));
        d.run();
    }
}
