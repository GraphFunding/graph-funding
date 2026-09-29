// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEpochSource} from "./interfaces/IEpochSource.sol";

/// @title Keeper staking
/// @notice Lock $GRAPHFUND to enter the draw for Graph Funding committees. The chance of being drawn is
///         proportional to the stake. Stakes below `minStake` stay locked but carry no weight.
contract KeeperStaking is Ownable2Step {
    using SafeERC20 for IERC20;

    error AlreadySet();
    error ZeroAddress();
    error TokenNotSet();
    error ZeroAmount();
    error DrawIsPending();
    error Locked();
    error NotGraphFund();
    error InsufficientStake();
    error StakersExist();
    error NoWeight();
    error BelowMinStake();

    event TokenSet(address indexed token);
    event GraphFundSet(address indexed graphFund);
    event MinStakeSet(uint256 minStake);
    event Staked(address indexed keeper, uint256 amount, uint256 stake);
    event Unstaked(address indexed keeper, uint256 amount, uint256 stake);
    event DrawPendingSet(bool pending);
    event KeeperLocked(address indexed keeper, uint256 epoch);

    IERC20 public token;
    address public graphFund;
    uint256 public minStake = 100_000e18;
    bool public drawPending;
    uint256 public drawPendingSince;
    uint256 public constant FREEZE_MAX = 7200; // ~1 day of blocks

    mapping(address => uint256) public stakeOf;
    mapping(address => uint256) public lockedEpoch;
    mapping(address => uint256) public slotOf;
    mapping(uint256 => address) public slotOwner;
    uint256 public slots;
    uint256 public totalWeight;
    uint256 public totalStaked;

    /// @dev Fenwick tree over slots (1-based). Grows by one slot per new staker.
    mapping(uint256 => uint256) internal _fen;

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyGraphFund() {
        if (msg.sender != graphFund) revert NotGraphFund();
        _;
    }

    // ---------------------------------------------------------------- admin

    function setToken(address token_) external onlyOwner {
        if (address(token) != address(0)) revert AlreadySet();
        if (token_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        emit TokenSet(token_);
    }

    function setGraphFund(address graphFund_) external onlyOwner {
        if (graphFund != address(0)) revert AlreadySet();
        if (graphFund_ == address(0)) revert ZeroAddress();
        graphFund = graphFund_;
        emit GraphFundSet(graphFund_);
    }

    /// @notice Only before anyone has staked, so the draw weights never go stale.
    function setMinStake(uint256 minStake_) external onlyOwner {
        if (slots != 0) revert StakersExist();
        minStake = minStake_;
        emit MinStakeSet(minStake_);
    }

    // ---------------------------------------------------------------- keepers

    function stake(uint256 amount) external {
        if (address(token) == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        if (drawPending && block.number < drawPendingSince + FREEZE_MAX) revert DrawIsPending();
        uint256 before = stakeOf[msg.sender];
        uint256 afterStake = before + amount;
        if (afterStake < minStake) revert BelowMinStake();
        uint256 slot = slotOf[msg.sender];
        if (slot == 0) slot = _append(msg.sender);
        stakeOf[msg.sender] = afterStake;
        totalStaked += amount;
        _reweight(slot, _weight(before), _weight(afterStake));
        emit Staked(msg.sender, amount, afterStake);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (drawPending && block.number < drawPendingSince + FREEZE_MAX) revert DrawIsPending();
        uint256 le = lockedEpoch[msg.sender];
        if (le != 0 && le >= IEpochSource(graphFund).epoch()) revert Locked();
        uint256 before = stakeOf[msg.sender];
        if (amount > before) revert InsufficientStake();
        uint256 afterStake = before - amount;
        stakeOf[msg.sender] = afterStake;
        totalStaked -= amount;
        _reweight(slotOf[msg.sender], _weight(before), _weight(afterStake));
        token.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, afterStake);
    }

    function weightOf(address keeper) external view returns (uint256) {
        return _weight(stakeOf[keeper]);
    }

    // ---------------------------------------------------------------- graph fund hooks

    function setDrawPending(bool pending) external onlyGraphFund {
        if (pending && !drawPending) drawPendingSince = block.number;
        drawPending = pending;
        emit DrawPendingSet(pending);
    }

    function lock(address keeper, uint256 epoch_) external onlyGraphFund {
        if (epoch_ > lockedEpoch[keeper]) {
            lockedEpoch[keeper] = epoch_;
            emit KeeperLocked(keeper, epoch_);
        }
    }

    /// @notice Keeper at weighted position `rand % totalWeight`.
    function drawOne(uint256 rand) external view returns (address) {
        uint256 tw = totalWeight;
        if (tw == 0) revert NoWeight();
        return slotOwner[_find(rand % tw)];
    }

    // ---------------------------------------------------------------- fenwick

    function _weight(uint256 s) internal view returns (uint256) {
        return s >= minStake ? s : 0;
    }

    function _reweight(uint256 slot, uint256 oldW, uint256 newW) internal {
        if (newW > oldW) {
            _add(slot, newW - oldW);
            totalWeight += newW - oldW;
        } else if (oldW > newW) {
            _sub(slot, oldW - newW);
            totalWeight -= oldW - newW;
        }
    }

    function _append(address keeper) internal returns (uint256 i) {
        i = ++slots;
        uint256 low = i & (~i + 1);
        _fen[i] = _prefix(i - 1) - _prefix(i - low);
        slotOf[keeper] = i;
        slotOwner[i] = keeper;
    }

    function _prefix(uint256 i) internal view returns (uint256 s) {
        while (i > 0) {
            s += _fen[i];
            i &= i - 1;
        }
    }

    function _add(uint256 i, uint256 v) internal {
        uint256 n = slots;
        while (i <= n) {
            _fen[i] += v;
            i += i & (~i + 1);
        }
    }

    function _sub(uint256 i, uint256 v) internal {
        uint256 n = slots;
        while (i <= n) {
            _fen[i] -= v;
            i += i & (~i + 1);
        }
    }

    /// @dev Smallest slot i with prefix(i) > r (requires r < totalWeight).
    function _find(uint256 r) internal view returns (uint256) {
        uint256 n = slots;
        uint256 pos;
        uint256 step = 1;
        while (step <= n) step <<= 1;
        for (step >>= 1; step > 0; step >>= 1) {
            uint256 nxt = pos + step;
            if (nxt <= n && _fen[nxt] <= r) {
                pos = nxt;
                r -= _fen[nxt];
            }
        }
        return pos + 1;
    }
}
