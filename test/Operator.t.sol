// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {ImmutableClaimOperator} from "../src/ImmutableClaimOperator.sol";
import {ImmutableClaimOperatorFactory} from "../src/ImmutableClaimOperatorFactory.sol";
import {ILeafVoter} from "../src/interfaces/ILeafVoter.sol";
import {
    MockFactoryRegistry,
    MockLeafVoter,
    MockRewardsManager,
    MockSafe,
    MockToken,
    MockVotingEscrow,
    MockWrappedNative
} from "./mocks/Mocks.sol";

uint256 constant ENTRY_GAS = 1_000_000;

contract Reenterer {
    ImmutableClaimOperatorFactory internal immutable FACTORY;
    bool internal immutable BUBBLE;
    bytes public reason;

    constructor(ImmutableClaimOperatorFactory factory, bool bubble) {
        FACTORY = factory;
        BUBBLE = bubble;
    }

    receive() external payable {
        try FACTORY.claim(
            address(this), 1, new ILeafVoter.FeeClaim[](0), new ILeafVoter.IncentiveClaim[](0), ENTRY_GAS
        ) {}
        catch (bytes memory err) {
            reason = err;
            if (BUBBLE) revert("reentered");
        }
    }
}

contract OperatorTest is Test {
    uint256 internal constant BASE = 8453;
    uint256 internal constant ID = 1;

    MockFactoryRegistry internal registry;
    MockLeafVoter internal voter;
    MockVotingEscrow internal escrow;
    MockWrappedNative internal weth;
    MockToken internal usdc;
    MockToken internal aero;
    MockRewardsManager internal pair;
    MockRewardsManager internal native;

    ImmutableClaimOperatorFactory internal factory;
    ImmutableClaimOperator internal operator;
    address internal recipient = makeAddr("recipient");
    address internal feeRecipient;

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(uint256 indexed tokenId, address indexed votingRewardsManager, bool fees, uint256 programId);

    function setUp() public {
        feeRecipient = address(new MockSafe());
        registry = new MockFactoryRegistry();
        voter = new MockLeafVoter(address(registry));
        escrow = new MockVotingEscrow();
        weth = new MockWrappedNative();
        usdc = new MockToken();
        aero = new MockToken();
        pair = _manager(address(aero), address(usdc));
        native = _manager(address(weth), address(usdc));

        factory = new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, feeRecipient);
        operator = ImmutableClaimOperator(payable(factory.operatorOf(recipient)));
        voter.setOperator(ID, address(operator));
    }

    function _manager(address token0, address token1) internal returns (MockRewardsManager manager) {
        manager = new MockRewardsManager(address(voter), token0, token1, address(weth));
        registry.register(address(manager));
    }

    function _owe(MockRewardsManager manager, uint256 amount0, uint256 amount1) internal {
        _fund(manager, manager.token0(), amount0);
        _fund(manager, manager.token1(), amount1);
        manager.setFees(ID, amount0, amount1);
    }

    function _fund(MockRewardsManager manager, address token, uint256 amount) internal {
        if (token == address(weth)) {
            vm.deal(address(this), amount);
            weth.mint{value: amount}(address(manager));
        } else {
            MockToken(token).mint(address(manager), amount);
        }
    }

    function _fees(MockRewardsManager a) internal pure returns (ILeafVoter.FeeClaim[] memory claims) {
        claims = new ILeafVoter.FeeClaim[](1);
        claims[0] = ILeafVoter.FeeClaim(address(a), 500);
    }

    function _fees(MockRewardsManager a, MockRewardsManager b)
        internal
        pure
        returns (ILeafVoter.FeeClaim[] memory claims)
    {
        claims = new ILeafVoter.FeeClaim[](2);
        claims[0] = ILeafVoter.FeeClaim(address(a), 500);
        claims[1] = ILeafVoter.FeeClaim(address(b), 500);
    }

    function _incentive(MockRewardsManager a, uint256 programId)
        internal
        pure
        returns (ILeafVoter.IncentiveClaim[] memory claims)
    {
        claims = new ILeafVoter.IncentiveClaim[](1);
        claims[0] = ILeafVoter.IncentiveClaim(address(a), programId, 500);
    }

    function _expectFailed(address emitter, address manager, uint256 programId) internal {
        vm.expectEmit(emitter);
        emit ClaimFailed(ID, manager, programId == 0, programId);
    }

    function _none() internal pure returns (ILeafVoter.IncentiveClaim[] memory) {
        return new ILeafVoter.IncentiveClaim[](0);
    }

    function _assertEmpty(address account) internal view {
        assertEq(account.balance, 0);
        assertEq(weth.balanceOf(account), 0);
        assertEq(usdc.balanceOf(account), 0);
        assertEq(aero.balanceOf(account), 0);
    }

    function _assertNothingLeft() internal view {
        _assertEmpty(address(operator));
        _assertEmpty(address(factory));
        _assertEmpty(factory.implementation());
    }

    function test_constructor_needsTheFeeRecipientToHaveCode() public {
        address none = makeAddr("none");
        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NoCode.selector, none));
        new ImmutableClaimOperator(address(voter), address(escrow), BASE, none);
        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NoCode.selector, none));
        new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, none);
    }

    function test_theImplementation_isNotAClone() public {
        ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));
        voter.setOperator(ID, address(implementation));
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        implementation.recipient();
        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        implementation.claim(ID, _fees(pair), _none(), ENTRY_GAS);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_splitsTokensAndNativeBetweenRecipientAndFee() public {
        _owe(pair, 1e18, 2e6);
        _owe(native, 3 ether, 5e6);

        vm.expectEmit(address(operator));
        emit Claimed(ID, address(aero), 1e18, 0.01e18);
        vm.expectEmit(address(operator));
        emit Claimed(ID, address(usdc), 2e6, 0.02e6);
        vm.expectEmit(address(operator));
        emit Claimed(ID, address(weth), 3 ether, 0.03 ether);
        vm.expectEmit(address(operator));
        emit Claimed(ID, address(usdc), 5e6, 0.05e6);
        factory.claim(recipient, ID, _fees(pair, native), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(aero.balanceOf(feeRecipient), 0.01e18);
        assertEq(usdc.balanceOf(recipient), 6.93e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.07e6);
        assertEq(recipient.balance, 2.97 ether);
        assertEq(feeRecipient.balance, 0.03 ether);
        _assertNothingLeft();
    }

    function test_claim_incentives() public {
        uint256 programId = pair.addIncentive(address(usdc));
        uint256 nativeId = pair.addIncentive(address(weth));
        _fund(pair, address(usdc), 100e6);
        _fund(pair, address(weth), 1 ether);
        pair.setIncentive(ID, programId, 100e6);
        pair.setIncentive(ID, nativeId, 1 ether);

        ILeafVoter.IncentiveClaim[] memory claims = new ILeafVoter.IncentiveClaim[](2);
        claims[0] = ILeafVoter.IncentiveClaim(address(pair), programId, 500);
        claims[1] = ILeafVoter.IncentiveClaim(address(pair), nativeId, 500);
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), claims, ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 99e6);
        assertEq(usdc.balanceOf(feeRecipient), 1e6);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(feeRecipient.balance, 0.01 ether);
        _assertNothingLeft();
    }

    function test_claim_takesNoFeeOnDust() public {
        _owe(pair, 99, 100);

        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 99);
        assertEq(aero.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(recipient), 99);
        assertEq(usdc.balanceOf(feeRecipient), 1);
    }

    function test_claim_forwardsTokensSentToTheClone() public {
        usdc.mint(address(operator), 10e6);
        vm.deal(address(operator), 1 ether);
        _owe(native, 1 ether, 0);

        factory.claim(recipient, ID, _fees(native), _none(), ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 9.9e6);
        assertEq(recipient.balance, 1.98 ether);
        _assertNothingLeft();
    }

    function test_claim_aTokenThatRevertsDoesNotBlockTheOthers() public {
        MockToken bad = new MockToken();
        MockRewardsManager broken = _manager(address(bad), address(aero));
        _owe(broken, 5e18, 7e18);
        _owe(pair, 1e18, 2e6);
        _owe(native, 1 ether, 0);
        bad.setBlocked(recipient, true);

        ILeafVoter.FeeClaim[] memory claims = new ILeafVoter.FeeClaim[](3);
        claims[0] = ILeafVoter.FeeClaim(address(pair), 500);
        claims[1] = ILeafVoter.FeeClaim(address(broken), 500);
        claims[2] = ILeafVoter.FeeClaim(address(native), 500);
        _expectFailed(address(operator), address(broken), 0);
        factory.claim(recipient, ID, claims, _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(recipient.balance, 0.99 ether);
        (uint256 owed0, uint256 owed1) = broken.fees(ID);
        assertEq(owed0, 5e18);
        assertEq(owed1, 7e18);
        assertEq(bad.balanceOf(address(broken)), 5e18);
        assertEq(aero.balanceOf(address(broken)), 7e18);
        assertEq(bad.balanceOf(feeRecipient), 0);
        assertEq(bad.balanceOf(address(operator)), 0);
        _assertNothingLeft();

        bad.setBlocked(recipient, false);
        factory.claim(recipient, ID, claims, _none(), ENTRY_GAS);
        assertEq(bad.balanceOf(recipient), 4.95e18);
        assertEq(aero.balanceOf(recipient), 0.99e18 + 6.93e18);
    }

    function test_claim_aManagerThatRevertsDoesNotBlockTheOthers() public {
        _owe(pair, 1e18, 2e6);
        _owe(native, 1 ether, 0);
        usdc.setBlocked(address(operator), true);

        _expectFailed(address(operator), address(pair), 0);
        factory.claim(recipient, ID, _fees(pair, native), _none(), ENTRY_GAS);

        assertEq(recipient.balance, 0.99 ether);
        assertEq(aero.balanceOf(recipient), 0);
        (uint256 owed0, uint256 owed1) = pair.fees(ID);
        assertEq(owed0, 1e18);
        assertEq(owed1, 2e6);
        _assertNothingLeft();
    }

    function test_claim_acceptsTokensThatReturnNothing() public {
        usdc.setMode(MockToken.Mode.NoReturn);
        _owe(pair, 0, 2e6);

        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.02e6);
    }

    function test_claim_rollsBackATransferThatReturnsFalse() public {
        _owe(pair, 1e18, 2e6);
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none(), ENTRY_GAS);
        usdc.mint(address(operator), 1e6);
        usdc.setMode(MockToken.Mode.ReturnsFalse);

        _expectFailed(address(operator), address(pair), 0);
        operator.claim(ID, _fees(pair), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(operator)), 0);
        assertEq(usdc.balanceOf(address(operator)), 1e6);
    }

    function test_claim_rollsBackWhenTheRecipientRefusesNativeTokens() public {
        address refuser = address(new MockToken());
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(refuser)));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        _expectFailed(address(clone), address(native), 0);
        factory.claim(refuser, ID, _fees(native), _none(), ENTRY_GAS);

        assertEq(address(clone).balance, 0);
        assertEq(feeRecipient.balance, 0);
        assertEq(usdc.balanceOf(refuser), 0);
        (uint256 owed0, uint256 owed1) = native.fees(ID);
        assertEq(owed0, 1 ether);
        assertEq(owed1, 3e6);
    }

    function test_claim_skipsAnUnregisteredManager() public {
        MockRewardsManager rogue = new MockRewardsManager(address(voter), address(aero), address(usdc), address(weth));
        aero.mint(address(operator), 1e18);

        _expectFailed(address(operator), address(rogue), 0);
        _expectFailed(address(operator), address(rogue), 1);
        factory.claim(recipient, ID, _fees(rogue), _incentive(rogue, 1), ENTRY_GAS);

        assertEq(aero.balanceOf(address(operator)), 1e18);
    }

    function test_claim_failsForAStakeWithAnotherOperator() public {
        voter.setOperator(ID, makeAddr("someone else"));
        _owe(pair, 1e18, 2e6);

        _expectFailed(address(operator), address(pair), 0);
        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_onBase_onlyWhileTheRecipientOwnsTheStake() public {
        vm.chainId(BASE);
        _owe(pair, 1e18, 2e6);
        escrow.setOwner(ID, makeAddr("buyer"));

        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);

        escrow.setOwner(ID, recipient);
        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);
        assertEq(aero.balanceOf(recipient), 0.99e18);

        escrow.setOwner(ID, makeAddr("buyer"));
        _owe(pair, 1e18, 2e6);
        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        operator.claim(ID, _fees(pair), _none(), ENTRY_GAS);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_offBase_neverAsksTheEscrow() public {
        vm.etch(address(escrow), "");
        _owe(pair, 1e18, 2e6);

        factory.claim(recipient, ID, _fees(pair), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_claim_cannotBeReentered() public {
        Reenterer reenterer = new Reenterer(factory, false);
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(address(reenterer))));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        factory.claim(address(reenterer), ID, _fees(native), _none(), ENTRY_GAS);

        assertEq(bytes4(reenterer.reason()), ImmutableClaimOperator.Reentrancy.selector);
        assertEq(address(reenterer).balance, 0.99 ether);
        assertEq(usdc.balanceOf(address(reenterer)), 2.97e6);
    }

    function test_claim_rollsBackWhenAReentryBubblesUp() public {
        Reenterer reenterer = new Reenterer(factory, true);
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(address(reenterer))));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        _expectFailed(address(clone), address(native), 0);
        factory.claim(address(reenterer), ID, _fees(native), _none(), ENTRY_GAS);

        assertEq(address(reenterer).balance, 0);
        assertEq(address(clone).balance, 0);
        assertEq(address(native).balance + weth.balanceOf(address(native)), 1 ether);
    }

    function test_claim_aBudgetTooSmall_failsTheEntriesAndKeepsTheRewards() public {
        _owe(pair, 1e18, 2e6);

        _expectFailed(address(operator), address(pair), 0);
        factory.claim(recipient, ID, _fees(pair), _none(), 20_000);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
        _assertNothingLeft();
    }

    function test_claimEntry_onlyFromTheCloneItself() public {
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none(), ENTRY_GAS);
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.NotSelf.selector);
        operator.claimEntry(ID, address(pair), true, 0, 500);
        vm.expectRevert(ImmutableClaimOperator.NotSelf.selector);
        operator.claimEntry(ID, address(pair), false, 1, 500);
    }

    function testFuzz_recipient_isTheOneTheCloneWasMadeFor(address account) public {
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(account)));
        assertEq(address(clone).code.length, 0);

        factory.claim(account, ID, new ILeafVoter.FeeClaim[](0), _none(), ENTRY_GAS);

        assertEq(clone.recipient(), account);
        assertEq(
            address(clone).code,
            abi.encodePacked(
                hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3", account
            )
        );
    }

    function test_recipient_withZeroBytesAtEitherEnd() public {
        address[3] memory accounts = [address(0), address(uint160(0xff)), address(uint160(0xff) << 152)];
        for (uint256 i; i < accounts.length; ++i) {
            factory.claim(accounts[i], ID, new ILeafVoter.FeeClaim[](0), _none(), ENTRY_GAS);
            assertEq(ImmutableClaimOperator(payable(factory.operatorOf(accounts[i]))).recipient(), accounts[i]);
        }
    }

    function test_claimEntry_simulatedFromTheClone_givesTheReason() public {
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none(), ENTRY_GAS);
        MockRewardsManager rogue = new MockRewardsManager(address(voter), address(aero), address(usdc), address(weth));
        _owe(pair, 1e18, 2e6);
        usdc.setBlocked(recipient, true);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NotRegistered.selector, rogue));
        vm.prank(address(operator));
        operator.claimEntry(ID, address(rogue), true, 0, 500);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.TransferFailed.selector, usdc));
        vm.prank(address(operator));
        operator.claimEntry(ID, address(pair), true, 0, 500);

        voter.setOperator(ID, address(0));
        vm.expectRevert(MockLeafVoter.NotAuthorized.selector);
        vm.prank(address(operator));
        operator.claimEntry(ID, address(pair), true, 0, 500);
    }

    function test_aProxyWithoutARecipient_isNotAClone() public {
        address proxy = makeAddr("proxy");
        vm.etch(
            proxy,
            abi.encodePacked(hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3")
        );
        voter.setOperator(ID, proxy);
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        ImmutableClaimOperator(payable(proxy)).recipient();
        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        ImmutableClaimOperator(payable(proxy)).claim(ID, _fees(pair), _none(), ENTRY_GAS);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_withMoreEntryGasThanAnyTransactionHas_reverts() public {
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.InsufficientGas.selector);
        factory.claim(recipient, ID, _fees(pair), _none(), type(uint256).max);
    }

    function test_claim_withAnEntryThatBurnsItsGas_succeedsOnlyWithTheOthersPaid() public {
        MockToken bad = new MockToken();
        MockRewardsManager broken = _manager(address(bad), address(aero));
        _owe(broken, 5e18, 7e18);
        _owe(pair, 1e18, 2e6);
        _owe(native, 1 ether, 0);
        bad.setMode(MockToken.Mode.BurnsGas);
        ILeafVoter.FeeClaim[] memory claims = new ILeafVoter.FeeClaim[](3);
        claims[0] = ILeafVoter.FeeClaim(address(pair), 500);
        claims[1] = ILeafVoter.FeeClaim(address(native), 500);
        claims[2] = ILeafVoter.FeeClaim(address(broken), 500);
        uint256 succeeded;

        for (uint256 gas = 50_000; gas <= 1_500_000; gas += 5_000) {
            uint256 snapshot = vm.snapshotState();
            try factory.claim{gas: gas}(recipient, ID, claims, _none(), 300_000) {
                ++succeeded;
                assertEq(aero.balanceOf(recipient), 0.99e18);
                assertEq(recipient.balance, 0.99 ether);
                assertEq(bad.balanceOf(address(broken)), 5e18);
                _assertNothingLeft();
            } catch (bytes memory err) {
                if (gas > 300_000) assertEq(bytes4(err), ImmutableClaimOperator.InsufficientGas.selector);
            }
            vm.revertToState(snapshot);
        }
        assertGt(succeeded, 0);
    }

    function test_claim_anIncentiveForProgram0_isNotAFeeClaim() public {
        _owe(pair, 1e18, 2e6);

        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(pair), false, 0);
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _incentive(pair, 0), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_skipsAZeroToken() public {
        MockRewardsManager single = _manager(address(aero), address(0));
        MockRewardsManager plain = new MockRewardsManager(address(voter), address(usdc), address(0), address(0));
        registry.register(address(plain));
        aero.mint(address(single), 1e18);
        single.setFees(ID, 1e18, 0);
        usdc.mint(address(plain), 2e6);
        plain.setFees(ID, 2e6, 0);
        vm.deal(address(operator), 1 ether);

        factory.claim(recipient, ID, _fees(single, plain), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(address(operator).balance, 1 ether);
    }

    function testFuzz_claim_paysEverythingOut(uint256 amount0, uint256 amount1, uint256 amountNative) public {
        amount0 = bound(amount0, 0, type(uint128).max);
        amount1 = bound(amount1, 0, type(uint128).max);
        amountNative = bound(amountNative, 0, type(uint96).max);
        _owe(pair, amount0, amount1);
        _owe(native, amountNative, 0);

        factory.claim(recipient, ID, _fees(pair, native), _none(), ENTRY_GAS);

        assertEq(aero.balanceOf(feeRecipient), amount0 / 100);
        assertEq(aero.balanceOf(recipient), amount0 - amount0 / 100);
        assertEq(usdc.balanceOf(feeRecipient), amount1 / 100);
        assertEq(usdc.balanceOf(recipient), amount1 - amount1 / 100);
        assertEq(feeRecipient.balance, amountNative / 100);
        assertEq(recipient.balance, amountNative - amountNative / 100);
        _assertNothingLeft();
    }
}
