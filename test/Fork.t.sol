// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {Discovery} from "../script/Discovery.sol";
import {ImmutableClaimOperator} from "../src/ImmutableClaimOperator.sol";
import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";

interface IVoter {
    function allocationChainAmounts(uint256 tokenId, uint256 chainId) external view returns (uint128);
    function setOperator(uint256 tokenId, uint256 chainId, address operator, uint256 gasLimit, address refundTo)
        external
        payable;
}

interface ILeafVoterExtra {
    function ORCHESTRATOR() external view returns (address);
    function operator(uint256 tokenId) external view returns (address);
    function setOperator(uint256 tokenId, address operator) external;
    function allocatedGauges(uint256 tokenId) external view returns (address[] memory);
    function allocations(uint256 tokenId, address gauge) external view returns (uint128);
    function tokenStates(uint256 tokenId)
        external
        view
        returns (address operator, uint48 lastAllocated, bool canVoteForZeroCapGauges, uint128 chainAllocation);
}

interface IVotingEscrowExtra {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function staked(uint256 tokenId) external view returns (uint128 amount, uint48 end, bool isPermanent);
}

abstract contract ForkTest is Test {
    uint256 internal constant ENTRY_GAS = 1_000_000;
    bytes internal constant FEE_SAFE_STAND_IN = hex"00";
    uint256 internal constant STAKE = 621;
    bytes32 internal constant CLAIMED = ImmutableClaimOperator.Claimed.selector;
    bytes32 internal constant CLAIM_FAILED = ImmutableClaimOperator.ClaimFailed.selector;

    Deploy internal d;
    ILeafVoterExtra internal leaf;
    ImmutableClaimOperatorFactory internal factory;
    ImmutableClaimOperator internal operator;
    address internal recipient;
    address internal feeRecipient;
    address internal keeper = makeAddr("keeper");

    ILeafVoter.FeeClaim[] internal feeClaims;
    ILeafVoter.IncentiveClaim[] internal incentiveClaims;
    address[] internal tokens;
    address internal wrappedNative;
    uint256 internal claimGas;

    function _rpc() internal view virtual returns (string memory);
    function _block() internal pure virtual returns (uint256);
    function _chainId() internal pure virtual returns (uint256);
    function _recipient() internal virtual returns (address);
    function _setOperator(address account) internal virtual;

    function setUp() public {
        string memory rpc = _rpc();
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc, _block());
        assertEq(block.chainid, _chainId());

        d = new Deploy();
        leaf = ILeafVoterExtra(d.LEAF_VOTER());
        feeRecipient = d.FEE_RECIPIENT();
        if (feeRecipient.code.length == 0) vm.etch(feeRecipient, FEE_SAFE_STAND_IN);
        factory = ImmutableClaimOperatorFactory(d.run());
        recipient = _recipient();
        operator = ImmutableClaimOperator(payable(factory.operatorOf(recipient)));
        _discover();
    }

    function _discover() internal {
        Discovery.Claims memory claims = Discovery.claims(address(leaf), STAKE, 0, true);
        assertGt(claims.fees.length, 0, "the stake has nothing to claim on this chain at this block");
        assertEq(claims.unreadPrograms, 0, "some incentive programs could not be read");
        emit log_named_uint("gauges and programs left out, which a fork cannot run", claims.leftOut);
        feeClaims = claims.fees;
        incentiveClaims = claims.incentives;
        tokens = claims.tokens;
        wrappedNative = claims.wrappedNative;
    }

    function _balances(address account) internal view returns (uint256[] memory) {
        return Discovery.balances(tokens, account);
    }

    function _gained(address account, uint256[] memory before) internal view returns (uint256[] memory) {
        return Discovery.gained(tokens, account, before);
    }

    function _claim() internal returns (Vm.Log[] memory) {
        vm.recordLogs();
        vm.prank(keeper);
        uint256 gas = gasleft();
        factory.claim(recipient, STAKE, feeClaims, incentiveClaims, ENTRY_GAS);
        claimGas = gas - gasleft();
        return vm.getRecordedLogs();
    }

    function _failuresWith(uint256 entryGas) internal returns (uint256 failures) {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        factory.claim(recipient, STAKE, feeClaims, incentiveClaims, entryGas);
        failures = _count(vm.getRecordedLogs(), CLAIM_FAILED);
        vm.revertToState(snapshot);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(operator) && logs[i].topics[0] == topic) ++count;
        }
    }

    function _claimed(Vm.Log[] memory logs, bool feesNotAmounts) internal view returns (uint256[] memory sums) {
        sums = new uint256[](tokens.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(operator) || logs[i].topics[0] != CLAIMED) continue;
            assertEq(uint256(logs[i].topics[1]), STAKE);
            (uint256 amount, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(fee, amount / 100);
            sums[_indexOf(address(uint160(uint256(logs[i].topics[2]))))] += feesNotAmounts ? fee : amount;
        }
    }

    function _indexOf(address token) internal view returns (uint256 index) {
        while (tokens[index] != token) ++index;
    }

    function _stakeState() internal view returns (bytes memory state) {
        (, uint48 lastAllocated, bool zeroCap, uint128 chainAllocation) = leaf.tokenStates(STAKE);
        address[] memory gauges = leaf.allocatedGauges(STAKE);
        state = abi.encode(lastAllocated, zeroCap, chainAllocation, gauges);
        for (uint256 i; i < gauges.length; ++i) {
            state = bytes.concat(state, abi.encode(leaf.allocations(STAKE, gauges[i])));
        }
    }

    function _assertNothingLeft() internal view {
        address[3] memory ours = [address(operator), address(factory), factory.implementation()];
        for (uint256 i; i < ours.length; ++i) {
            uint256[] memory balances = _balances(ours[i]);
            for (uint256 j; j < balances.length; ++j) {
                assertEq(balances[j], 0);
            }
            if (wrappedNative != address(0)) assertEq(IERC20(wrappedNative).balanceOf(ours[i]), 0);
        }
    }

    function test_claim_noEntryFailsWith700000GasAndSomeDoWith500000() public {
        _setOperator(address(operator));

        assertEq(_failuresWith(700_000), 0);
        assertGt(_failuresWith(500_000), 0);
    }

    function test_claim_paysInFullLessTheFee() public {
        _setOperator(address(operator));
        bytes memory stake = _stakeState();
        uint256 entries = feeClaims.length + incentiveClaims.length;

        uint256 snapshot = vm.snapshotState();
        uint256[] memory before = _balances(recipient);
        vm.prank(leaf.ORCHESTRATOR());
        uint256 directGas = gasleft();
        ILeafVoter(address(leaf)).claimRewards(STAKE, recipient, feeClaims, incentiveClaims);
        directGas -= gasleft();
        uint256[] memory direct = _gained(recipient, before);
        vm.revertToState(snapshot);

        uint256[] memory feesBefore = _balances(feeRecipient);
        assertEq(address(operator).code.length, 0);
        Vm.Log[] memory logs = _claim();
        assertEq(operator.recipient(), recipient);
        uint256[] memory paid = _gained(recipient, before);
        uint256[] memory fees = _gained(feeRecipient, feesBefore);

        assertEq(_claimed(logs, false), direct);
        assertEq(_claimed(logs, true), fees);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(paid[i] + fees[i], direct[i]);
            assertLe(fees[i], direct[i] / 100);
            assertGe(fees[i] + 2 * entries, direct[i] / 100);
        }
        assertEq(_count(logs, CLAIM_FAILED), 0);
        assertLt(claimGas, directGas + 150_000 + 90_000 * entries);
        _assertNothingLeft();
        assertEq(_stakeState(), stake);

        logs = _claim();
        assertEq(_count(logs, CLAIM_FAILED), 0);
        _assertNothingLeft();
    }

    function test_sweep_paysTheWrappedAndNativeTokensTheCloneHolds() public {
        _setOperator(address(operator));
        _claim();
        deal(wrappedNative, address(operator), 1 ether);
        vm.deal(address(operator), 2 ether);
        uint256[2] memory held = [IERC20(wrappedNative).balanceOf(recipient), recipient.balance];
        uint256[2] memory feesHeld = [IERC20(wrappedNative).balanceOf(feeRecipient), feeRecipient.balance];

        vm.startPrank(keeper);
        operator.sweep(wrappedNative);
        operator.sweep(address(0));
        vm.stopPrank();

        assertEq(IERC20(wrappedNative).balanceOf(recipient) - held[0], 0.99 ether);
        assertEq(IERC20(wrappedNative).balanceOf(feeRecipient) - feesHeld[0], 0.01 ether);
        assertEq(recipient.balance - held[1], 1.98 ether);
        assertEq(feeRecipient.balance - feesHeld[1], 0.02 ether);
        _assertNothingLeft();
    }

    function test_optingOut_stopsTheClaims() public {
        _setOperator(address(operator));
        assertEq(leaf.operator(STAKE), address(operator));
        _setOperator(address(0));
        assertEq(leaf.operator(STAKE), address(0));
        bytes memory stake = _stakeState();
        uint256[] memory before = _balances(recipient);
        uint256[] memory feesBefore = _balances(feeRecipient);

        Vm.Log[] memory logs = _claim();

        assertEq(_count(logs, CLAIM_FAILED), feeClaims.length + incentiveClaims.length);
        assertEq(_count(logs, CLAIMED), 0);
        assertEq(_balances(recipient), before);
        assertEq(_balances(feeRecipient), feesBefore);
        _assertNothingLeft();
        assertEq(_stakeState(), stake);

        _setOperator(address(operator));
        assertEq(_count(_claim(), CLAIM_FAILED), 0);
    }
}

contract BaseForkTest is ForkTest {
    IVoter internal constant VOTER = IVoter(0x49d7d4f17Ec56Ef8fA04E464AF5D1A4942CC31e6);
    IVotingEscrowExtra internal escrow;

    function _rpc() internal view override returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string(""));
    }

    function _block() internal pure override returns (uint256) {
        return 56_166_000;
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }

    function _recipient() internal override returns (address) {
        escrow = IVotingEscrowExtra(d.ESCROW());
        return escrow.ownerOf(STAKE);
    }

    function _setOperator(address account) internal override {
        vm.prank(recipient);
        VOTER.setOperator(STAKE, block.chainid, account, 0, recipient);
    }

    function test_claim_leavesTheStakeWithItsOwner() public {
        (uint128 amount, uint48 end, bool isPermanent) = escrow.staked(STAKE);
        uint128 allocated = VOTER.allocationChainAmounts(STAKE, block.chainid);
        _setOperator(address(operator));

        _claim();

        assertEq(escrow.ownerOf(STAKE), recipient);
        (uint128 amountAfter, uint48 endAfter, bool isPermanentAfter) = escrow.staked(STAKE);
        assertEq(amountAfter, amount);
        assertEq(endAfter, end);
        assertEq(isPermanentAfter, isPermanent);
        assertEq(VOTER.allocationChainAmounts(STAKE, block.chainid), allocated);
    }

    function test_claim_afterASale_isRefused() public {
        _setOperator(address(operator));
        address buyer = makeAddr("buyer");
        vm.prank(recipient);
        escrow.transferFrom(recipient, buyer, STAKE);
        assertEq(leaf.operator(STAKE), address(operator));
        uint256[] memory before = _balances(recipient);

        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, STAKE, feeClaims, incentiveClaims, ENTRY_GAS);
        assertEq(_balances(recipient), before);

        vm.expectRevert(abi.encodeWithSignature("NotAuthorized()"));
        vm.prank(recipient);
        VOTER.setOperator(STAKE, block.chainid, address(operator), 0, recipient);

        address buyerOperator = factory.operatorOf(buyer);
        vm.prank(buyer);
        VOTER.setOperator(STAKE, block.chainid, buyerOperator, 0, buyer);
        uint256 native = buyer.balance;
        factory.claim(buyer, STAKE, feeClaims, incentiveClaims, ENTRY_GAS);
        assertGt(buyer.balance, native);
        assertEq(_balances(recipient), before);
    }
}

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function unBlacklist(address account) external;
}

contract EthereumForkTest is ForkTest {
    IUSDC internal constant USDC = IUSDC(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function _rpc() internal view override returns (string memory) {
        return vm.envOr("ETHEREUM_RPC_URL", string(""));
    }

    function _block() internal pure override returns (uint256) {
        return 26_393_600;
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }

    function _recipient() internal override returns (address) {
        return makeAddr("recipient");
    }

    function _setOperator(address account) internal override {
        address bridgeFromBase = leaf.ORCHESTRATOR();
        vm.prank(bridgeFromBase);
        leaf.setOperator(STAKE, account);
    }

    function test_claim_aTokenTheRecipientCannotReceive_failsAloneAndStaysClaimable() public {
        _setOperator(address(operator));
        vm.prank(USDC.blacklister());
        USDC.blacklist(recipient);
        uint256 native = recipient.balance;

        Vm.Log[] memory logs = _claim();

        assertGt(_count(logs, CLAIM_FAILED), 0);
        assertGt(_count(logs, CLAIMED), 0);
        assertGt(recipient.balance, native);
        assertEq(USDC.balanceOf(recipient), 0);
        assertEq(USDC.balanceOf(feeRecipient), 0);
        _assertNothingLeft();

        vm.prank(USDC.blacklister());
        USDC.unBlacklist(recipient);
        logs = _claim();

        assertEq(_count(logs, CLAIM_FAILED), 0);
        assertGt(USDC.balanceOf(recipient), 1e6);
        assertGt(USDC.balanceOf(feeRecipient), 0);
        _assertNothingLeft();
    }
}
