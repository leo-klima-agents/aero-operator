// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFactoryRegistry} from "./interfaces/IFactoryRegistry.sol";
import {ILeafVoter} from "./interfaces/ILeafVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVotingRewardsManager} from "./interfaces/IVotingRewardsManager.sol";

contract ImmutableClaimOperator {
    struct Entry {
        uint256 tokenId;
        address recipient;
        address registry;
        address votingRewardsManager;
        bool fees;
        uint256 programId;
        uint256 maxCheckpoints;
    }

    uint256 public constant FEE_BPS = 100;
    uint256 private constant CLONE_SIZE = 65;
    uint256 private constant RESERVED_GAS = 20_000;
    uint256 private constant MAX_REASON = 256;

    address public immutable leafVoter;
    address public immutable escrow;
    uint256 public immutable baseChainId;
    address public immutable feeRecipient;

    bool private transient locked;

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(
        uint256 indexed tokenId, address indexed votingRewardsManager, uint256 indexed programId, bytes reason
    );

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

    function recipient() public view returns (address account) {
        if (address(this).code.length != CLONE_SIZE) revert NotClone();
        assembly ("memory-safe") {
            extcodecopy(address(), 0x00, sub(CLONE_SIZE, 0x14), 0x14)
            account := shr(96, mload(0x00))
        }
    }

    function claim(
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims,
        uint256 entryGas
    ) external nonReentrant {
        Entry memory entry;
        entry.tokenId = tokenId;
        entry.recipient = recipient();
        if (block.chainid == baseChainId && IVotingEscrow(escrow).ownerOf(tokenId) != entry.recipient) {
            revert NotOwner();
        }
        entry.registry = ILeafVoter(leafVoter).FACTORY_REGISTRY();
        entry.fees = true;
        for (uint256 i; i < feeClaims.length; ++i) {
            entry.votingRewardsManager = feeClaims[i].votingRewardsManager;
            entry.maxCheckpoints = feeClaims[i].maxCheckpoints;
            _try(entry, entryGas);
        }
        entry.fees = false;
        for (uint256 i; i < incentiveClaims.length; ++i) {
            entry.votingRewardsManager = incentiveClaims[i].votingRewardsManager;
            entry.programId = incentiveClaims[i].programId;
            entry.maxCheckpoints = incentiveClaims[i].maxCheckpoints;
            _try(entry, entryGas);
        }
    }

    function claimEntry(Entry calldata entry) external onlySelf {
        IVotingRewardsManager manager = IVotingRewardsManager(entry.votingRewardsManager);
        if (IFactoryRegistry(entry.registry).rewardsToGauge(address(manager)) == address(0)) {
            revert NotRegistered(address(manager));
        }
        ILeafVoter.FeeClaim[] memory feeClaims = new ILeafVoter.FeeClaim[](entry.fees ? 1 : 0);
        ILeafVoter.IncentiveClaim[] memory incentiveClaims = new ILeafVoter.IncentiveClaim[](entry.fees ? 0 : 1);
        if (entry.fees) {
            feeClaims[0] = ILeafVoter.FeeClaim(address(manager), entry.maxCheckpoints);
        } else {
            incentiveClaims[0] = ILeafVoter.IncentiveClaim(address(manager), entry.programId, entry.maxCheckpoints);
        }
        ILeafVoter(leafVoter).claimRewards(entry.tokenId, address(this), feeClaims, incentiveClaims);

        address native = manager.wrappedNative();
        if (entry.fees) {
            _forward(entry, manager.token0(), native);
            _forward(entry, manager.token1(), native);
        } else {
            // forge-lint: disable-next-line(unused-return)
            (address token,,,,,) = manager.incentive(entry.programId);
            _forward(entry, token, native);
        }
    }

    // An entry is given `entryGas`, of which a call can pass on 63/64 of what is left, less what handling its
    // failure may need.
    function _try(Entry memory entry, uint256 entryGas) private {
        uint256 passable = gasleft();
        passable = passable > RESERVED_GAS ? passable - RESERVED_GAS : 0;
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (passable - passable / 64 < entryGas) revert InsufficientGas();
        // forge-lint: disable-next-line(calls-loop, reentrancy-no-eth)
        try this.claimEntry{gas: entryGas}(entry) {}
        catch {
            bytes memory reason;
            assembly ("memory-safe") {
                let size := returndatasize()
                if gt(size, MAX_REASON) { size := MAX_REASON }
                reason := mload(0x40)
                mstore(reason, size)
                returndatacopy(add(reason, 0x20), 0, size)
                mstore(0x40, add(add(reason, 0x20), and(add(size, 0x1f), not(0x1f))))
            }
            // forge-lint: disable-next-line(reentrancy-events)
            emit ClaimFailed(entry.tokenId, entry.votingRewardsManager, entry.programId, reason);
        }
    }

    function _forward(Entry calldata entry, address token, address native) private {
        if (token == address(0)) return;
        bool isNative = token == native;
        uint256 amount = isNative ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        uint256 fee = amount * FEE_BPS / 10_000;
        if (fee != 0) _send(token, isNative, feeRecipient, fee);
        _send(token, isNative, entry.recipient, amount - fee);
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(entry.tokenId, token, amount, fee);
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
