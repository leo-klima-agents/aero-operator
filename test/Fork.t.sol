// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

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
    bytes32 internal constant CLAIMED = keccak256("Claimed(uint256,address,uint256,uint256)");
    bytes32 internal constant CLAIM_FAILED = keccak256("ClaimFailed(uint256,address,bool,uint256)");

    Deploy internal d;
    ILeafVoterExtra internal leaf;
    ImmutableClaimOperatorFactory internal factory;
    ImmutableClaimOperator internal operator;
    address internal recipient;
    address internal feeRecipient;
    address internal caller = makeAddr("caller");

    ILeafVoter.FeeClaim[] internal feeClaims;
    ILeafVoter.IncentiveClaim[] internal incentiveClaims;
    address[] internal tokens;
    address internal wrappedNative;
    uint256 internal claimGas;

    function _rpc() internal view virtual returns (string memory);
    function _block() internal pure virtual returns (uint256);
    function _chainId() internal pure virtual returns (uint256);
    function _stake() internal pure virtual returns (uint256);
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
        // Stands in for the fee Safe where it is missing.
        if (feeRecipient.code.length == 0) vm.etch(feeRecipient, hex"00");
        factory = ImmutableClaimOperatorFactory(d.run());
        recipient = _recipient();
        operator = ImmutableClaimOperator(payable(factory.operatorOf(recipient)));
        _discover();
    }

    function _discover() internal {
        Discovery.Claims memory claims = Discovery.claims(address(leaf), _stake(), 0, true);
        assertGt(claims.fees.length, 0, "the stake has nothing to claim on this chain at this block");
        assertEq(claims.unread, 0, "some incentive programs could not be read");
        for (uint256 i; i < claims.fees.length; ++i) {
            feeClaims.push(claims.fees[i]);
        }
        for (uint256 i; i < claims.incentives.length; ++i) {
            incentiveClaims.push(claims.incentives[i]);
        }
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
        vm.prank(caller);
        uint256 gas = gasleft();
        factory.claim(recipient, _stake(), feeClaims, incentiveClaims, ENTRY_GAS);
        claimGas = gas - gasleft();
        return vm.getRecordedLogs();
    }

    function _failuresWith(uint256 entryGas) internal returns (uint256 failures) {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        factory.claim(recipient, _stake(), feeClaims, incentiveClaims, entryGas);
        failures = _count(vm.getRecordedLogs(), CLAIM_FAILED);
        vm.revertToState(snapshot);
    }

    function _checkWhatAFirstFeeClaimNeeds() internal {
        _setOperator(address(operator));
        assertEq(_failuresWith(700_000), 0);
        assertGt(_failuresWith(500_000), 0);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(operator) && logs[i].topics[0] == topic) ++count;
        }
    }

    function _claimed(Vm.Log[] memory logs) internal view returns (uint256[] memory amounts, uint256[] memory fees) {
        amounts = new uint256[](tokens.length);
        fees = new uint256[](tokens.length);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(operator) || logs[i].topics[0] != CLAIMED) continue;
            assertEq(uint256(logs[i].topics[1]), _stake());
            address token = address(uint160(uint256(logs[i].topics[2])));
            (uint256 amount, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(fee, amount / 100);
            for (uint256 j; j < tokens.length; ++j) {
                if (tokens[j] != (token == wrappedNative ? address(0) : token)) continue;
                amounts[j] += amount;
                fees[j] += fee;
            }
        }
    }

    function _stakeState() internal view returns (bytes memory state) {
        (, uint48 lastAllocated, bool zeroCap, uint128 chainAllocation) = leaf.tokenStates(_stake());
        address[] memory gauges = leaf.allocatedGauges(_stake());
        state = abi.encode(lastAllocated, zeroCap, chainAllocation, gauges);
        for (uint256 i; i < gauges.length; ++i) {
            state = bytes.concat(state, abi.encode(leaf.allocations(_stake(), gauges[i])));
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

    function test_addresses_matchTheRecordOnEveryChain() public view {
        string memory json = vm.readFile("verification/bytecode-hashes.json");
        assertEq(address(factory), vm.parseJsonAddress(json, ".deployment.factory"));
        assertEq(factory.implementation(), vm.parseJsonAddress(json, ".deployment.implementation"));
        assertEq(address(factory).codehash, vm.parseJsonBytes32(json, ".deployment.factoryRuntimeKeccak"));
        assertEq(
            factory.implementation().codehash, vm.parseJsonBytes32(json, ".deployment.implementationRuntimeKeccak")
        );

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                hex"6100413d81600a3d39f3363d3d373d3d3d363d73",
                vm.parseJsonAddress(json, ".deployment.implementation"),
                hex"5af43d82803e903d91602b57fd5bf3",
                recipient
            )
        );
        assertEq(
            address(operator),
            vm.computeCreate2Address(bytes32(0), initCodeHash, vm.parseJsonAddress(json, ".deployment.factory"))
        );

        ImmutableClaimOperator implementation = ImmutableClaimOperator(payable(factory.implementation()));
        assertEq(implementation.leafVoter(), 0x382409fad8503FbCdbB27A4211551fa03e884078);
        assertEq(implementation.escrow(), 0xBF7977E1521e9a3032bf7243Ee4712f311f13915);
        assertEq(implementation.baseChainId(), 8453);
        assertEq(implementation.feeRecipient(), 0x450c72de8c0079B49AcedF294a13011bd09D125B);
    }

    function test_theFactory_cannotBeDeployedWithoutTheFeeSafe() public {
        vm.etch(feeRecipient, "");

        (bool ok,) = CREATE2_FACTORY.call(bytes.concat(bytes32(uint256(1)), d.initCode()));

        assertFalse(ok);
    }

    function test_claim_revertsUnlessAnEntryCanBeGivenItsGas() public {
        _setOperator(address(operator));
        uint256[] memory before = _balances(recipient);

        vm.expectRevert(ImmutableClaimOperator.InsufficientGas.selector);
        factory.claim{gas: ENTRY_GAS}(recipient, _stake(), feeClaims, incentiveClaims, ENTRY_GAS);

        assertEq(_balances(recipient), before);
    }

    function test_claim_paysInFullLessTheFee() public {
        _setOperator(address(operator));
        bytes memory stake = _stakeState();
        uint256 entries = feeClaims.length + incentiveClaims.length;

        uint256 snapshot = vm.snapshotState();
        uint256[] memory before = _balances(recipient);
        vm.prank(leaf.ORCHESTRATOR());
        uint256 directGas = gasleft();
        ILeafVoter(address(leaf)).claimRewards(_stake(), recipient, feeClaims, incentiveClaims);
        directGas -= gasleft();
        uint256[] memory direct = _gained(recipient, before);
        vm.revertToState(snapshot);

        uint256[] memory feesBefore = _balances(feeRecipient);
        assertEq(address(operator).code.length, 0);
        Vm.Log[] memory logs = _claim();
        assertEq(operator.recipient(), recipient);
        uint256[] memory paid = _gained(recipient, before);
        uint256[] memory fees = _gained(feeRecipient, feesBefore);
        (uint256[] memory claimed, uint256[] memory claimedFees) = _claimed(logs);

        for (uint256 i; i < tokens.length; ++i) {
            assertEq(paid[i] + fees[i], direct[i]);
            assertEq(claimed[i], direct[i]);
            assertEq(claimedFees[i], fees[i]);
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

    function test_optingOut_stopsTheClaims() public {
        _setOperator(address(operator));
        assertEq(leaf.operator(_stake()), address(operator));
        _setOperator(address(0));
        assertEq(leaf.operator(_stake()), address(0));
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

    function _stake() internal pure override returns (uint256) {
        return 621;
    }

    function _recipient() internal override returns (address) {
        escrow = IVotingEscrowExtra(d.ESCROW());
        return escrow.ownerOf(_stake());
    }

    function _setOperator(address account) internal override {
        vm.prank(recipient);
        VOTER.setOperator(_stake(), block.chainid, account, 0, recipient);
    }

    function test_claim_aFirstFeeClaimNeedsMoreThan500000Gas() public {
        _checkWhatAFirstFeeClaimNeeds();
    }

    function test_claim_leavesTheStakeWithItsOwner() public {
        (uint128 amount, uint48 end, bool isPermanent) = escrow.staked(_stake());
        uint128 allocated = VOTER.allocationChainAmounts(_stake(), block.chainid);
        _setOperator(address(operator));

        _claim();

        assertEq(escrow.ownerOf(_stake()), recipient);
        (uint128 amountAfter, uint48 endAfter, bool isPermanentAfter) = escrow.staked(_stake());
        assertEq(amountAfter, amount);
        assertEq(endAfter, end);
        assertEq(isPermanentAfter, isPermanent);
        assertEq(VOTER.allocationChainAmounts(_stake(), block.chainid), allocated);
    }

    function test_claim_afterASale_isRefused() public {
        _setOperator(address(operator));
        address buyer = makeAddr("buyer");
        vm.prank(recipient);
        escrow.transferFrom(recipient, buyer, _stake());
        assertEq(leaf.operator(_stake()), address(operator));
        uint256[] memory before = _balances(recipient);

        vm.expectRevert(ImmutableClaimOperator.NotOwner.selector);
        factory.claim(recipient, _stake(), feeClaims, incentiveClaims, ENTRY_GAS);
        assertEq(_balances(recipient), before);

        vm.expectRevert(bytes4(keccak256("NotAuthorized()")));
        vm.prank(recipient);
        VOTER.setOperator(_stake(), block.chainid, address(operator), 0, recipient);

        address buyerOperator = factory.operatorOf(buyer);
        vm.prank(buyer);
        VOTER.setOperator(_stake(), block.chainid, buyerOperator, 0, buyer);
        uint256 native = buyer.balance;
        factory.claim(buyer, _stake(), feeClaims, incentiveClaims, ENTRY_GAS);
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

    function _stake() internal pure override returns (uint256) {
        return 621;
    }

    function _recipient() internal override returns (address) {
        return makeAddr("recipient");
    }

    // As the Voter's message from Base does.
    function _setOperator(address account) internal override {
        vm.prank(leaf.ORCHESTRATOR());
        leaf.setOperator(_stake(), account);
    }

    function test_claim_aFirstFeeClaimNeedsMoreThan500000Gas() public {
        _checkWhatAFirstFeeClaimNeeds();
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
