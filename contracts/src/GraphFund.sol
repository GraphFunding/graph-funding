// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IKeeperStaking} from "./interfaces/IKeeperStaking.sol";
import {IKeeperBadge} from "./interfaces/IKeeperBadge.sol";
import {Median} from "./lib/Median.sol";

/// @title Graph Funding
/// @notice Snowmoon, chapter 17, on Ethereum. Fees flow down a tree of public goods. At every branch a
///         committee drawn at random from $GRAPHFUND stakers sets the weights of the children.
/// @dev Unaudited. Randomness comes from the blockhash of a future block, which that block's proposer can bias.
contract GraphFund is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Node {
        uint32 parent;
        uint8 depth;
        bool active;
        bool pending;
        bool everFunded;
        bool bondSettled;
        uint8 zeroStreak;
        address recipient; // 0 = branch
        address proposer; // 0 = added by the owner
        uint256 bond;
        string name;
    }

    struct Params {
        uint64 epochLength;
        uint8 committeeSize;
        uint16 voterPayBps;
        uint8 drawDelay;
        uint8 maxChildren;
        uint8 maxDepth;
        uint16 maxNodes;
        uint8 pruneAfter;
        uint256 proposalBond;
    }

    error BadNode();
    error BadParent();
    error TooDeep();
    error TooManyChildren();
    error TooManyNodes();
    error BadName();
    error BadWeights();
    error BadParams();
    error AlreadyStarted();
    error NotStarted();
    error NoDrawPending();
    error TooEarly();
    error NotMember();
    error AlreadyVoted();
    error NothingOwed();
    error ZeroAddress();
    error TokenNotSet();
    error UseRejectProposal();
    error NotProposer();
    error NotFunded();
    error BondSettled();
    error NotPrunable();

    event NodeAdded(uint32 indexed id, uint32 indexed parent, address recipient, address proposer, string name, bool pending);
    event NodeActivated(uint32 indexed id);
    event NodeRemoved(uint32 indexed id);
    event WeightsSet(uint32 indexed node, uint16[] weights);
    event ParamsSet(Params params);
    event EpochStarted(uint256 indexed epoch, uint256 at);
    event DrawRequested(uint256 indexed epoch, uint256 seedBlock);
    event Drawn(uint256 indexed epoch, uint256 seed);
    event CommitteeDrawn(uint256 indexed epoch, uint32 indexed node, address[] members);
    event Voted(uint256 indexed epoch, uint32 indexed node, address indexed keeper, uint16[] weights);
    event WeightsFinalized(uint256 indexed epoch, uint32 indexed node, uint16[] weights);
    event Credited(uint256 indexed epoch, uint32 indexed node, address indexed recipient, uint256 amount);
    event VoterPaid(uint256 indexed epoch, uint32 indexed node, address indexed keeper, uint256 amount);
    event EpochAdvanced(uint256 indexed epoch, uint256 distributed);
    event Paid(address indexed to, uint256 amount, bool asEth);
    event Donated(address indexed from, uint256 amount);
    event Proposed(uint32 indexed id, address indexed proposer, uint256 bond);
    event ProposalRejected(uint32 indexed id, uint256 bondBurned);
    event BondReturned(uint32 indexed id, address indexed to, uint256 amount);
    event Pruned(uint32 indexed id, address indexed bondTo, uint256 bond);

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IWETH public immutable weth;
    IKeeperStaking public immutable staking;
    IKeeperBadge public immutable badge;

    Params internal _params;

    Node[] internal _nodes;
    mapping(uint256 => uint32[]) internal _kids;
    mapping(uint256 => uint16[]) internal _weights;
    mapping(uint256 => uint256) internal _pendingKids;
    uint32[] internal _pendingIds;
    uint256 public liveNodes;

    uint256 public epoch;
    uint256 public epochStart;
    uint256 public seedBlock;
    bool public drawPending;

    mapping(uint256 => mapping(uint256 => address[])) internal _committee;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public isMember;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasVoted;
    mapping(uint256 => mapping(uint256 => address[])) internal _voters;
    mapping(uint256 => mapping(uint256 => uint16[][])) internal _votes;
    mapping(uint256 => mapping(address => bool)) public badged;

    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    constructor(address owner_, IWETH weth_, IKeeperStaking staking_, IKeeperBadge badge_) Ownable(owner_) {
        if (address(weth_) == address(0) || address(staking_) == address(0) || address(badge_) == address(0)) {
            revert ZeroAddress();
        }
        weth = weth_;
        staking = staking_;
        badge = badge_;
        _params = Params({
            epochLength: 6 hours,
            committeeSize: 5,
            voterPayBps: 200,
            drawDelay: 5,
            maxChildren: 8,
            maxDepth: 4,
            maxNodes: 48,
            pruneAfter: 4,
            proposalBond: 1_000_000e18
        });
        _nodes.push();
        Node storage root = _nodes[0];
        root.active = true;
        root.name = "Ethereum public goods";
        liveNodes = 1;
        emit NodeAdded(0, 0, address(0), address(0), root.name, false);
    }

    receive() external payable {
        if (msg.sender != address(weth)) {
            weth.deposit{value: msg.value}();
            emit Donated(msg.sender, msg.value);
        }
    }

    // ================================================================ owner: tree & params

    function addNode(uint32 parent, string calldata name, address recipient) external onlyOwner returns (uint32) {
        return _create(parent, name, recipient, address(0), 0);
    }

    function removeNode(uint32 id) external onlyOwner {
        if (id == 0 || id >= _nodes.length) revert BadNode();
        Node storage n = _nodes[id];
        if (!(n.active || n.pending)) revert BadNode();
        if (n.proposer != address(0)) revert UseRejectProposal();
        _remove(id);
    }

    function setWeights(uint32 node, uint16[] calldata bps) external onlyOwner {
        if (node >= _nodes.length) revert BadNode();
        Node storage n = _nodes[node];
        if (!n.active || n.recipient != address(0)) revert BadNode();
        if (bps.length == 0 || bps.length != _kids[node].length) revert BadWeights();
        _checkSum(bps);
        _weights[node] = bps;
        emit WeightsSet(node, bps);
    }

    function setParams(Params calldata p) external onlyOwner {
        if (
            p.epochLength < 10 minutes || p.epochLength > 7 days || p.committeeSize == 0 || p.committeeSize > 9
                || p.voterPayBps > 1_000 || p.drawDelay == 0 || p.drawDelay > 64 || p.maxChildren < 2
                || p.maxChildren > 16 || p.maxDepth == 0 || p.maxDepth > 6 || p.maxNodes < liveNodes
                || p.maxNodes > 128 || p.pruneAfter == 0
        ) revert BadParams();
        if (uint256(p.epochLength) < uint256(p.drawDelay) * 12 + 1 hours) revert BadParams(); // voting window after the seed
        if (uint256(p.committeeSize) * (uint256(p.maxNodes) / 2) > 120) revert BadParams(); // keeps draw() far under the 16.78M tx gas cap
        _params = p;
        emit ParamsSet(p);
    }

    function start() external onlyOwner {
        if (epoch != 0) revert AlreadyStarted();
        epoch = 1;
        epochStart = block.timestamp;
        emit EpochStarted(1, block.timestamp);
        _requestDraw();
    }

    // ================================================================ epochs

    function draw() external {
        if (!drawPending) revert NoDrawPending();
        if (block.number <= seedBlock) revert TooEarly();
        if (block.number - seedBlock > 256) {
            _requestDraw();
            return;
        }
        uint256 e = epoch;
        uint256 seed = uint256(keccak256(abi.encode(blockhash(seedBlock), e)));
        drawPending = false;
        staking.setDrawPending(false);
        if (staking.totalWeight() > 0) {
            (uint32[] memory br, uint256 nb) = _activeBranches();
            uint256 k = _params.committeeSize;
            for (uint256 b; b < nb; b++) {
                uint32 id = br[b];
                if (_kids[id].length < 2) continue;
                address[] storage c = _committee[e][id];
                for (uint256 a; a < k * 3 && c.length < k; a++) {
                    address m = staking.drawOne(uint256(keccak256(abi.encode(seed, id, a))));
                    if (isMember[e][id][m]) continue;
                    isMember[e][id][m] = true;
                    c.push(m);
                    staking.lock(m, e);
                }
                emit CommitteeDrawn(e, id, c);
            }
        }
        emit Drawn(e, seed);
    }

    function vote(uint32 node, uint16[] calldata bps) external {
        uint256 e = epoch;
        if (!isMember[e][node][msg.sender]) revert NotMember();
        if (hasVoted[e][node][msg.sender]) revert AlreadyVoted();
        if (bps.length != _kids[node].length) revert BadWeights();
        _checkSum(bps);
        hasVoted[e][node][msg.sender] = true;
        uint16[] storage slot = _votes[e][node].push();
        for (uint256 i; i < bps.length; i++) slot.push(bps[i]);
        _voters[e][node].push(msg.sender);
        if (!badged[e][msg.sender]) {
            badged[e][msg.sender] = true;
            try badge.mint(msg.sender, e) {} catch {}
        }
        emit Voted(e, node, msg.sender, bps);
    }

    function advance() external nonReentrant {
        uint256 e = epoch;
        if (e == 0) revert NotStarted();
        if (block.timestamp < epochStart + _params.epochLength) revert TooEarly();
        (uint32[] memory br, uint256 nb) = _activeBranches();
        for (uint256 b; b < nb; b++) _finalize(e, br[b]);
        uint256 distributed = _distribute(e);
        _updateStreaks(br, nb);
        _activatePending();
        epoch = e + 1;
        epochStart = block.timestamp;
        emit EpochAdvanced(e, distributed);
        _requestDraw();
    }

    function payout(address to) external nonReentrant {
        uint256 amount = owed[to];
        if (amount == 0) revert NothingOwed();
        owed[to] = 0;
        totalOwed -= amount;
        weth.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            weth.deposit{value: amount}();
            IERC20(address(weth)).safeTransfer(to, amount);
        }
        emit Paid(to, amount, ok);
    }

    // ================================================================ proposals

    function propose(uint32 parent, address recipient, string calldata name) external returns (uint32 id) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 bond = _params.proposalBond;
        IERC20 t = _bondToken();
        id = _create(parent, name, recipient, msg.sender, bond);
        if (bond > 0) t.safeTransferFrom(msg.sender, address(this), bond);
        emit Proposed(id, msg.sender, bond);
    }

    function rejectProposal(uint32 id) external onlyOwner {
        if (id >= _nodes.length) revert BadNode();
        Node storage n = _nodes[id];
        if (n.proposer == address(0) || !(n.active || n.pending)) revert BadNode();
        uint256 bond = n.bondSettled ? 0 : n.bond;
        n.bondSettled = true;
        address proposer = n.proposer;
        bool refund = n.everFunded;
        _remove(id);
        if (bond > 0) {
            if (refund) {
                _bondToken().safeTransfer(proposer, bond);
                emit BondReturned(id, proposer, bond);
            } else {
                _bondToken().safeTransfer(DEAD, bond);
            }
        }
        emit ProposalRejected(id, refund ? 0 : bond);
    }

    function claimBond(uint32 id) external {
        if (id >= _nodes.length) revert BadNode();
        Node storage n = _nodes[id];
        if (n.proposer != msg.sender) revert NotProposer();
        if (!n.everFunded) revert NotFunded();
        if (n.bondSettled) revert BondSettled();
        n.bondSettled = true;
        _bondToken().safeTransfer(msg.sender, n.bond);
        emit BondReturned(id, msg.sender, n.bond);
    }

    function prune(uint32 id) external {
        if (id >= _nodes.length) revert BadNode();
        Node storage n = _nodes[id];
        if (n.proposer == address(0) || !n.active || n.zeroStreak < _params.pruneAfter) revert NotPrunable();
        uint256 bond = n.bondSettled ? 0 : n.bond;
        n.bondSettled = true;
        address to = n.everFunded ? n.proposer : DEAD;
        _remove(id);
        if (bond > 0) _bondToken().safeTransfer(to, bond);
        emit Pruned(id, to, bond);
    }

    // ================================================================ views

    function nodeCount() external view returns (uint256) {
        return _nodes.length;
    }

    function getNode(uint32 id) external view returns (Node memory) {
        return _nodes[id];
    }

    function getChildren(uint32 id) external view returns (uint32[] memory ids, uint16[] memory weights) {
        return (_kids[id], _weights[id]);
    }

    function getPending() external view returns (uint32[] memory) {
        return _pendingIds;
    }

    function getParams() external view returns (Params memory) {
        return _params;
    }

    function getCommittee(uint256 e, uint32 node) external view returns (address[] memory) {
        return _committee[e][node];
    }

    function getVotes(uint256 e, uint32 node) external view returns (address[] memory voters, uint16[][] memory vectors) {
        return (_voters[e][node], _votes[e][node]);
    }

    function started() external view returns (bool) {
        return epoch > 0;
    }

    function nextAdvanceAt() external view returns (uint256) {
        return epoch == 0 ? 0 : epochStart + _params.epochLength;
    }

    function pool() external view returns (uint256) {
        return weth.balanceOf(address(this)) - totalOwed;
    }

    // ================================================================ internals: tree

    function _create(uint32 parent, string calldata name, address recipient, address proposer, uint256 bond)
        internal
        returns (uint32 id)
    {
        if (parent >= _nodes.length) revert BadNode();
        Node storage p = _nodes[parent];
        if (!p.active || p.pending || p.recipient != address(0)) revert BadParent();
        if (uint256(p.depth) + 1 > _params.maxDepth) revert TooDeep();
        if (_kids[parent].length + _pendingKids[parent] >= _params.maxChildren) revert TooManyChildren();
        if (liveNodes >= _params.maxNodes) revert TooManyNodes();
        uint256 len = bytes(name).length;
        if (len == 0 || len > 64) revert BadName();
        id = uint32(_nodes.length);
        _nodes.push();
        Node storage n = _nodes[id];
        n.parent = parent;
        n.depth = p.depth + 1;
        n.recipient = recipient;
        n.proposer = proposer;
        n.bond = bond;
        n.name = name;
        liveNodes++;
        if (epoch == 0) {
            n.active = true;
            _attach(parent, id);
        } else {
            n.pending = true;
            _pendingIds.push(id);
            _pendingKids[parent]++;
        }
        emit NodeAdded(id, parent, recipient, proposer, name, n.pending);
    }

    function _attach(uint32 parent, uint32 id) internal {
        _kids[parent].push(id);
        _weights[parent].push(_kids[parent].length == 1 ? 10_000 : 0);
    }

    function _remove(uint32 id) internal {
        Node storage n = _nodes[id];
        if (n.pending) _dropPending(id);
        else _detach(n.parent, id);
        _deactivate(id);
    }

    function _dropPending(uint32 id) internal {
        uint256 len = _pendingIds.length;
        for (uint256 i; i < len; i++) {
            if (_pendingIds[i] == id) {
                _pendingIds[i] = _pendingIds[len - 1];
                _pendingIds.pop();
                break;
            }
        }
        _pendingKids[_nodes[id].parent]--;
    }

    function _detach(uint32 parent, uint32 id) internal {
        uint32[] storage ks = _kids[parent];
        uint16[] storage ws = _weights[parent];
        uint256 n = ks.length;
        for (uint256 i; i < n; i++) {
            if (ks[i] == id) {
                if (epoch > 0) {
                    uint16[][] storage vs = _votes[epoch][parent];
                    uint256 nv = vs.length;
                    for (uint256 v; v < nv; v++) {
                        if (vs[v].length == n) {
                            vs[v][i] = vs[v][n - 1];
                            vs[v].pop();
                        }
                    }
                }
                ks[i] = ks[n - 1];
                ws[i] = ws[n - 1];
                ks.pop();
                ws.pop();
                break;
            }
        }
        uint256 m = ks.length;
        if (m > 0) {
            uint256[] memory raw = new uint256[](m);
            for (uint256 i; i < m; i++) raw[i] = ws[i];
            uint16[] memory w = Median.normalize(raw);
            _weights[parent] = w;
            emit WeightsSet(parent, w);
        }
    }

    /// @dev Marks `id` and every descendant (active or pending) as removed. Refunds unsettled proposal bonds
    ///      to their proposers.
    function _deactivate(uint32 id) internal {
        Node storage n = _nodes[id];
        n.active = false;
        n.pending = false;
        liveNodes--;
        if (n.proposer != address(0) && !n.bondSettled && n.bond > 0) {
            n.bondSettled = true;
            _bondToken().safeTransfer(n.proposer, n.bond);
            emit BondReturned(id, n.proposer, n.bond);
        }
        emit NodeRemoved(id);
        uint32[] storage ks = _kids[id];
        while (ks.length > 0) {
            uint32 c = ks[ks.length - 1];
            ks.pop();
            _weights[id].pop();
            _deactivate(c);
        }
        if (_pendingKids[id] > 0) {
            for (uint256 i = _pendingIds.length; i > 0; i--) {
                uint32 c = _pendingIds[i - 1];
                if (_nodes[c].parent == id) {
                    _dropPending(c);
                    _deactivate(c);
                }
            }
        }
    }

    function _activatePending() internal {
        uint256 len = _pendingIds.length;
        for (uint256 i; i < len; i++) {
            uint32 id = _pendingIds[i];
            Node storage n = _nodes[id];
            n.pending = false;
            n.active = true;
            _pendingKids[n.parent]--;
            _attach(n.parent, id);
            emit NodeActivated(id);
        }
        delete _pendingIds;
    }

    /// @dev Active branches in depth-first order, starting at the root.
    function _activeBranches() internal view returns (uint32[] memory out, uint256 n) {
        uint256 cap = liveNodes;
        out = new uint32[](cap);
        uint32[] memory stack = new uint32[](cap);
        uint256 sp = 1; // stack[0] == 0 (root)
        while (sp > 0) {
            uint32 id = stack[--sp];
            if (_nodes[id].recipient != address(0)) continue;
            out[n++] = id;
            uint32[] storage ks = _kids[id];
            for (uint256 i; i < ks.length; i++) stack[sp++] = ks[i];
        }
    }

    function _checkSum(uint16[] calldata bps) internal pure {
        uint256 sum;
        for (uint256 i; i < bps.length; i++) sum += bps[i];
        if (sum != 10_000) revert BadWeights();
    }

    function _bondToken() internal view returns (IERC20 t) {
        t = IERC20(staking.token());
        if (address(t) == address(0)) revert TokenNotSet();
    }

    // ================================================================ internals: epochs

    function _requestDraw() internal {
        seedBlock = block.number + _params.drawDelay;
        drawPending = true;
        staking.setDrawPending(true);
        emit DrawRequested(epoch, seedBlock);
    }

    function _finalize(uint256 e, uint32 id) internal {
        uint16[][] storage vs = _votes[e][id];
        uint256 nv = vs.length;
        uint256 nk = _kids[id].length;
        if (nv == 0 || nk == 0) return;
        uint256 valid;
        for (uint256 v; v < nv; v++) {
            if (vs[v].length == nk) valid++;
        }
        if (valid == 0) return;
        uint256[] memory med = new uint256[](nk);
        uint16[] memory col = new uint16[](valid);
        for (uint256 c; c < nk; c++) {
            uint256 j;
            for (uint256 v; v < nv; v++) {
                if (vs[v].length == nk) col[j++] = vs[v][c];
            }
            med[c] = Median.median(col);
        }
        uint16[] memory w = Median.normalize(med);
        _weights[id] = w;
        emit WeightsFinalized(e, id, w);
    }

    function _distribute(uint256 e) internal returns (uint256 distributed) {
        uint256 bal = weth.balanceOf(address(this));
        uint256 available = bal - totalOwed;
        if (available == 0) return 0;
        uint256 before = totalOwed;
        _flow(e, 0, available);
        distributed = totalOwed - before;
    }

    function _flow(uint256 e, uint32 id, uint256 amount) internal {
        Node storage n = _nodes[id];
        if (n.recipient != address(0)) {
            owed[n.recipient] += amount;
            totalOwed += amount;
            emit Credited(e, id, n.recipient, amount);
            return;
        }
        uint32[] storage ks = _kids[id];
        if (ks.length == 0) return;
        uint256 rest = amount;
        address[] storage vr = _voters[e][id];
        uint256 nv = vr.length;
        if (nv > 0 && _params.voterPayBps > 0) {
            uint256 each = (amount * _params.voterPayBps / 10_000) / nv;
            if (each > 0) {
                for (uint256 i; i < nv; i++) {
                    owed[vr[i]] += each;
                    emit VoterPaid(e, id, vr[i], each);
                }
                totalOwed += each * nv;
                rest -= each * nv;
            }
        }
        uint16[] storage ws = _weights[id];
        for (uint256 i; i < ks.length; i++) {
            uint256 part = rest * ws[i] / 10_000;
            if (part > 0) _flow(e, ks[i], part);
        }
    }

    function _updateStreaks(uint32[] memory br, uint256 nb) internal {
        for (uint256 b; b < nb; b++) {
            uint32[] storage ks = _kids[br[b]];
            uint16[] storage ws = _weights[br[b]];
            for (uint256 i; i < ks.length; i++) {
                Node storage c = _nodes[ks[i]];
                if (c.proposer == address(0)) continue;
                if (ws[i] == 0) {
                    if (c.zeroStreak < type(uint8).max) c.zeroStreak++;
                } else {
                    c.zeroStreak = 0;
                    c.everFunded = true;
                }
            }
        }
    }
}
