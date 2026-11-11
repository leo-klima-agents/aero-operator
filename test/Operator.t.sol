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
    MockToken,
    MockVotingEscrow,
    MockWrappedNative
} from "./mocks/Mocks.sol";

contract Reenterer {
    ImmutableClaimOperatorFactory internal immutable FACTORY;
    bool internal immutable BUBBLE;
    bytes public reason;

    constructor(ImmutableClaimOperatorFactory factory, bool bubble) {
        FACTORY = factory;
        BUBBLE = bubble;
    }

    receive() external payable {
        try FACTORY.claim(address(this), 1, new ILeafVoter.FeeClaim[](0), new ILeafVoter.IncentiveClaim[](0)) {}
        catch (bytes memory err) {
            reason = err;
            if (BUBBLE) revert("reentered");
        }
    }
}

contract OperatorTest is Test {
    uint256 internal constant BASE = 8453;
    uint256 internal constant ID = 1;
    address internal constant FEE_RECIPIENT = 0x450c72de8c0079B49AcedF294a13011bd09D125B;

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

    event Claimed(uint256 indexed tokenId, address indexed token, uint256 amount, uint256 fee);
    event ClaimFailed(uint256 indexed tokenId, address indexed votingRewardsManager, uint256 programId);

    function setUp() public {
        registry = new MockFactoryRegistry();
        voter = new MockLeafVoter(address(registry));
        escrow = new MockVotingEscrow();
        weth = new MockWrappedNative();
        usdc = new MockToken();
        aero = new MockToken();
        pair = _manager(address(aero), address(usdc));
        native = _manager(address(weth), address(usdc));

        factory = new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, FEE_RECIPIENT);
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

    function test_constants() public view {
        ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));
        assertEq(implementation.FEE_BPS(), 100);
        assertEq(implementation.leafVoter(), address(voter));
        assertEq(implementation.escrow(), address(escrow));
        assertEq(implementation.baseChainId(), BASE);
        assertEq(implementation.feeRecipient(), FEE_RECIPIENT);
        assertEq(address(implementation), vm.computeCreateAddress(address(factory), 1));
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(ImmutableClaimOperator.ZeroAddress.selector);
        new ImmutableClaimOperator(address(0), address(escrow), BASE, FEE_RECIPIENT);
        vm.expectRevert(ImmutableClaimOperator.ZeroAddress.selector);
        new ImmutableClaimOperator(address(voter), address(0), BASE, FEE_RECIPIENT);
        vm.expectRevert(ImmutableClaimOperator.ZeroAddress.selector);
        new ImmutableClaimOperator(address(voter), address(escrow), BASE, address(0));
        vm.expectRevert(ImmutableClaimOperator.ZeroAddress.selector);
        new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, address(0));
    }

    function test_firstClaim_deploysTheCloneAtThePredictedAddress() public {
        assertEq(address(operator).code.length, 0);
        _owe(pair, 1e18, 1e6);

        factory.claim(recipient, ID, _fees(pair), _none());

        assertEq(
            address(operator).code,
            abi.encodePacked(
                hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3", recipient
            )
        );
        assertEq(operator.recipient(), recipient);
        assertEq(operator.leafVoter(), address(voter));
        assertEq(operator.feeRecipient(), FEE_RECIPIENT);
        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_operatorOf_dependsOnTheRecipient() public {
        address other = makeAddr("other");
        assertNotEq(factory.operatorOf(other), address(operator));
        factory.claim(other, ID, new ILeafVoter.FeeClaim[](0), _none());
        assertEq(ImmutableClaimOperator(payable(factory.operatorOf(other))).recipient(), other);
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
        factory.claim(recipient, ID, _fees(pair, native), _none());

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(aero.balanceOf(FEE_RECIPIENT), 0.01e18);
        assertEq(usdc.balanceOf(recipient), 6.93e6);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 0.07e6);
        assertEq(recipient.balance, 2.97 ether);
        assertEq(FEE_RECIPIENT.balance, 0.03 ether);
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
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), claims);

        assertEq(usdc.balanceOf(recipient), 99e6);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 1e6);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(FEE_RECIPIENT.balance, 0.01 ether);
        _assertNothingLeft();
    }

    function test_claim_onTheCloneItself_onceDeployed() public {
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none());
        _owe(pair, 1e18, 0);

        vm.prank(makeAddr("anyone"));
        operator.claim(ID, _fees(pair), _none());

        assertEq(aero.balanceOf(recipient), 0.99e18);
        _assertNothingLeft();
    }

    function test_claim_takesNoFeeOnDust() public {
        _owe(pair, 99, 100);

        factory.claim(recipient, ID, _fees(pair), _none());

        assertEq(aero.balanceOf(recipient), 99);
        assertEq(aero.balanceOf(FEE_RECIPIENT), 0);
        assertEq(usdc.balanceOf(recipient), 99);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 1);
    }

    function test_claim_forwardsTokensSentToTheClone() public {
        usdc.mint(address(operator), 10e6);
        vm.deal(address(operator), 1 ether);
        _owe(native, 1 ether, 0);

        factory.claim(recipient, ID, _fees(native), _none());

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
        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(broken), 0);
        factory.claim(recipient, ID, claims, _none());

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(recipient.balance, 0.99 ether);
        (uint256 owed0, uint256 owed1) = broken.fees(ID);
        assertEq(owed0, 5e18);
        assertEq(owed1, 7e18);
        assertEq(bad.balanceOf(address(broken)), 5e18);
        assertEq(aero.balanceOf(address(broken)), 7e18);
        assertEq(bad.balanceOf(FEE_RECIPIENT), 0);
        assertEq(bad.balanceOf(address(operator)), 0);
        _assertNothingLeft();

        bad.setBlocked(recipient, false);
        factory.claim(recipient, ID, claims, _none());
        assertEq(bad.balanceOf(recipient), 4.95e18);
        assertEq(aero.balanceOf(recipient), 0.99e18 + 6.93e18);
    }

    function test_claim_aManagerThatRevertsDoesNotBlockTheOthers() public {
        _owe(pair, 1e18, 2e6);
        _owe(native, 1 ether, 0);
        usdc.setBlocked(address(operator), true);

        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(pair), 0);
        factory.claim(recipient, ID, _fees(pair, native), _none());

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

        factory.claim(recipient, ID, _fees(pair), _none());

        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), 0.02e6);
    }

    function test_claim_rollsBackATransferThatReturnsFalse() public {
        _owe(pair, 1e18, 2e6);
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none());
        usdc.mint(address(operator), 1e6);
        usdc.setMode(MockToken.Mode.ReturnsFalse);

        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(pair), 0);
        operator.claim(ID, _fees(pair), _none());

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(operator)), 0);
        assertEq(usdc.balanceOf(address(operator)), 1e6);
    }

    function test_claim_rollsBackWhenTheRecipientRefusesNativeTokens() public {
        address refuser = address(new MockToken());
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(refuser)));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        vm.expectEmit(address(clone));
        emit ClaimFailed(ID, address(native), 0);
        factory.claim(refuser, ID, _fees(native), _none());

        assertEq(address(clone).balance, 0);
        assertEq(FEE_RECIPIENT.balance, 0);
        assertEq(usdc.balanceOf(refuser), 0);
        (uint256 owed0, uint256 owed1) = native.fees(ID);
        assertEq(owed0, 1 ether);
        assertEq(owed1, 3e6);
    }

    function test_claim_skipsAnUnregisteredManager() public {
        MockRewardsManager rogue = new MockRewardsManager(address(voter), address(aero), address(usdc), address(weth));
        aero.mint(address(operator), 1e18);

        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(rogue), 0);
        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(rogue), 1);
        factory.claim(recipient, ID, _fees(rogue), _incentive(rogue, 1));

        assertEq(aero.balanceOf(address(operator)), 1e18);
    }

    function test_claim_failsForAStakeWithAnotherOperator() public {
        voter.setOperator(ID, makeAddr("someone else"));
        _owe(pair, 1e18, 2e6);

        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(pair), 0);
        factory.claim(recipient, ID, _fees(pair), _none());

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_failsForAnUnknownProgram() public {
        vm.expectEmit(address(operator));
        emit ClaimFailed(ID, address(pair), 7);
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _incentive(pair, 7));
    }

    function test_claim_onBase_onlyWhileTheRecipientOwnsTheStake() public {
        vm.chainId(BASE);
        _owe(pair, 1e18, 2e6);
        escrow.setOwner(ID, makeAddr("buyer"));

        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, ID, _fees(pair), _none());

        escrow.setOwner(ID, recipient);
        factory.claim(recipient, ID, _fees(pair), _none());
        assertEq(aero.balanceOf(recipient), 0.99e18);

        escrow.setOwner(ID, makeAddr("buyer"));
        _owe(pair, 1e18, 2e6);
        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        operator.claim(ID, _fees(pair), _none());
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_offBase_neverAsksTheEscrow() public {
        vm.etch(address(escrow), "");
        _owe(pair, 1e18, 2e6);

        factory.claim(recipient, ID, _fees(pair), _none());

        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_claim_cannotBeReentered() public {
        Reenterer reenterer = new Reenterer(factory, false);
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(address(reenterer))));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        factory.claim(address(reenterer), ID, _fees(native), _none());

        assertEq(bytes4(reenterer.reason()), ImmutableClaimOperator.Reentrancy.selector);
        assertEq(address(reenterer).balance, 0.99 ether);
        assertEq(usdc.balanceOf(address(reenterer)), 2.97e6);
    }

    function test_claim_rollsBackWhenAReentryBubblesUp() public {
        Reenterer reenterer = new Reenterer(factory, true);
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(address(reenterer))));
        voter.setOperator(ID, address(clone));
        _owe(native, 1 ether, 3e6);

        vm.expectEmit(address(clone));
        emit ClaimFailed(ID, address(native), 0);
        factory.claim(address(reenterer), ID, _fees(native), _none());

        assertEq(address(reenterer).balance, 0);
        assertEq(address(clone).balance, 0);
        assertEq(address(native).balance + weth.balanceOf(address(native)), 1 ether);
    }

    function test_claimFeesAndIncentives_onlyFromTheCloneItself() public {
        factory.claim(recipient, ID, new ILeafVoter.FeeClaim[](0), _none());
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.NotSelf.selector);
        operator.claimFees(ID, ILeafVoter.FeeClaim(address(pair), 500));
        vm.expectRevert(ImmutableClaimOperator.NotSelf.selector);
        operator.claimIncentives(ID, ILeafVoter.IncentiveClaim(address(pair), 1, 500));
    }

    function testFuzz_claim_paysEverythingOut(uint256 amount0, uint256 amount1, uint256 amountNative) public {
        amount0 = bound(amount0, 0, type(uint128).max);
        amount1 = bound(amount1, 0, type(uint128).max);
        amountNative = bound(amountNative, 0, type(uint96).max);
        _owe(pair, amount0, amount1);
        _owe(native, amountNative, 0);

        factory.claim(recipient, ID, _fees(pair, native), _none());

        assertEq(aero.balanceOf(FEE_RECIPIENT), amount0 / 100);
        assertEq(aero.balanceOf(recipient), amount0 - amount0 / 100);
        assertEq(usdc.balanceOf(FEE_RECIPIENT), amount1 / 100);
        assertEq(usdc.balanceOf(recipient), amount1 - amount1 / 100);
        assertEq(FEE_RECIPIENT.balance, amountNative / 100);
        assertEq(recipient.balance, amountNative - amountNative / 100);
        _assertNothingLeft();
    }
}
