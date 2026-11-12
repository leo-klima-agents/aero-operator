// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ILeafVoter} from "../../src/interfaces/ILeafVoter.sol";

contract MockToken {
    enum Mode {
        Standard,
        NoReturn,
        ReturnsFalse,
        BurnsGas
    }

    Mode public mode;
    mapping(address account => uint256) public balanceOf;
    mapping(address account => bool) public blocked;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(!blocked[to] && amount != 0, "blocked or nothing to send");
        if (mode == Mode.BurnsGas) {
            assembly ("memory-safe") {
                invalid()
            }
        }
        bool ok = mode != Mode.ReturnsFalse;
        if (ok) {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        if (mode == Mode.NoReturn) return;
        assembly ("memory-safe") {
            mstore(0x00, ok)
            return(0x00, 0x20)
        }
    }
}

contract MockWrappedNative {
    mapping(address account => uint256) public balanceOf;

    function mint(address to) external payable {
        balanceOf[to] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }
}

contract MockFactoryRegistry {
    mapping(address rewards => address) public rewardsToGauge;

    function register(address rewards) external {
        rewardsToGauge[rewards] = address(uint160(rewards) ^ type(uint160).max);
    }
}

contract MockRewardsManager {
    struct Incentive {
        address token;
        uint256 amount;
        uint256 rate;
        uint48 start;
        uint48 end;
        address creator;
    }

    address public immutable voter;
    address public immutable token0;
    address public immutable token1;
    address public immutable wrappedNative;

    uint256 public incentiveCount;
    uint256 public work;
    uint256 public lastMaxCheckpoints;
    mapping(uint256 programId => Incentive) public incentive;
    mapping(uint256 tokenId => uint256[2]) internal _fees;
    mapping(uint256 tokenId => mapping(uint256 programId => uint256)) public incentives;

    constructor(address voter_, address token0_, address token1_, address wrappedNative_) {
        voter = voter_;
        token0 = token0_;
        token1 = token1_;
        wrappedNative = wrappedNative_;
    }

    receive() external payable {}

    function fees(uint256 tokenId) external view returns (uint256, uint256) {
        return (_fees[tokenId][0], _fees[tokenId][1]);
    }

    function setFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        _fees[tokenId] = [amount0, amount1];
    }

    function addIncentive(address token) external returns (uint256 programId) {
        programId = ++incentiveCount;
        incentive[programId].token = token;
    }

    function setIncentive(uint256 tokenId, uint256 programId, uint256 amount) external {
        incentives[tokenId][programId] = amount;
    }

    function setWork(uint256 work_) external {
        work = work_;
    }

    function claimFees(uint256 tokenId, address recipient, uint256 maxCheckpoints) external {
        require(msg.sender == voter && maxCheckpoints != 0, "claimFees");
        _work(maxCheckpoints);
        (uint256 amount0, uint256 amount1) = (_fees[tokenId][0], _fees[tokenId][1]);
        delete _fees[tokenId];
        _pay(recipient, token0, amount0);
        _pay(recipient, token1, amount1);
    }

    function claimIncentives(uint256 tokenId, address recipient, uint256 programId, uint256 maxCheckpoints) external {
        require(msg.sender == voter && maxCheckpoints != 0, "claimIncentives");
        _work(maxCheckpoints);
        require(programId != 0 && programId <= incentiveCount, "program");
        uint256 amount = incentives[tokenId][programId];
        delete incentives[tokenId][programId];
        _pay(recipient, incentive[programId].token, amount);
    }

    function _work(uint256 maxCheckpoints) private {
        lastMaxCheckpoints = maxCheckpoints;
        uint256 afterWork = gasleft() - work;
        while (gasleft() > afterWork) {}
    }

    function _pay(address recipient, address token, uint256 amount) private {
        if (amount == 0) return;
        if (token == wrappedNative) {
            MockWrappedNative(token).withdraw(amount);
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "native");
        } else {
            (bool ok, bytes memory ret) = token.call(abi.encodeCall(MockToken.transfer, (recipient, amount)));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "token");
        }
    }
}

contract MockLeafVoter {
    address public immutable FACTORY_REGISTRY;
    mapping(uint256 tokenId => address) public operator;

    error NotAuthorized();

    constructor(address registry) {
        FACTORY_REGISTRY = registry;
    }

    function setOperator(uint256 tokenId, address operator_) external {
        operator[tokenId] = operator_;
    }

    function claimRewards(
        uint256 tokenId,
        address recipient,
        ILeafVoter.FeeClaim[] calldata feeClaims,
        ILeafVoter.IncentiveClaim[] calldata incentiveClaims
    ) external {
        if (msg.sender != operator[tokenId]) revert NotAuthorized();
        for (uint256 i; i < feeClaims.length; ++i) {
            address manager = feeClaims[i].votingRewardsManager;
            if (MockFactoryRegistry(FACTORY_REGISTRY).rewardsToGauge(manager) == address(0)) continue;
            MockRewardsManager(payable(manager)).claimFees(tokenId, recipient, feeClaims[i].maxCheckpoints);
        }
        for (uint256 i; i < incentiveClaims.length; ++i) {
            address manager = incentiveClaims[i].votingRewardsManager;
            if (MockFactoryRegistry(FACTORY_REGISTRY).rewardsToGauge(manager) == address(0)) continue;
            MockRewardsManager(payable(manager))
                .claimIncentives(tokenId, recipient, incentiveClaims[i].programId, incentiveClaims[i].maxCheckpoints);
        }
    }
}

contract MockSafe {
    receive() external payable {}
}

contract MockVotingEscrow {
    mapping(uint256 tokenId => address) public ownerOf;

    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
}
