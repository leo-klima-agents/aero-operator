// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {Deploy} from "./Deploy.s.sol";

contract Hashes is Deploy {
    function record() external {
        string memory artifact = vm.readFile("out/ImmutableClaimOperatorFactory.sol/ImmutableClaimOperatorFactory.json");
        vm.etch(FEE_RECIPIENT, hex"00");
        (bool ok,) = CREATE2_FACTORY.call(bytes.concat(SALT, initCode()));
        require(ok && predict().code.length != 0, "CREATE2 deploy failed");

        string memory dep = "deployment";
        string memory depJson = vm.serializeAddress(dep, "leafVoter", LEAF_VOTER);
        depJson = vm.serializeAddress(dep, "escrow", ESCROW);
        depJson = vm.serializeUint(dep, "baseChainId", BASE_CHAIN_ID);
        depJson = vm.serializeAddress(dep, "feeRecipient", FEE_RECIPIENT);
        depJson = vm.serializeBytes(dep, "constructorArgs", constructorArgs());
        depJson = vm.serializeAddress(dep, "factory", predict());
        depJson = vm.serializeBytes32(dep, "factoryRuntimeKeccak", keccak256(predict().code));
        depJson = vm.serializeAddress(dep, "implementation", predictImplementation());
        depJson = vm.serializeBytes32(dep, "implementationRuntimeKeccak", keccak256(predictImplementation().code));

        string memory root = "hashes";
        string memory json =
            vm.serializeString(root, "solc", vm.parseJsonString(artifact, ".metadata.compiler.version"));
        json = vm.serializeAddress(root, "create2Deployer", CREATE2_FACTORY);
        json = vm.serializeString(root, "saltPreimage", SALT_PREIMAGE);
        json = vm.serializeBytes32(root, "salt", SALT);
        json = vm.serializeBytes32(
            root, "creationCodeKeccak", keccak256(type(ImmutableClaimOperatorFactory).creationCode)
        );
        json = vm.serializeString(root, "deployment", depJson);
        vm.writeJson(json, "verification/bytecode-hashes.json");
    }
}
