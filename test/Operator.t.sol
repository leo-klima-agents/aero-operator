// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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

contract Reenterer {
    address internal immutable target;
    bytes internal reentry;
    bytes public reason;

    constructor(address target_, bytes memory reentry_) {
        target = target_;
        reentry = reentry_;
    }

    receive() external payable {
        (, reason) = target.call(reentry);
    }
}

contract OperatorTest is Test {
    uint256 internal constant BASE = 8453;
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant MAX_CHECKPOINTS = 500;
    uint256 internal constant ENTRY_GAS = 1_000_000;
    uint256 internal constant MANAGER_WORK = 1_300_000;
    uint256 internal constant RESERVED_GAS = 20_000;
    uint256 internal constant USED_BY_THE_FACTORY = 4406;
    uint256 internal constant USED_TO_DEPLOY_A_CLONE = 45_079;
    uint256 internal constant USED_BY_THE_PROXY = 2624;
    uint256 internal constant USED_BEFORE_ONE_FEE_ENTRY = 3923;

    MockFactoryRegistry internal registry;
    MockLeafVoter internal voter;
    MockVotingEscrow internal escrow;
    MockWrappedNative internal weth;
    MockToken internal usdc;
    MockToken internal aero;
    MockRewardsManager internal pair;
    MockRewardsManager internal wethPair;

    ImmutableClaimOperatorFactory internal factory;
    ImmutableClaimOperator internal operator;
    address internal recipient = makeAddr("recipient");
    address internal feeRecipient;

    function setUp() public {
        feeRecipient = address(new MockSafe());
        registry = new MockFactoryRegistry();
        voter = new MockLeafVoter(address(registry));
        escrow = new MockVotingEscrow();
        weth = new MockWrappedNative();
        usdc = new MockToken();
        aero = new MockToken();
        pair = _manager(address(aero), address(usdc));
        wethPair = _manager(address(weth), address(usdc));

        factory = new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, feeRecipient);
        operator = ImmutableClaimOperator(payable(factory.operatorOf(recipient)));
        voter.setOperator(TOKEN_ID, address(operator));
    }

    function _manager(address token0, address token1) internal returns (MockRewardsManager manager) {
        manager = new MockRewardsManager(token0, token1, address(weth));
        registry.register(address(manager));
    }

    function _owe(MockRewardsManager manager, uint256 amount0, uint256 amount1) internal {
        _fund(manager, manager.token0(), amount0);
        _fund(manager, manager.token1(), amount1);
        manager.setFees(TOKEN_ID, amount0, amount1);
    }

    function _oweIncentive(MockRewardsManager manager, address token, uint256 amount)
        internal
        returns (uint256 programId)
    {
        programId = manager.addIncentive(token);
        _fund(manager, token, amount);
        manager.setIncentive(TOKEN_ID, programId, amount);
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
        claims[0] = ILeafVoter.FeeClaim(address(a), MAX_CHECKPOINTS);
    }

    function _fees(MockRewardsManager a, MockRewardsManager b)
        internal
        pure
        returns (ILeafVoter.FeeClaim[] memory claims)
    {
        claims = new ILeafVoter.FeeClaim[](2);
        claims[0] = ILeafVoter.FeeClaim(address(a), MAX_CHECKPOINTS);
        claims[1] = ILeafVoter.FeeClaim(address(b), MAX_CHECKPOINTS);
    }

    function _gasToHoldToPassOn(uint256 gas) internal pure returns (uint256) {
        return gas + (gas - 1) / 63;
    }

    function _reenterer(bytes memory reentry) internal returns (Reenterer reenterer, ImmutableClaimOperator clone) {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        clone = ImmutableClaimOperator(payable(factory.operatorOf(next)));
        reenterer = new Reenterer(address(clone), reentry);
        voter.setOperator(TOKEN_ID, address(clone));
    }

    function _reentries() internal pure returns (bytes[2] memory) {
        return [
            abi.encodeCall(
                ImmutableClaimOperator.claim, (TOKEN_ID, new ILeafVoter.FeeClaim[](0), _noIncentives(), ENTRY_GAS)
            ),
            abi.encodeCall(ImmutableClaimOperator.sweep, (address(0)))
        ];
    }

    function _leastGas(address target, bytes memory data) internal returns (uint256 goesThrough) {
        uint256 reverts = 0;
        goesThrough = 30_000_000;
        while (goesThrough - reverts > 1) {
            uint256 halfway = (reverts + goesThrough) / 2;
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = target.call{gas: halfway}(data);
            vm.revertToState(snapshot);
            if (ok) goesThrough = halfway;
            else reverts = halfway;
        }
    }

    function _incentive(MockRewardsManager a, uint256 programId)
        internal
        pure
        returns (ILeafVoter.IncentiveClaim[] memory claims)
    {
        claims = new ILeafVoter.IncentiveClaim[](1);
        claims[0] = ILeafVoter.IncentiveClaim(address(a), programId, MAX_CHECKPOINTS);
    }

    function _expectFailed(address emitter, address manager, bool fees, uint256 programId) internal {
        vm.expectEmit(emitter);
        emit ImmutableClaimOperator.ClaimFailed(TOKEN_ID, manager, fees, programId);
    }

    function _deployClone(address account) internal {
        factory.claim(account, TOKEN_ID, new ILeafVoter.FeeClaim[](0), _noIncentives(), ENTRY_GAS);
    }

    function _noIncentives() internal pure returns (ILeafVoter.IncentiveClaim[] memory) {
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

    function claimTwice() external {
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
    }

    function _paid() internal view returns (bool) {
        return aero.balanceOf(recipient) + usdc.balanceOf(recipient) != 0;
    }

    function _assertGoesThroughOnlyIfTheEntryGotItsGas(
        ILeafVoter.FeeClaim[] memory fees,
        ILeafVoter.IncentiveClaim[] memory incentives
    ) internal returns (uint256 entryGas) {
        uint256 tooLittle = 0;
        entryGas = 3_000_000;
        while (entryGas - tooLittle > 1) {
            uint256 halfway = (tooLittle + entryGas) / 2;
            uint256 snapshot = vm.snapshotState();
            factory.claim(recipient, TOKEN_ID, fees, incentives, halfway);
            if (_paid()) entryGas = halfway;
            else tooLittle = halfway;
            vm.revertToState(snapshot);
        }
        bytes memory data = abi.encodeCall(factory.claim, (recipient, TOKEN_ID, fees, incentives, entryGas));
        uint256 leastGas = _leastGas(address(factory), data);

        for (uint256 gas = leastGas - 50; gas < leastGas + 100; ++gas) {
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = address(factory).call{gas: gas}(data);
            assertEq(ok, gas >= leastGas);
            assertEq(_paid(), ok);
            vm.revertToState(snapshot);
        }
    }

    function test_constructor_needsTheFeeSafeToHaveCode() public {
        address none = makeAddr("none");
        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NoCode.selector, none));
        new ImmutableClaimOperator(address(voter), address(escrow), BASE, none);
        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NoCode.selector, none));
        new ImmutableClaimOperatorFactory(address(voter), address(escrow), BASE, none);
    }

    function test_implementation_isNotAClone() public {
        ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));

        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        implementation.recipient();
        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        implementation.claim(TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        implementation.sweep(address(usdc));
    }

    function test_proxyWithoutARecipient_isNotAClone() public {
        address proxy = makeAddr("proxy");
        vm.etch(
            proxy,
            abi.encodePacked(hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3")
        );

        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        ImmutableClaimOperator(payable(proxy)).recipient();
        vm.expectRevert(ImmutableClaimOperator.NotClone.selector);
        ImmutableClaimOperator(payable(proxy)).claim(TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
    }

    function testFuzz_recipient_isTheOneTheCloneWasMadeFor(address account) public {
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(account)));
        assertEq(address(clone).code.length, 0);

        _deployClone(account);

        bytes memory code = abi.encodePacked(
            hex"363d3d373d3d3d363d73", factory.implementation(), hex"5af43d82803e903d91602b57fd5bf3", account
        );
        bytes32 initCodeHash = keccak256(bytes.concat(hex"6100413d81600a3d39f3", code));
        assertEq(address(clone), vm.computeCreate2Address(bytes32(0), initCodeHash, address(factory)));
        assertEq(address(clone).code, code);
        assertEq(clone.recipient(), account);
    }

    function test_recipient_withZeroBytesAtEitherEnd() public {
        address[3] memory accounts = [address(0), address(uint160(0xff)), address(uint160(0xff) << 152)];
        for (uint256 i; i < accounts.length; ++i) {
            _deployClone(accounts[i]);
            assertEq(ImmutableClaimOperator(payable(factory.operatorOf(accounts[i]))).recipient(), accounts[i]);
        }
    }

    function test_claim_splitsTokensAndNativeBetweenRecipientAndFee() public {
        _owe(pair, 1e18, 2e6);
        _owe(wethPair, 3 ether, 5e6);

        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(aero), 1e18, 0.01e18, 0);
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(usdc), 2e6, 0.02e6, block.number);
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(0), 3 ether, 0.03 ether, block.number);
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(usdc), 5e6, 0.05e6, block.number);
        factory.claim(recipient, TOKEN_ID, _fees(pair, wethPair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(aero.balanceOf(feeRecipient), 0.01e18);
        assertEq(usdc.balanceOf(recipient), 6.93e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.07e6);
        assertEq(recipient.balance, 2.97 ether);
        assertEq(feeRecipient.balance, 0.03 ether);
        assertEq(pair.lastMaxCheckpoints(), MAX_CHECKPOINTS);
        _assertNothingLeft();
    }

    function test_claim_splitsIncentivesBetweenRecipientAndFee() public {
        uint256 programId = _oweIncentive(pair, address(usdc), 100e6);
        uint256 nativeId = _oweIncentive(pair, address(weth), 1 ether);

        ILeafVoter.IncentiveClaim[] memory claims = new ILeafVoter.IncentiveClaim[](2);
        claims[0] = ILeafVoter.IncentiveClaim(address(pair), programId, MAX_CHECKPOINTS);
        claims[1] = ILeafVoter.IncentiveClaim(address(pair), nativeId, 77);
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(usdc), 100e6, 1e6, 0);
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(0), 1 ether, 0.01 ether, block.number);
        factory.claim(recipient, TOKEN_ID, new ILeafVoter.FeeClaim[](0), claims, ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 99e6);
        assertEq(usdc.balanceOf(feeRecipient), 1e6);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(feeRecipient.balance, 0.01 ether);
        assertEq(pair.lastMaxCheckpoints(), 77);
        _assertNothingLeft();
    }

    function test_claim_takesNoFeeOnDust() public {
        _owe(pair, 99, 100);

        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 99);
        assertEq(aero.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(recipient), 99);
        assertEq(usdc.balanceOf(feeRecipient), 1);
    }

    function test_claim_leavesWhatTheCloneHeldBefore() public {
        usdc.mint(address(operator), 10e6);
        vm.deal(address(operator), 1 ether);
        _owe(wethPair, 1 ether, 2e6);

        factory.claim(recipient, TOKEN_ID, _fees(wethPair), _noIncentives(), ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(usdc.balanceOf(address(operator)), 10e6);
        assertEq(address(operator).balance, 1 ether);
    }

    function test_claim_aTokenThatRevertsDoesNotBlockTheOthers() public {
        MockToken bad = new MockToken();
        MockRewardsManager broken = _manager(address(bad), address(aero));
        _owe(broken, 5e18, 7e18);
        _owe(pair, 1e18, 2e6);
        _owe(wethPair, 1 ether, 0);
        bad.setBlocked(recipient, true);

        ILeafVoter.FeeClaim[] memory claims = new ILeafVoter.FeeClaim[](3);
        claims[0] = ILeafVoter.FeeClaim(address(pair), MAX_CHECKPOINTS);
        claims[1] = ILeafVoter.FeeClaim(address(broken), MAX_CHECKPOINTS);
        claims[2] = ILeafVoter.FeeClaim(address(wethPair), MAX_CHECKPOINTS);
        _expectFailed(address(operator), address(broken), true, 0);
        factory.claim(recipient, TOKEN_ID, claims, _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(recipient.balance, 0.99 ether);
        (uint256 owed0, uint256 owed1) = broken.fees(TOKEN_ID);
        assertEq(owed0, 5e18);
        assertEq(owed1, 7e18);
        assertEq(bad.balanceOf(address(broken)), 5e18);
        assertEq(aero.balanceOf(address(broken)), 7e18);
        assertEq(bad.balanceOf(feeRecipient), 0);
        assertEq(bad.balanceOf(address(operator)), 0);
        _assertNothingLeft();

        bad.setBlocked(recipient, false);
        factory.claim(recipient, TOKEN_ID, claims, _noIncentives(), ENTRY_GAS);
        assertEq(bad.balanceOf(recipient), 4.95e18);
        assertEq(aero.balanceOf(recipient), 0.99e18 + 6.93e18);
    }

    function test_claim_acceptsTokensThatReturnNothing() public {
        usdc.setMode(MockToken.Mode.NoReturn);
        _owe(pair, 0, 2e6);

        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.02e6);
    }

    function test_claim_rollsBackWhenTheRecipientRefusesNativeTokens() public {
        address refuser = address(new MockToken());
        ImmutableClaimOperator clone = ImmutableClaimOperator(payable(factory.operatorOf(refuser)));
        voter.setOperator(TOKEN_ID, address(clone));
        _owe(wethPair, 1 ether, 3e6);

        _expectFailed(address(clone), address(wethPair), true, 0);
        factory.claim(refuser, TOKEN_ID, _fees(wethPair), _noIncentives(), ENTRY_GAS);

        assertEq(address(clone).balance, 0);
        assertEq(feeRecipient.balance, 0);
        assertEq(usdc.balanceOf(refuser), 0);
        (uint256 owed0, uint256 owed1) = wethPair.fees(TOKEN_ID);
        assertEq(owed0, 1 ether);
        assertEq(owed1, 3e6);
    }

    function test_claim_failsAnUnregisteredManager() public {
        MockRewardsManager rogue = new MockRewardsManager(address(aero), address(usdc), address(weth));
        aero.mint(address(operator), 1e18);

        _expectFailed(address(operator), address(rogue), true, 0);
        _expectFailed(address(operator), address(rogue), false, 1);
        factory.claim(recipient, TOKEN_ID, _fees(rogue), _incentive(rogue, 1), ENTRY_GAS);

        assertEq(aero.balanceOf(address(operator)), 1e18);
    }

    function test_claim_failsForAStakeWithAnotherOperator() public {
        voter.setOperator(TOKEN_ID, makeAddr("someone else"));
        _owe(pair, 1e18, 2e6);

        _expectFailed(address(operator), address(pair), true, 0);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_onBase_onlyWhileTheRecipientOwnsTheStake() public {
        vm.chainId(BASE);
        _owe(pair, 1e18, 2e6);
        escrow.setOwner(TOKEN_ID, makeAddr("buyer"));

        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        escrow.setOwner(TOKEN_ID, recipient);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_claim_offBase_neverAsksTheEscrow() public {
        vm.etch(address(escrow), "");
        _owe(pair, 1e18, 2e6);

        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_claim_cannotBeReentered() public {
        bytes[2] memory reentries = _reentries();
        for (uint256 i; i < reentries.length; ++i) {
            (Reenterer reenterer,) = _reenterer(reentries[i]);
            _owe(wethPair, 1 ether, 0);
            uint256 programId = _oweIncentive(wethPair, address(weth), 1 ether);

            factory.claim(address(reenterer), TOKEN_ID, _fees(wethPair), _incentive(wethPair, programId), ENTRY_GAS);

            assertEq(bytes4(reenterer.reason()), ImmutableClaimOperator.Reentrancy.selector);
            assertEq(address(reenterer).balance, 1.98 ether);
        }
    }

    function test_claim_rollsBackWhenTheFeeCannotBePaid() public {
        usdc.setBlocked(feeRecipient, true);
        _owe(pair, 1e18, 2e6);

        _expectFailed(address(operator), address(pair), true, 0);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(usdc.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
        _assertNothingLeft();
    }

    function test_claim_pointsEachPaymentToTheBlockOfTheOneBefore() public {
        vm.roll(100);
        _owe(wethPair, 1 ether, 0);
        factory.claim(recipient, TOKEN_ID, _fees(wethPair), _noIncentives(), ENTRY_GAS);
        assertEq(operator.lastClaimBlock(), 100);

        vm.roll(107);
        usdc.mint(address(operator), 1);
        vm.deal(address(operator), 1);
        factory.claim(recipient, TOKEN_ID, _fees(wethPair), _noIncentives(), ENTRY_GAS);
        operator.sweep(address(usdc));
        operator.sweep(address(0));
        _owe(pair, 0, 2e6);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), 10_000);
        assertEq(operator.lastClaimBlock(), 100);

        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(usdc), 2e6, 0.02e6, 100);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
        assertEq(operator.lastClaimBlock(), 107);
    }

    function test_claim_pointsToTheChainsOwnBlockWhereArbSysIs() public {
        vm.etch(address(100), hex"fe");
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(523_926_782));
        _owe(pair, 1e18, 0);

        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(operator.lastClaimBlock(), 523_926_782);
    }

    function test_claim_pointsToBlockNumberWhereArbSysDoesNotAnswer() public {
        bytes[3] memory codes = [bytes(""), hex"00", hex"60006000fd"];
        for (uint256 i; i < codes.length; ++i) {
            vm.etch(address(100), codes[i]);
            vm.roll(200 + i);
            _owe(pair, 1e18, 0);

            factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

            assertEq(operator.lastClaimBlock(), 200 + i);
        }
        assertEq(aero.balanceOf(recipient), 2.97e18);
    }

    function test_claim_givesEveryEntryItsGas() public {
        pair.setWork(MANAGER_WORK);
        wethPair.setWork(MANAGER_WORK);
        _owe(pair, 1e18, 0);
        _owe(wethPair, 1 ether, 0);
        ILeafVoter.IncentiveClaim[] memory incentives = new ILeafVoter.IncentiveClaim[](2);
        incentives[0] =
            ILeafVoter.IncentiveClaim(address(pair), _oweIncentive(pair, address(usdc), 2e6), MAX_CHECKPOINTS);
        incentives[1] =
            ILeafVoter.IncentiveClaim(address(wethPair), _oweIncentive(wethPair, address(usdc), 3e6), MAX_CHECKPOINTS);

        factory.claim(recipient, TOKEN_ID, _fees(pair, wethPair), incentives, MANAGER_WORK + 300_000);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(usdc.balanceOf(recipient), 4.95e6);
    }

    function test_claim_emitsNothingForATokenThatPaidNothing() public {
        _owe(pair, 1e18, 0);

        vm.recordLogs();
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);

        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_claim_withLessThanTheReserveLeft_revertsWithInsufficientGas() public {
        _deployClone(recipient);

        vm.expectRevert(ImmutableClaimOperator.InsufficientGas.selector);
        operator.claim{gas: 15_000}(TOKEN_ID, _fees(pair), _noIncentives(), 1);
    }

    function test_claim_withTooLittleEntryGas_failsTheEntryAndKeepsTheRewards() public {
        _owe(pair, 1e18, 2e6);

        _expectFailed(address(operator), address(pair), true, 0);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), 10_000);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
        _assertNothingLeft();
    }

    function test_claim_twiceInOneTransaction() public {
        _owe(pair, 1e18, 2e6);

        this.claimTwice();

        assertEq(aero.balanceOf(recipient), 0.99e18);
    }

    function test_claim_revertsIfTheCloneCannotBeDeployed() public {
        vm.setNonce(address(operator), 1);

        vm.expectRevert(bytes(""));
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
    }

    function test_claim_leastGasFollowsTheFormula() public {
        _owe(pair, 1e18, 2e6);
        uint256[5] memory budgets = [uint256(300_000), 630_000, 1_000_000, 2_345_678, 5_000_000];
        uint256 beforeTheClone = vm.snapshotState();

        for (uint256 i; i < budgets.length; ++i) {
            bytes memory toClone =
                abi.encodeCall(ImmutableClaimOperator.claim, (TOKEN_ID, _fees(pair), _noIncentives(), budgets[i]));
            bytes memory toFactory =
                abi.encodeCall(factory.claim, (recipient, TOKEN_ID, _fees(pair), _noIncentives(), budgets[i]));
            uint256 words = (toClone.length + 31) / 32;
            uint256 forClone = USED_BY_THE_PROXY + 6 * words + words * words / 512
                + _gasToHoldToPassOn(USED_BEFORE_ONE_FEE_ENTRY + RESERVED_GAS + _gasToHoldToPassOn(budgets[i]));
            uint256 forFactory = USED_BY_THE_FACTORY + _gasToHoldToPassOn(forClone);

            assertEq(_leastGas(address(factory), toFactory), forFactory + USED_TO_DEPLOY_A_CLONE);
            _deployClone(recipient);
            assertEq(_leastGas(address(operator), toClone), forClone);
            assertEq(_leastGas(address(factory), toFactory), forFactory);
            vm.revertToState(beforeTheClone);
        }
    }

    function test_claim_goesThroughOnlyIfTheEntryGotItsGas() public {
        _deployClone(recipient);
        _owe(pair, 1e18, 0);
        uint256 programId = _oweIncentive(pair, address(usdc), 2e6);
        pair.setWork(MANAGER_WORK);

        uint256 forFees = _assertGoesThroughOnlyIfTheEntryGotItsGas(_fees(pair), _noIncentives());
        uint256 forAnIncentive =
            _assertGoesThroughOnlyIfTheEntryGotItsGas(new ILeafVoter.FeeClaim[](0), _incentive(pair, programId));

        assertGt(forFees, MANAGER_WORK);
        assertGt(forAnIncentive, MANAGER_WORK);
    }

    function test_claim_withMoreEntryGasThanAnyTransactionHas_reverts() public {
        _owe(pair, 1e18, 2e6);

        vm.expectRevert(ImmutableClaimOperator.InsufficientGas.selector);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), type(uint256).max);
    }

    function test_claim_withAnEntryThatBurnsItsGas_succeedsOnlyWithTheOthersPaid() public {
        MockToken bad = new MockToken();
        MockRewardsManager broken = _manager(address(bad), address(aero));
        _owe(broken, 5e18, 7e18);
        _owe(pair, 1e18, 2e6);
        _owe(wethPair, 1 ether, 0);
        bad.setMode(MockToken.Mode.BurnsGas);
        ILeafVoter.FeeClaim[] memory claims = new ILeafVoter.FeeClaim[](3);
        claims[0] = ILeafVoter.FeeClaim(address(broken), MAX_CHECKPOINTS);
        claims[1] = ILeafVoter.FeeClaim(address(pair), MAX_CHECKPOINTS);
        claims[2] = ILeafVoter.FeeClaim(address(wethPair), MAX_CHECKPOINTS);
        uint256 succeeded;

        for (uint256 gas = 50_000; gas <= 1_500_000; gas += 5_000) {
            uint256 snapshot = vm.snapshotState();
            try factory.claim{gas: gas}(recipient, TOKEN_ID, claims, _noIncentives(), 300_000) {
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

        _expectFailed(address(operator), address(pair), false, 0);
        factory.claim(recipient, TOKEN_ID, new ILeafVoter.FeeClaim[](0), _incentive(pair, 0), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0);
        assertEq(aero.balanceOf(address(pair)), 1e18);
    }

    function test_claim_leavesWhatAManagerPaysWithoutNamingIt() public {
        MockRewardsManager single = _manager(address(aero), address(0));
        MockRewardsManager plain = new MockRewardsManager(address(usdc), address(0), address(0));
        registry.register(address(plain));
        aero.mint(address(single), 1e18);
        single.setFees(TOKEN_ID, 1e18, 0);
        vm.deal(address(single), 5);
        single.setTip(5);
        usdc.mint(address(plain), 2e6);
        plain.setFees(TOKEN_ID, 2e6, 0);
        vm.deal(address(operator), 1 ether);

        factory.claim(recipient, TOKEN_ID, _fees(single, plain), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 0.99e18);
        assertEq(usdc.balanceOf(recipient), 1.98e6);
        assertEq(recipient.balance, 0);
        assertEq(address(operator).balance, 1 ether + 5);
    }

    function test_claim_paysOnceWhenBothTokensAreTheSame() public {
        MockRewardsManager same = _manager(address(aero), address(aero));
        _owe(same, 1e18, 2e18);

        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Claimed(TOKEN_ID, address(aero), 3e18, 0.03e18, 0);
        factory.claim(recipient, TOKEN_ID, _fees(same), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(recipient), 2.97e18);
        _assertNothingLeft();
    }

    function testFuzz_claim_paysEverythingOut(uint256 amount0, uint256 amount1, uint256 amountNative) public {
        amount0 = bound(amount0, 0, type(uint128).max);
        amount1 = bound(amount1, 0, type(uint128).max);
        amountNative = bound(amountNative, 0, type(uint96).max);
        _owe(pair, amount0, amount1);
        _owe(wethPair, amountNative, 0);

        factory.claim(recipient, TOKEN_ID, _fees(pair, wethPair), _noIncentives(), ENTRY_GAS);

        assertEq(aero.balanceOf(feeRecipient), amount0 / 100);
        assertEq(aero.balanceOf(recipient), amount0 - amount0 / 100);
        assertEq(usdc.balanceOf(feeRecipient), amount1 / 100);
        assertEq(usdc.balanceOf(recipient), amount1 - amount1 / 100);
        assertEq(feeRecipient.balance, amountNative / 100);
        assertEq(recipient.balance, amountNative - amountNative / 100);
        _assertNothingLeft();
    }

    function test_claimEntry_onlyFromTheCloneItself() public {
        _deployClone(recipient);

        vm.expectRevert(ImmutableClaimOperator.NotSelf.selector);
        operator.claimEntry(TOKEN_ID, address(pair), true, 0, MAX_CHECKPOINTS);
    }

    function test_claimEntry_simulatedFromTheClone_givesTheReason() public {
        _deployClone(recipient);
        MockRewardsManager rogue = new MockRewardsManager(address(aero), address(usdc), address(weth));
        _owe(pair, 1e18, 2e6);
        usdc.setBlocked(recipient, true);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.NotRegistered.selector, rogue));
        vm.prank(address(operator));
        operator.claimEntry(TOKEN_ID, address(rogue), true, 0, MAX_CHECKPOINTS);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.TransferFailed.selector, usdc));
        vm.prank(address(operator));
        operator.claimEntry(TOKEN_ID, address(pair), true, 0, MAX_CHECKPOINTS);

        voter.setOperator(TOKEN_ID, address(0));
        vm.expectRevert(MockLeafVoter.NotAuthorized.selector);
        vm.prank(address(operator));
        operator.claimEntry(TOKEN_ID, address(pair), true, 0, MAX_CHECKPOINTS);
    }

    function test_sweep_paysWhatTheCloneHolds() public {
        _deployClone(recipient);
        usdc.mint(address(operator), 10e6);
        vm.deal(address(this), 2 ether);
        weth.mint{value: 2 ether}(address(operator));
        vm.deal(address(operator), 1 ether);

        vm.startPrank(makeAddr("anyone"));
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Swept(address(usdc), 10e6, 0.1e6);
        operator.sweep(address(usdc));
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Swept(address(weth), 2 ether, 0.02 ether);
        operator.sweep(address(weth));
        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Swept(address(0), 1 ether, 0.01 ether);
        operator.sweep(address(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 9.9e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.1e6);
        assertEq(weth.balanceOf(recipient), 1.98 ether);
        assertEq(weth.balanceOf(feeRecipient), 0.02 ether);
        assertEq(recipient.balance, 0.99 ether);
        assertEq(feeRecipient.balance, 0.01 ether);
        _assertNothingLeft();
    }

    function test_sweep_takesNoFeeOnDust() public {
        _deployClone(recipient);
        usdc.mint(address(operator), 99);

        vm.expectEmit(address(operator));
        emit ImmutableClaimOperator.Swept(address(usdc), 99, 0);
        operator.sweep(address(usdc));

        assertEq(usdc.balanceOf(recipient), 99);
    }

    function test_sweep_revertsIfATransferReturnsFalse() public {
        _deployClone(recipient);
        usdc.mint(address(operator), 10e6);
        usdc.setMode(MockToken.Mode.ReturnsFalse);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.TransferFailed.selector, address(usdc)));
        operator.sweep(address(usdc));
    }

    function test_sweep_ofNothing_doesNothing() public {
        _deployClone(recipient);

        vm.recordLogs();
        operator.sweep(address(usdc));
        operator.sweep(address(0));

        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_sweep_throughTheFactory_deploysTheClone() public {
        usdc.mint(address(operator), 10e6);
        vm.chainId(BASE);
        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, TOKEN_ID, _fees(pair), _noIncentives(), ENTRY_GAS);
        assertEq(address(operator).code.length, 0);

        vm.prank(makeAddr("anyone"));
        factory.sweep(recipient, address(usdc));

        assertEq(operator.recipient(), recipient);
        assertEq(usdc.balanceOf(recipient), 9.9e6);
        assertEq(usdc.balanceOf(feeRecipient), 0.1e6);
        factory.sweep(recipient, address(usdc));
    }

    function test_sweep_ofAnAddressWithoutCode_reverts() public {
        vm.expectRevert(bytes(""));
        factory.sweep(recipient, makeAddr("no code"));
    }

    function test_sweep_revertsIfATransferFails() public {
        _deployClone(recipient);
        usdc.mint(address(operator), 10e6);
        usdc.setBlocked(recipient, true);

        vm.expectRevert(abi.encodeWithSelector(ImmutableClaimOperator.TransferFailed.selector, address(usdc)));
        operator.sweep(address(usdc));
    }

    function test_sweep_cannotBeReentered() public {
        bytes[2] memory reentries = _reentries();
        for (uint256 i; i < reentries.length; ++i) {
            (Reenterer reenterer, ImmutableClaimOperator clone) = _reenterer(reentries[i]);
            vm.deal(address(clone), 1 ether);

            factory.sweep(address(reenterer), address(0));

            assertEq(bytes4(reenterer.reason()), ImmutableClaimOperator.Reentrancy.selector);
            assertEq(address(reenterer).balance, 0.99 ether);
        }
    }
}
