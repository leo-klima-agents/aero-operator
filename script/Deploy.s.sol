// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ImmutableClaimOperator} from "../src/ImmutableClaimOperator.sol";
import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";

contract Deploy is Script {
    address public constant LEAF_VOTER = 0x382409fad8503FbCdbB27A4211551fa03e884078;
    address public constant ESCROW = 0xBF7977E1521e9a3032bf7243Ee4712f311f13915;
    uint256 public constant BASE_CHAIN_ID = 8453;
    address public constant FEE_RECIPIENT = 0x450c72de8c0079B49AcedF294a13011bd09D125B;

    string public constant SALT_PREIMAGE = "metadex.cafe/ImmutableClaimOperatorFactory/v1";
    bytes32 public constant SALT = keccak256(bytes(SALT_PREIMAGE));

    function constructorArgs() public pure returns (bytes memory) {
        return abi.encode(LEAF_VOTER, ESCROW, BASE_CHAIN_ID, FEE_RECIPIENT);
    }

    function initCode() public pure returns (bytes memory) {
        return bytes.concat(type(ImmutableClaimOperatorFactory).creationCode, constructorArgs());
    }

    function predict() public pure returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(initCode()), CREATE2_FACTORY);
    }

    function predictImplementation() public pure returns (address) {
        return vm.computeCreateAddress(predict(), 1);
    }

    function run() external returns (address deployed) {
        require(CREATE2_FACTORY.code.length != 0, "CREATE2 deployer not present");
        // Reverts where the fee Safe is missing.
        new ImmutableClaimOperator(LEAF_VOTER, ESCROW, BASE_CHAIN_ID, FEE_RECIPIENT);
        deployed = predict();
        console.log("ImmutableClaimOperatorFactory", deployed);
        console.log("ImmutableClaimOperator", predictImplementation());
        require(
            deployed == vm.parseJsonAddress(vm.readFile("verification/bytecode-hashes.json"), ".deployment.factory"),
            "build differs from verification/bytecode-hashes.json"
        );
        if (deployed.code.length != 0) {
            console.log("already deployed");
            return deployed;
        }
        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(bytes.concat(SALT, initCode()));
        vm.stopBroadcast();
        require(ok && deployed.code.length != 0, "CREATE2 deploy failed");
        console.log("deployed");
    }
}
