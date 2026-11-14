// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {ImmutableClaimOperator} from "../src/ImmutableClaimOperator.sol";
import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";

contract DeployTest is Test {
    Deploy internal d;
    string internal record;

    function setUp() public {
        d = new Deploy();
        record = vm.readFile("verification/bytecode-hashes.json");
        vm.etch(d.TREASURY(), hex"00");
    }

    function test_run_deploysTheRecordedCodeAtThePredictedAddresses() public {
        address predicted = d.predict();
        assertEq(predicted.code.length, 0);

        assertEq(d.run(), predicted);

        ImmutableClaimOperatorFactory factory = ImmutableClaimOperatorFactory(predicted);
        ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));
        assertEq(address(implementation), d.predictImplementation());
        assertEq(address(factory).codehash, vm.parseJsonBytes32(record, ".deployment.factoryRuntimeKeccak"));
        assertEq(
            address(implementation).codehash, vm.parseJsonBytes32(record, ".deployment.implementationRuntimeKeccak")
        );
        assertEq(implementation.leafVoter(), d.LEAF_VOTER());
        assertEq(implementation.escrow(), d.ESCROW());
        assertEq(implementation.baseChainId(), d.BASE_CHAIN_ID());
        assertEq(implementation.TREASURY(), d.TREASURY());
    }

    function test_run_deploysToAddressesThatHoldNativeTokens() public {
        vm.deal(d.predict(), 1);
        vm.deal(d.predictImplementation(), 1);

        assertEq(d.run(), d.predict());
    }

    function test_run_isIdempotent() public {
        address first = d.run();
        bytes32 codehash = first.codehash;

        assertEq(d.run(), first);
        assertEq(first.codehash, codehash);
    }

    function test_deploy_refusesABuildThatDiffersFromTheRecord() public {
        string memory another = vm.replace(record, vm.toString(d.predict()), vm.toString(address(1)));

        vm.expectRevert(bytes("build differs from the record"));
        d.deploy(another);
    }

    function test_deploy_refusesCodeThatDiffersFromTheRecord() public {
        string[2] memory keys = [".deployment.factoryRuntimeKeccak", ".deployment.implementationRuntimeKeccak"];
        for (uint256 i; i < keys.length; ++i) {
            string memory recorded = vm.toString(vm.parseJsonBytes32(record, keys[i]));
            string memory another = vm.replace(record, recorded, vm.toString(bytes32(uint256(1))));
            uint256 snapshot = vm.snapshotState();

            vm.expectRevert(bytes("deployed code differs from the record"));
            d.deploy(another);
            vm.revertToState(snapshot);
        }
    }

    function test_run_refusesOtherCodeAtTheAddress() public {
        vm.etch(d.predict(), hex"00");

        vm.expectRevert(bytes("deployed code differs from the record"));
        d.run();
    }

    function test_run_failsIfTheDeployerDeploysNothing() public {
        vm.etch(CREATE2_FACTORY, hex"00");
        vm.expectRevert(bytes("deployed code differs from the record"));
        d.run();

        vm.etch(CREATE2_FACTORY, hex"fd");
        vm.expectRevert(bytes("CREATE2 deploy failed"));
        d.run();
    }

    function test_run_failsWithoutTheDeployer() public {
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert(bytes("CREATE2 deployer not present"));
        d.run();
    }

    function test_run_failsWithoutTheTreasury() public {
        vm.etch(d.TREASURY(), "");
        vm.expectRevert(bytes("treasury not present"));
        d.run();
    }
}
