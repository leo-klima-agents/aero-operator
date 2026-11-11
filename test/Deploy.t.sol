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
        vm.etch(d.LEAF_VOTER(), hex"00");
        vm.etch(d.FEE_RECIPIENT(), hex"00");
    }

    function test_canonicalValues() public view {
        assertEq(d.LEAF_VOTER(), 0x382409fad8503FbCdbB27A4211551fa03e884078);
        assertEq(d.ESCROW(), 0xBF7977E1521e9a3032bf7243Ee4712f311f13915);
        assertEq(d.BASE_CHAIN_ID(), 8453);
        assertEq(d.FEE_RECIPIENT(), 0x450c72de8c0079B49AcedF294a13011bd09D125B);
        assertEq(d.SALT(), keccak256("metadex.cafe/ImmutableClaimOperatorFactory/v1"));
        assertEq(CREATE2_FACTORY, 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }

    function test_recordMatchesScript() public {
        string memory json = vm.readFile("verification/bytecode-hashes.json");
        assertEq(vm.parseJsonAddress(json, ".create2Deployer"), CREATE2_FACTORY);
        assertEq(vm.parseJsonString(json, ".saltPreimage"), d.SALT_PREIMAGE());
        assertEq(vm.parseJsonBytes32(json, ".salt"), d.SALT());
        assertEq(
            vm.parseJsonBytes32(json, ".factoryCreationCodeKeccak"),
            keccak256(type(ImmutableClaimOperatorFactory).creationCode)
        );
        assertEq(
            vm.parseJsonBytes32(json, ".implementationCreationCodeKeccak"),
            keccak256(type(ImmutableClaimOperator).creationCode)
        );
        assertEq(vm.parseJsonAddress(json, ".deployment.leafVoter"), d.LEAF_VOTER());
        assertEq(vm.parseJsonAddress(json, ".deployment.escrow"), d.ESCROW());
        assertEq(vm.parseJsonUint(json, ".deployment.baseChainId"), d.BASE_CHAIN_ID());
        assertEq(vm.parseJsonAddress(json, ".deployment.feeRecipient"), d.FEE_RECIPIENT());
        assertEq(vm.parseJsonBytes(json, ".deployment.constructorArgs"), d.constructorArgs());
        assertEq(vm.parseJsonAddress(json, ".deployment.factory"), d.predict());
        assertEq(vm.parseJsonAddress(json, ".deployment.implementation"), d.predictImplementation());

        ImmutableClaimOperatorFactory factory = ImmutableClaimOperatorFactory(d.run());
        assertEq(vm.parseJsonBytes32(json, ".deployment.factoryRuntimeKeccak"), address(factory).codehash);
        assertEq(
            vm.parseJsonBytes32(json, ".deployment.implementationRuntimeKeccak"), factory.implementation().codehash
        );
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

    function test_run_failsWithoutTheLeafVoter() public {
        vm.etch(d.LEAF_VOTER(), "");
        vm.expectRevert(bytes("LeafVoter not present"));
        d.run();
    }

    function test_run_failsWithoutTheFeeRecipient() public {
        vm.etch(d.FEE_RECIPIENT(), "");
        vm.expectRevert(bytes("fee recipient not present"));
        d.run();
    }

    function test_run_onBase_failsWithoutTheEscrow() public {
        vm.chainId(8453);
        vm.expectRevert(bytes("escrow not present"));
        d.run();

        vm.etch(d.ESCROW(), hex"00");
        assertEq(d.run(), d.predict());
    }
}
