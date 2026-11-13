// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IArbSys} from "./interfaces/IArbSys.sol";
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
    address private constant ARB_SYS = address(100);

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
        address account = recipient();
        uint256 amount = _balance(token);
        if (amount != 0) emit Swept(token, amount, _pay(account, token, amount));
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
        IVotingRewardsManager manager = IVotingRewardsManager(votingRewardsManager);
        address wrappedNative = manager.wrappedNative();
        address token0 = fees ? manager.token0() : manager.incentive(programId);
        address token1 = fees ? manager.token1() : address(0);
        uint256 held0 = _held(token0, wrappedNative);
        uint256 held1 = _held(token1, wrappedNative);

        ILeafVoter.FeeClaim[] memory feeClaims = new ILeafVoter.FeeClaim[](fees ? 1 : 0);
        ILeafVoter.IncentiveClaim[] memory incentiveClaims = new ILeafVoter.IncentiveClaim[](fees ? 0 : 1);
        if (fees) feeClaims[0] = ILeafVoter.FeeClaim(votingRewardsManager, maxCheckpoints);
        else incentiveClaims[0] = ILeafVoter.IncentiveClaim(votingRewardsManager, programId, maxCheckpoints);
        ILeafVoter(leafVoter).claimRewards(tokenId, address(this), feeClaims, incentiveClaims);

        address account = recipient();
        _forward(tokenId, account, token0, wrappedNative, held0);
        _forward(tokenId, account, token1, wrappedNative, held1);
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

    function _forward(uint256 tokenId, address account, address token, address wrappedNative, uint256 heldBefore)
        private
    {
        uint256 amount = _held(token, wrappedNative) - heldBefore;
        if (amount == 0) return;
        if (token == wrappedNative) token = NATIVE;
        emit Claimed(tokenId, token, amount, _pay(account, token, amount), lastClaimBlock);
        lastClaimBlock = _blockNumber();
    }

    function _held(address token, address wrappedNative) private view returns (uint256) {
        if (token == address(0)) return 0;
        return _balance(token == wrappedNative ? NATIVE : token);
    }

    function _balance(address token) private view returns (uint256) {
        return token == NATIVE ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _blockNumber() private view returns (uint256 number) {
        number = block.number;
        if (ARB_SYS.code.length == 0) return number;
        (bool ok, bytes memory ret) = ARB_SYS.staticcall(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (ok && ret.length == 32) number = abi.decode(ret, (uint256));
    }

    function _pay(address account, address token, uint256 amount) private returns (uint256 fee) {
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
