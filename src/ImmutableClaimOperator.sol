// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "./interfaces/IERC20.sol";
import {IFactoryRegistry} from "./interfaces/IFactoryRegistry.sol";
import {ILeafVoter} from "./interfaces/ILeafVoter.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVotingRewardsManager} from "./interfaces/IVotingRewardsManager.sol";

contract ImmutableClaimOperator {
    uint256 public constant FEE_BPS = 100;
    uint256 private constant CLONE_SIZE = 65;
    uint256 private constant RESERVED_GAS = 20_000;
    uint256 private constant EIP150_DIVISOR = 64;
    address private constant NATIVE = address(0);

    address public immutable leafVoter;
    address public immutable escrow;
    uint256 public immutable baseChainId;
    address public immutable feeRecipient;

    uint256 public lastClaimBlock;
    bool private transient locked;

    event Claimed(
        uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee, uint256 previousClaimBlock
    );
    event ClaimFailed(uint256 indexed tokenId, address indexed votingRewardsManager, bool fees, uint256 programId);
    event Swept(address indexed token, uint256 amount, uint256 fee);

    error NoCode(address account);
    error NotOwner();
    error NotSelf();
    error NotRegistered(address votingRewardsManager);
    error NotClone();
    error InsufficientGas();
    error TransferFailed(address token);
    error Reentrancy();

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address leafVoter_, address escrow_, uint256 baseChainId_, address feeRecipient_) {
        if (feeRecipient_.code.length == 0) revert NoCode(feeRecipient_);
        leafVoter = leafVoter_;
        escrow = escrow_;
        baseChainId = baseChainId_;
        feeRecipient = feeRecipient_;
    }

    receive() external payable {}

    function claim(
        uint256 tokenId,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims,
        uint256 entryGas
    ) external nonReentrant {
        address account = recipient();
        if (block.chainid == baseChainId && IVotingEscrow(escrow).ownerOf(tokenId) != account) revert NotOwner();
        for (uint256 i; i < feeClaims.length; ++i) {
            ILeafVoter.FeeClaim calldata entry = feeClaims[i];
            _try(tokenId, entry.votingRewardsManager, true, 0, entry.maxCheckpoints, entryGas);
        }
        for (uint256 i; i < incentiveClaims.length; ++i) {
            ILeafVoter.IncentiveClaim calldata entry = incentiveClaims[i];
            _try(tokenId, entry.votingRewardsManager, false, entry.programId, entry.maxCheckpoints, entryGas);
        }
    }

    function sweep(address token) external nonReentrant {
        (uint256 amount, uint256 fee) = _pay(recipient(), token);
        if (amount != 0) emit Swept(token, amount, fee);
    }

    function claimEntry(
        uint256 tokenId,
        address votingRewardsManager,
        bool fees,
        uint256 programId,
        uint256 maxCheckpoints
    ) external {
        if (msg.sender != address(this)) revert NotSelf();
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
        address wrappedNative = manager.wrappedNative();
        address account = recipient();
        if (fees) {
            _forward(tokenId, account, manager.token0(), wrappedNative);
            _forward(tokenId, account, manager.token1(), wrappedNative);
        } else {
            _forward(tokenId, account, manager.incentive(programId), wrappedNative);
        }
    }

    function recipient() public view returns (address) {
        bytes memory code = address(this).code;
        if (code.length != CLONE_SIZE) revert NotClone();
        uint160 account = 0;
        for (uint256 i = CLONE_SIZE - 20; i < CLONE_SIZE; ++i) {
            account = account << 8 | uint8(code[i]);
        }
        return address(account);
    }

    function _try(
        uint256 tokenId,
        address votingRewardsManager,
        bool fees,
        uint256 programId,
        uint256 maxCheckpoints,
        uint256 entryGas
    ) private {
        uint256 spare = gasleft();
        spare = spare > RESERVED_GAS ? spare - RESERVED_GAS : 0;
        uint256 keptByCaller = spare / EIP150_DIVISOR;
        if (spare - keptByCaller < entryGas) revert InsufficientGas();
        try this.claimEntry{gas: entryGas}(tokenId, votingRewardsManager, fees, programId, maxCheckpoints) {}
        catch {
            emit ClaimFailed(tokenId, votingRewardsManager, fees, programId);
        }
    }

    function _forward(uint256 tokenId, address account, address token, address wrappedNative) private {
        if (token == address(0)) return;
        if (token == wrappedNative) token = NATIVE;
        (uint256 amount, uint256 fee) = _pay(account, token);
        if (amount == 0) return;
        emit Claimed(tokenId, token, amount, fee, lastClaimBlock);
        lastClaimBlock = block.number;
    }

    function _pay(address account, address token) private returns (uint256 amount, uint256 fee) {
        amount = token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (amount == 0) return (0, 0);
        fee = amount * FEE_BPS / 10_000;
        if (fee != 0) _send(token, feeRecipient, fee);
        _send(token, account, amount - fee);
    }

    function _send(address token, address to, uint256 amount) private {
        bool ok;
        if (token == NATIVE) {
            (ok,) = to.call{value: amount}("");
        } else {
            bytes memory ret;
            (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
            ok = ok && (ret.length == 0 || abi.decode(ret, (bool)));
        }
        if (!ok) revert TransferFailed(token);
    }
}
