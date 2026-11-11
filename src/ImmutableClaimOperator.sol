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
    address private immutable implementation = address(this);

    bool private transient locked;

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(
        uint256 indexed tokenId, address indexed votingRewardsManager, uint256 indexed programId, bytes reason
    );

    error NoCode(address account);
    error NotClone();
    error NotClaiming();
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

    // forge-lint: disable-next-line(missing-zero-check)
    constructor(address leafVoter_, address escrow_, uint256 baseChainId_, address feeRecipient_) {
        if (leafVoter_.code.length == 0) revert NoCode(leafVoter_);
        if (feeRecipient_.code.length == 0) revert NoCode(feeRecipient_);
        if (block.chainid == baseChainId_ && escrow_.code.length == 0) revert NoCode(escrow_);
        leafVoter = leafVoter_;
        escrow = escrow_;
        baseChainId = baseChainId_;
        feeRecipient = feeRecipient_;
    }

    receive() external payable {
        if (!locked) revert NotClaiming();
    }

    function recipient() public view returns (address account) {
        if (address(this) == implementation) revert NotClone();
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, sub(extcodesize(address()), 0x14), 0x14)
            account := shr(96, mload(0x00))
        }
    }

    function claim(
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims
    ) external nonReentrant {
        address account = recipient();
        if (block.chainid == baseChainId && IVotingEscrow(escrow).ownerOf(tokenId) != account) revert NotOwner();
        for (uint256 i; i < feeClaims.length; ++i) {
            _try(tokenId, feeClaims[i].votingRewardsManager, 0, feeClaims[i].maxCheckpoints);
        }
        for (uint256 i; i < incentiveClaims.length; ++i) {
            ILeafVoter.IncentiveClaim calldata c = incentiveClaims[i];
            _try(tokenId, c.votingRewardsManager, c.programId, c.maxCheckpoints);
        }
    }

    function claimEntry(uint256 tokenId, address votingRewardsManager, uint256 programId, uint256 maxCheckpoints)
        external
        onlySelf
    {
        address registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        if (IFactoryRegistry(registry).rewardsToGauge(votingRewardsManager) == address(0)) {
            revert NotRegistered(votingRewardsManager);
        }
        bool fees = programId == 0;
        ILeafVoter.FeeClaim[] memory feeClaims = new ILeafVoter.FeeClaim[](fees ? 1 : 0);
        ILeafVoter.IncentiveClaim[] memory incentiveClaims = new ILeafVoter.IncentiveClaim[](fees ? 0 : 1);
        if (fees) feeClaims[0] = ILeafVoter.FeeClaim(votingRewardsManager, maxCheckpoints);
        else incentiveClaims[0] = ILeafVoter.IncentiveClaim(votingRewardsManager, programId, maxCheckpoints);
        ILeafVoter(leafVoter).claimRewards(tokenId, address(this), feeClaims, incentiveClaims);

        IVotingRewardsManager manager = IVotingRewardsManager(votingRewardsManager);
        address native = manager.wrappedNative();
        if (fees) {
            _forward(tokenId, manager.token0(), native);
            _forward(tokenId, manager.token1(), native);
        } else {
            // forge-lint: disable-next-line(unused-return)
            (address token,,,,,) = manager.incentive(programId);
            _forward(tokenId, token, native);
        }
    }

    function _try(uint256 tokenId, address votingRewardsManager, uint256 programId, uint256 maxCheckpoints) private {
        // forge-lint: disable-next-line(calls-loop, reentrancy-no-eth)
        try this.claimEntry(tokenId, votingRewardsManager, programId, maxCheckpoints) {}
        catch (bytes memory reason) {
            // forge-lint: disable-next-line(reentrancy-events)
            emit ClaimFailed(tokenId, votingRewardsManager, programId, reason);
        }
    }

    function _forward(uint256 tokenId, address token, address native) private {
        if (token == address(0)) return;
        bool isNative = token == native;
        uint256 amount = isNative ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 fee = amount * FEE_BPS / 10_000;
        if (fee != 0) _send(token, isNative, feeRecipient, fee);
        _send(token, isNative, recipient(), amount - fee);
        // forge-lint: disable-next-line(reentrancy-events)
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
