// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFactoryRegistry} from "./interfaces/IFactoryRegistry.sol";
import {ILeafVoter} from "./interfaces/ILeafVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVotingRewardsManager} from "./interfaces/IVotingRewardsManager.sol";

contract ImmutableClaimOperator {
    uint256 public constant FEE_BPS = 100;
    uint256 private constant CLONE_SIZE = 65;
    uint256 private constant RESERVED_GAS = 20_000;

    address public immutable leafVoter;
    address public immutable escrow;
    uint256 public immutable baseChainId;
    address public immutable feeRecipient;

    bool private transient locked;

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(uint256 indexed tokenId, address indexed votingRewardsManager, bool fees, uint256 programId);

    error NoCode(address account);
    error NotClone();
    error NotClaiming();
    error InsufficientGas();
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

    function recipient() public view returns (address) {
        if (address(this).code.length != CLONE_SIZE) revert NotClone();
        bytes memory code = address(this).code;
        uint160 account = 0;
        for (uint256 i = CLONE_SIZE - 20; i < CLONE_SIZE; ++i) {
            account = account << 8 | uint8(code[i]);
        }
        return address(account);
    }

    function claim(
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims,
        uint256 entryGas
    ) external nonReentrant {
        address account = recipient();
        if (block.chainid == baseChainId && IVotingEscrow(escrow).ownerOf(tokenId) != account) revert NotOwner();
        for (uint256 i; i < feeClaims.length; ++i) {
            _try(tokenId, feeClaims[i].votingRewardsManager, true, 0, feeClaims[i].maxCheckpoints, entryGas);
        }
        for (uint256 i; i < incentiveClaims.length; ++i) {
            ILeafVoter.IncentiveClaim calldata c = incentiveClaims[i];
            _try(tokenId, c.votingRewardsManager, false, c.programId, c.maxCheckpoints, entryGas);
        }
    }

    function claimEntry(
        uint256 tokenId,
        address votingRewardsManager,
        bool fees,
        uint256 programId,
        uint256 maxCheckpoints
    ) external onlySelf {
        // Already so in a claim. Lets an entry be simulated alone, in a call from the clone's own address.
        locked = true;
        address registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        if (IFactoryRegistry(registry).rewardsToGauge(votingRewardsManager) == address(0)) {
            revert NotRegistered(votingRewardsManager);
        }
        ILeafVoter.FeeClaim[] memory feeClaims = new ILeafVoter.FeeClaim[](fees ? 1 : 0);
        ILeafVoter.IncentiveClaim[] memory incentiveClaims = new ILeafVoter.IncentiveClaim[](fees ? 0 : 1);
        if (fees) feeClaims[0] = ILeafVoter.FeeClaim(votingRewardsManager, maxCheckpoints);
        else incentiveClaims[0] = ILeafVoter.IncentiveClaim(votingRewardsManager, programId, maxCheckpoints);
        ILeafVoter(leafVoter).claimRewards(tokenId, address(this), feeClaims, incentiveClaims);

        IVotingRewardsManager manager = IVotingRewardsManager(votingRewardsManager);
        address native = manager.wrappedNative();
        address account = recipient();
        if (fees) {
            _forward(tokenId, account, manager.token0(), native);
            _forward(tokenId, account, manager.token1(), native);
        } else {
            // forge-lint: disable-next-line(unused-return)
            (address token,,,,,) = manager.incentive(programId);
            _forward(tokenId, account, token, native);
        }
    }

    // An entry is given `entryGas`: a call can pass on 63/64 of the gas left, less what is kept to go on after it.
    function _try(
        uint256 tokenId,
        address votingRewardsManager,
        bool fees,
        uint256 programId,
        uint256 maxCheckpoints,
        uint256 entryGas
    ) private {
        uint256 passable = gasleft();
        passable = passable > RESERVED_GAS ? passable - RESERVED_GAS : 0;
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (passable - passable / 64 < entryGas) revert InsufficientGas();
        // forge-lint: disable-next-line(calls-loop, reentrancy-no-eth)
        try this.claimEntry{gas: entryGas}(tokenId, votingRewardsManager, fees, programId, maxCheckpoints) {}
        catch {
            // forge-lint: disable-next-line(reentrancy-events)
            emit ClaimFailed(tokenId, votingRewardsManager, fees, programId);
        }
    }

    function _forward(uint256 tokenId, address account, address token, address native) private {
        if (token == address(0)) return;
        bool isNative = token == native;
        uint256 amount = isNative ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 fee = amount * FEE_BPS / 10_000;
        if (fee != 0) _send(token, isNative, feeRecipient, fee);
        _send(token, isNative, account, amount - fee);
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
