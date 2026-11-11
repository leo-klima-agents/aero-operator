// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ImmutableClaimOperator} from "./ImmutableClaimOperator.sol";
import {ILeafVoter} from "./interfaces/ILeafVoter.sol";

contract ImmutableClaimOperatorFactory {
    address public immutable implementation;

    error DeployFailed();

    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address leafVoter, address escrow, uint256 baseChainId, address feeRecipient) {
        implementation = address(new ImmutableClaimOperator(leafVoter, escrow, baseChainId, feeRecipient));
    }

    function claim(
        address recipient,
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims,
        uint256 entryGas
    ) external {
        bytes memory initCode = _initCode(recipient);
        address operator = _predict(initCode);
        if (operator.code.length == 0) {
            address deployed;
            assembly ("memory-safe") {
                deployed := create2(0, add(initCode, 0x20), mload(initCode), 0)
            }
            if (deployed != operator) revert DeployFailed();
        }
        ImmutableClaimOperator(payable(operator)).claim(tokenId, feeClaims, incentiveClaims, entryGas);
    }

    function operatorOf(address recipient) external view returns (address) {
        return _predict(_initCode(recipient));
    }

    function _predict(bytes memory initCode) private view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), keccak256(initCode)));
        return address(uint160(uint256(hash)));
    }

    function _initCode(address recipient) private view returns (bytes memory) {
        return abi.encodePacked(
            hex"6100413d81600a3d39f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3",
            recipient
        );
    }
}
