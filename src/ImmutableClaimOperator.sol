// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFactoryRegistry} from "./interfaces/IFactoryRegistry.sol";
import {ILeafVoter} from "./interfaces/ILeafVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVotingRewardsManager} from "./interfaces/IVotingRewardsManager.sol";

contract ImmutableClaimOperator {
    uint256 public constant FEE_BPS = 100;

    address public immutable leafVoter;
    address public immutable escrow;
    uint256 public immutable baseChainId;
    address public immutable feeRecipient;

    bool private transient locked;

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(uint256 indexed tokenId, address indexed votingRewardsManager, uint256 programId);

    error ZeroAddress();
    error Reentrancy();
    error NotOwner();
    error NotSelf();
    error NotRegistered(address votingRewardsManager);
    error TransferFailed(address token);

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(address leafVoter_, address escrow_, uint256 baseChainId_, address feeRecipient_) {
        if (leafVoter_ == address(0) || escrow_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        leafVoter = leafVoter_;
        escrow = escrow_;
        baseChainId = baseChainId_;
        feeRecipient = feeRecipient_;
    }

    receive() external payable {}

    function recipient() public view returns (address account) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, 0x2d, 0x14)
            account := shr(96, mload(0x00))
        }
    }

    function claim(
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims
    ) external nonReentrant {
        if (block.chainid == baseChainId && IVotingEscrow(escrow).ownerOf(tokenId) != recipient()) revert NotOwner();
        for (uint256 i; i < feeClaims.length; ++i) {
            try this.claimFees(tokenId, feeClaims[i]) {}
            catch {
                emit ClaimFailed(tokenId, feeClaims[i].votingRewardsManager, 0);
            }
        }
        for (uint256 i; i < incentiveClaims.length; ++i) {
            try this.claimIncentives(tokenId, incentiveClaims[i]) {}
            catch {
                emit ClaimFailed(tokenId, incentiveClaims[i].votingRewardsManager, incentiveClaims[i].programId);
            }
        }
    }

    function claimFees(uint256 tokenId, ILeafVoter.FeeClaim calldata feeClaim) external onlySelf {
        IVotingRewardsManager manager = _manager(feeClaim.votingRewardsManager);
        ILeafVoter.FeeClaim[] memory feeClaims = new ILeafVoter.FeeClaim[](1);
        feeClaims[0] = feeClaim;
        ILeafVoter(leafVoter).claimRewards(tokenId, address(this), feeClaims, new ILeafVoter.IncentiveClaim[](0));
        address native = manager.wrappedNative();
        _forward(tokenId, manager.token0(), native);
        _forward(tokenId, manager.token1(), native);
    }

    function claimIncentives(uint256 tokenId, ILeafVoter.IncentiveClaim calldata incentiveClaim) external onlySelf {
        IVotingRewardsManager manager = _manager(incentiveClaim.votingRewardsManager);
        ILeafVoter.IncentiveClaim[] memory incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
        incentiveClaims[0] = incentiveClaim;
        ILeafVoter(leafVoter).claimRewards(tokenId, address(this), new ILeafVoter.FeeClaim[](0), incentiveClaims);
        (address token,,,,,) = manager.incentive(incentiveClaim.programId);
        _forward(tokenId, token, manager.wrappedNative());
    }

    function _manager(address votingRewardsManager) private view returns (IVotingRewardsManager) {
        address registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        if (IFactoryRegistry(registry).rewardsToGauge(votingRewardsManager) == address(0)) {
            revert NotRegistered(votingRewardsManager);
        }
        return IVotingRewardsManager(votingRewardsManager);
    }

    function _forward(uint256 tokenId, address token, address native) private {
        bool isNative = token == native;
        uint256 amount = isNative ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 fee = amount * FEE_BPS / 10_000;
        if (fee != 0) _send(token, isNative, feeRecipient, fee);
        _send(token, isNative, recipient(), amount - fee);
        emit Claimed(tokenId, token, amount, fee);
    }

    function _send(address token, bool isNative, address to, uint256 amount) private {
        bool ok;
        if (isNative) {
            // forge-lint: disable-next-line(arbitrary-send-eth)
            (ok,) = to.call{value: amount}("");
        } else {
            bytes memory ret;
            (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
            ok = ok && (ret.length == 0 ? token.code.length != 0 : abi.decode(ret, (bool)));
        }
        if (!ok) revert TransferFailed(token);
    }
}
