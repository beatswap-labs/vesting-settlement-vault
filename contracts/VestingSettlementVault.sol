// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol"; 
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/Pausable.sol"; 

contract VestingSettlementVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Primary settlement token (staking + vesting payouts)
    IERC20 public immutable BTX;
    
    /// @dev Multiplier denominator (e.g. 10980 = 1.098x)
    uint256 public constant DENOMINATOR = 10000; 
    
    /// @notice Total number of pools created
    uint256 public poolCount;

    /// @notice Max vesting positions scanned per claim call (default 200)
    uint256 public claimBatchLimit;

    struct GlobalStats {
        uint256 totalVestedBase;    // Sum of base amounts (principal)
        uint256 totalCommittedAmount;    // Sum of total vesting amounts (principal included)
        uint256 totalClaimed;    // Total claimed from vault
    }
    GlobalStats public globalStats;

    struct PoolInfo {
        string name;            
        bool isStaking;    // true: stake() pool, false: merkle-based pools
        uint256 currentRoundId;    // starts at 1
        uint256 totalFunded;    // BTX deposited by owner for settlement
        uint256 currentDuration;    // current round duration (for UI/view sync)
        uint256 currentMultiplier;    // current round multiplier (for UI/view sync)
        uint256 poolTotalVestedBase;   
        uint256 poolTotalCommittedAmount; 
        uint256 poolTotalClaimed;      
    }

    struct RoundInfo {
        bytes32 merkleRoot;    // only used for non-staking rounds
        uint256 duration;    // vesting duration in seconds
        uint256 multiplier;    // total = base * multiplier / DENOMINATOR
        bool isPaused;    // round-level pause
        uint256 totalEligibleUsers;   // hard cap (operational control)
        uint256 joinedUsers;    // number of users who started vesting
    }

    struct UserVesting {
        uint256 baseAmount;    // principal (stake or base allocation)
        uint256 startTime;    // vesting start timestamp
        uint256 duration;    // vesting duration in seconds
        uint256 releasedAmount;    // already claimed amount
        uint256 roundId;    // round identifier
        uint256 multiplier;    // snapshot multiplier for this vesting entry
        bool isCompleted;    // true when fully vested & removed from active list
    }

    struct DashboardItem {
        uint256 poolId;
        string poolName;
        uint256 roundId;
        uint256 baseAmount;
        uint256 totalVestingAmount;    // total = principal + reward
        uint256 releasedAmount;
        uint256 claimableNow;
        uint256 remaining;
        uint256 startTime;
        uint256 endTime;
        uint256 multiplier;
        bool isCompleted;
    }

    struct GlobalStatsView {
        uint256 totalVestedBase;
        uint256 totalCommittedAmount; 
        uint256 totalClaimed;
        uint256 totalOutstanding;    // committed - claimed
        uint256 vaultBalance;    // BTX balance in vault
        uint256 solvencyGap;    // outstanding - balance (if positive)
    }

    struct PoolViewInfo {
        uint256 poolId;
        string name;
        bool isStaking;
        uint256 currentRoundId;
        uint256 totalFunded;
        uint256 currentDuration;
        uint256 currentMultiplier;
        uint256 roundTotalUsers;    // non-staking only (staking rounds store 0)
        uint256 roundJoinedUsers;    // non-staking only (staking rounds store 0)
        uint256 poolTotalBase;
        uint256 poolTotalCommittedAmount; 
        uint256 poolTotalClaimed;
        uint256 poolOutstanding; 
    }

    mapping(uint256 => PoolInfo) public pools;
    mapping(uint256 => mapping(uint256 => RoundInfo)) public rounds; 
    
    /// @dev Prevents double-join for a specific (user,pool,round)
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) public hasUserJoinedRound;
    
    /// @dev Full vesting history per user per pool
    mapping(address => mapping(uint256 => UserVesting[])) public userVestingHistory;
    
    /// @dev Active vesting indices per user per pool (swap-pop on completion)
    mapping(address => mapping(uint256 => uint256[])) public userActiveVestingIndices;
    
    /// @dev One merkle root can be used only once per pool
    mapping(uint256 => mapping(bytes32 => bool)) public usedRoots;
    
    /// @dev Per-user scan cursor per pool for gas-bounded batch claiming
    mapping(address => mapping(uint256 => uint256)) public userClaimCursors;

    event PoolCreated(uint256 indexed poolId, string name, bool isStaking);
    event RoundRegistered(uint256 indexed poolId, uint256 indexed roundId, bytes32 root, uint256 duration, uint256 multiplier, uint256 totalUsers);
    event StakingRoundUpdated(uint256 indexed poolId, uint256 indexed newRoundId, uint256 newDuration, uint256 newMultiplier);
    event VestingStarted(address indexed user, uint256 indexed poolId, uint256 indexed roundId, uint256 baseAmount, uint256 duration, uint256 multiplier);
    event Staked(address indexed user, uint256 indexed poolId, uint256 indexed roundId, uint256 amount, uint256 duration, uint256 multiplier);
    event RewardClaimed(address indexed user, uint256 totalAmount);
    event FundDeposited(uint256 indexed poolId, uint256 amount);
    event RoundStatusChanged(uint256 indexed poolId, uint256 indexed roundId, bool isPaused);
    event AdminTokenRecovered(address tokenAddress, uint256 amount);
    event ClaimBatchLimitUpdated(uint256 newLimit);

    error InvalidPoolId();
    error InvalidProof();
    error InvalidRoundId();
    error AlreadyJoinedRound();
    error NothingToClaim();
    error ZeroAmount();
    error RootAlreadyUsed();
    error RoundPaused();
    error NotStakingPool();
    error IsStakingPool();
    error InvalidBatchLimit();
    error ZeroRoot();
    error ZeroDuration();
    error ZeroMultiplier();
    error ZeroTotalUsers();
    error ZeroAddress(); 
    error MaxParticipantsReached();

    constructor(address initialOwner, address btxAddress) Ownable(initialOwner) {
        if (btxAddress == address(0)) revert ZeroAddress();
        BTX = IERC20(btxAddress);

        /// @dev Default max scan per claim call
        claimBatchLimit = 200;

        /// @dev Staking pool: 365 days linear vesting, 9.8% APR => 1.098x total vesting amount
        createPool("Staking and Community Rewards", true, 365 days, 10980); 
        
        /// @dev Non-staking pools are merkle-based; rounds will be registered later
        createPool("IP-Rights Acquisition", false, 0, 0);       
        createPool("Retroactive IP-Rights Acquisition", false, 0, 0);     
        createPool("Licensing to Earn", false, 0, 0);        
        createPool("Whitelist", false, 0, 0);   
    }

    /// @notice Emergency stop for user flows
    function pause() external onlyOwner { _pause(); }
    
    /// @notice Resume user flows
    function unpause() external onlyOwner { _unpause(); }

    function setClaimBatchLimit(uint256 newLimit) external onlyOwner {
        /// @dev Safety bounds for predictable gas usage
        if (newLimit == 0 || newLimit > 500) revert InvalidBatchLimit();
        claimBatchLimit = newLimit;
        emit ClaimBatchLimitUpdated(newLimit);
    }

    function createPool(string memory name, bool isStaking, uint256 initialDuration, uint256 initialMultiplier) public onlyOwner {
        uint256 poolId = poolCount;
        
        /// @dev Staking starts at round 1; non-staking rounds start from 1 after registerRound()
        uint256 startRound = isStaking ? 1 : 0;
        
        pools[poolId] = PoolInfo({
            name: name,
            isStaking: isStaking,
            currentRoundId: startRound,
            totalFunded: 0,
            currentDuration: initialDuration,
            currentMultiplier: initialMultiplier,
            poolTotalVestedBase: 0,
            poolTotalCommittedAmount: 0,
            poolTotalClaimed: 0
        });
        poolCount++;
        emit PoolCreated(poolId, name, isStaking);
        
        /// @dev Staking rounds are updated via updateStakingRound(); merkleRoot is unused for staking
        if (isStaking) {
            _updateStakingRoundInternal(poolId, 1, initialDuration, initialMultiplier);
        }
    }

    function registerRound(
        uint256 poolId, 
        bytes32 root, 
        uint256 duration, 
        uint256 multiplier, 
        uint256 totalUsers 
    ) external onlyOwner {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (pools[poolId].isStaking) revert IsStakingPool();

        if (root == bytes32(0)) revert ZeroRoot();
        if (duration == 0) revert ZeroDuration();
        if (multiplier == 0) revert ZeroMultiplier();
        if (totalUsers == 0) revert ZeroTotalUsers();
        
        /// @dev Prevent reusing the same merkle root within a pool
        if (usedRoots[poolId][root]) revert RootAlreadyUsed();

        pools[poolId].currentRoundId++;
        uint256 newRoundId = pools[poolId].currentRoundId;

        /// @dev Keep pool-level duration/multiplier synced for view/UI
        pools[poolId].currentDuration = duration;
        pools[poolId].currentMultiplier = multiplier;

        rounds[poolId][newRoundId] = RoundInfo({
            merkleRoot: root,
            duration: duration,
            multiplier: multiplier,
            isPaused: false,
            totalEligibleUsers: totalUsers, 
            joinedUsers: 0                
        });

        usedRoots[poolId][root] = true;
        emit RoundRegistered(poolId, newRoundId, root, duration, multiplier, totalUsers);
    }

    function updateStakingRound(uint256 poolId, uint256 newDuration, uint256 newMultiplier) external onlyOwner {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (!pools[poolId].isStaking) revert NotStakingPool();

        if (newDuration == 0) revert ZeroDuration();
        if (newMultiplier == 0) revert ZeroMultiplier();

        /// @dev Each update creates a new staking round id
        pools[poolId].currentRoundId++;
        _updateStakingRoundInternal(poolId, pools[poolId].currentRoundId, newDuration, newMultiplier);
    }

    function _updateStakingRoundInternal(uint256 poolId, uint256 roundId, uint256 duration, uint256 multiplier) internal {
        pools[poolId].currentDuration = duration;
        pools[poolId].currentMultiplier = multiplier;

        /// @dev merkleRoot is unused for staking rounds
        rounds[poolId][roundId] = RoundInfo({
            merkleRoot: bytes32(0), 
            duration: duration,
            multiplier: multiplier,
            isPaused: false,
            totalEligibleUsers: 0,
            joinedUsers: 0
        });

        emit StakingRoundUpdated(poolId, roundId, duration, multiplier);
    }

    function setRoundPaused(uint256 poolId, uint256 roundId, bool paused) external onlyOwner {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (roundId == 0 || roundId > pools[poolId].currentRoundId) revert InvalidRoundId();
        if (rounds[poolId][roundId].duration == 0) revert InvalidRoundId();
        
        rounds[poolId][roundId].isPaused = paused;
        emit RoundStatusChanged(poolId, roundId, paused);
    }

    function depositFund(uint256 poolId, uint256 amount) external onlyOwner {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (amount == 0) revert ZeroAmount();
        
        /// @dev Owner supplies BTX to cover vesting settlements
        BTX.safeTransferFrom(msg.sender, address(this), amount);
        pools[poolId].totalFunded += amount;
        emit FundDeposited(poolId, amount);
    }

    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner whenNotPaused {
        if (tokenAddress == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        
        /// @dev Admin recovery (including BTX) under multisig policy; only when not paused
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
        emit AdminTokenRecovered(tokenAddress, amount);
    }

    function startVesting(uint256 poolId, uint256 roundId, uint256 baseAmount, bytes32[] calldata proof) external nonReentrant whenNotPaused {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (pools[poolId].isStaking) revert IsStakingPool();
        if (baseAmount == 0) revert ZeroAmount();
        
        RoundInfo storage round = rounds[poolId][roundId];
        if (round.duration == 0) revert InvalidRoundId();
        if (round.isPaused) revert RoundPaused();

        /// @dev One-time join per (user,pool,round)
        if (hasUserJoinedRound[msg.sender][poolId][roundId]) revert AlreadyJoinedRound();

        /// @dev Hard cap by admin-provided eligible user count
        if (round.joinedUsers >= round.totalEligibleUsers) revert MaxParticipantsReached();

        /// @dev Leaf format must match off-chain merkle tree construction
        bytes32 leaf = keccak256(abi.encode(msg.sender, poolId, roundId, baseAmount));
        if (!MerkleProof.verify(proof, round.merkleRoot, leaf)) revert InvalidProof();

        hasUserJoinedRound[msg.sender][poolId][roundId] = true;
        round.joinedUsers++;

        _addVesting(poolId, baseAmount, round.duration, roundId, round.multiplier);
        emit VestingStarted(msg.sender, poolId, roundId, baseAmount, round.duration, round.multiplier);
    }

    function stake(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
        if (poolId >= poolCount) revert InvalidPoolId();
        if (!pools[poolId].isStaking) revert NotStakingPool();
        if (amount == 0) revert ZeroAmount();
        
        uint256 currentRoundId = pools[poolId].currentRoundId;
        RoundInfo storage round = rounds[poolId][currentRoundId];

        if (round.isPaused) revert RoundPaused();
        
        /// @dev Stake transfers BTX into the vault; withdrawal is via linear vesting claims
        BTX.safeTransferFrom(msg.sender, address(this), amount);
        
        _addVesting(poolId, amount, round.duration, currentRoundId, round.multiplier);
        emit Staked(msg.sender, poolId, currentRoundId, amount, round.duration, round.multiplier);
    }

    function _addVesting(uint256 poolId, uint256 amount, uint256 duration, uint256 roundId, uint256 multiplier) internal {
        userVestingHistory[msg.sender][poolId].push(UserVesting({
            baseAmount: amount,
            startTime: block.timestamp,
            duration: duration,
            releasedAmount: 0,
            roundId: roundId, 
            multiplier: multiplier,
            isCompleted: false
        }));

        uint256 idx = userVestingHistory[msg.sender][poolId].length - 1;
        
        /// @dev Track active vesting entries for gas-bounded claiming
        userActiveVestingIndices[msg.sender][poolId].push(idx);

        /// @dev Total vesting amount includes principal + reward
        uint256 totalVestingAmount = (amount * multiplier) / DENOMINATOR;
        
        globalStats.totalVestedBase += amount;
        globalStats.totalCommittedAmount += totalVestingAmount;

        pools[poolId].poolTotalVestedBase += amount;
        pools[poolId].poolTotalCommittedAmount += totalVestingAmount;
    }

    function claimSinglePool(uint256 poolId, uint256 limit) external nonReentrant whenNotPaused {
        if (poolId >= poolCount) revert InvalidPoolId();
        
        /// @dev Caller can lower scan count; otherwise default to claimBatchLimit
        uint256 batchSize = limit;
        if (batchSize == 0 || batchSize > claimBatchLimit) {
            batchSize = claimBatchLimit;
        }

        (, uint256 payout) = _claimProcess(poolId, batchSize);
        
        if (payout == 0) revert NothingToClaim();

        globalStats.totalClaimed += payout;
        BTX.safeTransfer(msg.sender, payout);
        emit RewardClaimed(msg.sender, payout);
    }

    function claimVested() external nonReentrant whenNotPaused {
        uint256 limit = claimBatchLimit;
        uint256 scannedTotal = 0; 
        uint256 totalPayout = 0;

        /// @dev Scan pools until reaching claimBatchLimit across all pools
        for (uint256 i = 0; i < poolCount; i++) {
            if (scannedTotal >= limit) break;
            
            (uint256 scannedInPool, uint256 payoutInPool) = _claimProcess(i, limit - scannedTotal);
            
            scannedTotal += scannedInPool;
            totalPayout += payoutInPool;
        }
        
        if (totalPayout == 0) revert NothingToClaim(); 

        globalStats.totalClaimed += totalPayout;
        BTX.safeTransfer(msg.sender, totalPayout);
        emit RewardClaimed(msg.sender, totalPayout);
    }

    function _claimProcess(uint256 poolId, uint256 limit) internal returns (uint256 scanned, uint256 amount) {
        uint256 scannedCount = 0;
        uint256 totalToTransfer = 0;

        uint256[] storage activeIndices = userActiveVestingIndices[msg.sender][poolId];
        uint256 len = activeIndices.length;
        if (len == 0) return (0, 0);

        uint256 cursor = userClaimCursors[msg.sender][poolId];
        uint256 maxScan = (limit > len) ? len : limit;

        /// @dev Round-robin scan over active entries to avoid O(n) claims on large histories
        for (uint256 k = 0; k < maxScan; k++) {
            if (activeIndices.length == 0) break; 
            
            if (cursor >= activeIndices.length) {
                cursor = 0;
            }

            scannedCount++;

            (uint256 claimableNow, uint256 nextCursor) = _processSingleVesting(poolId, activeIndices, cursor);
            
            totalToTransfer += claimableNow;
            cursor = nextCursor;
        }
        userClaimCursors[msg.sender][poolId] = cursor;

        return (scannedCount, totalToTransfer);
    }

    function _processSingleVesting(
        uint256 poolId,
        uint256[] storage activeIndices,
        uint256 cursor
    ) internal returns (uint256 claimableNow, uint256 nextCursor) {
        uint256 idx = activeIndices[cursor];
        UserVesting storage v = userVestingHistory[msg.sender][poolId][idx];

        uint256 totalVestingAmount = (v.baseAmount * v.multiplier) / DENOMINATOR;
        
        if (block.timestamp <= v.startTime) {
            return (0, cursor + 1);
        }

        uint256 currentVestable = _calculateLinearVesting(v.startTime, v.duration, totalVestingAmount);
        
        /// @dev Underflow guard for claimable calculation
        if (currentVestable <= v.releasedAmount) {
            return (0, cursor + 1);
        }

        claimableNow = currentVestable - v.releasedAmount;

        if (claimableNow > 0) {
            v.releasedAmount += claimableNow;
            pools[poolId].poolTotalClaimed += claimableNow;
        }

        /// @dev Remove completed vesting entry from active list (swap-pop)
        if (v.releasedAmount == totalVestingAmount) {
            v.isCompleted = true;
            activeIndices[cursor] = activeIndices[activeIndices.length - 1];
            activeIndices.pop();
            return (claimableNow, cursor); 
        } else {
            return (claimableNow, cursor + 1);
        }
    }

    function _calculateLinearVesting(uint256 startTime, uint256 duration, uint256 totalAmount) internal view returns (uint256) {
        if (block.timestamp <= startTime) return 0;
        uint256 elapsedTime = block.timestamp - startTime;
        
        /// @dev Fully vested after duration
        if (elapsedTime >= duration) return totalAmount; 
        
        /// @dev Linear per-second vesting
        return (totalAmount * elapsedTime) / duration;
    }

    function getClaimableAmount(address user) external view returns (uint256 totalClaimable) {
        totalClaimable = 0;

        /// @dev Full scan; front-end should prefer paginated dashboard if user has many positions
        for (uint256 i = 0; i < poolCount; i++) {
            uint256[] storage activeIndices = userActiveVestingIndices[user][i];
            uint256 len = activeIndices.length;

            for (uint256 j = 0; j < len; j++) {
                uint256 idx = activeIndices[j];
                UserVesting storage v = userVestingHistory[user][i][idx];

                if (block.timestamp <= v.startTime) {
                    continue;
                }

                uint256 totalVestingAmount = (v.baseAmount * v.multiplier) / DENOMINATOR;
                uint256 currentVestable = _calculateLinearVesting(v.startTime, v.duration, totalVestingAmount);

                if (currentVestable > v.releasedAmount) {
                    totalClaimable += (currentVestable - v.releasedAmount);
                }
            }
        }
        return totalClaimable;
    }

    function getGlobalStats() external view returns (GlobalStatsView memory viewData) {
        GlobalStats memory stats = globalStats;
        uint256 bal = BTX.balanceOf(address(this));
        
        uint256 outstanding = (stats.totalCommittedAmount > stats.totalClaimed) 
            ? (stats.totalCommittedAmount - stats.totalClaimed) 
            : 0;
            
        uint256 gap = (outstanding > bal) ? (outstanding - bal) : 0;

        return GlobalStatsView({
            totalVestedBase: stats.totalVestedBase,
            totalCommittedAmount: stats.totalCommittedAmount, 
            totalClaimed: stats.totalClaimed,
            totalOutstanding: outstanding,
            vaultBalance: bal,
            solvencyGap: gap
        });
    }

    function getUserVestingCountByPool(address user, uint256 poolId) external view returns (uint256) {
        return userVestingHistory[user][poolId].length;
    }

    function getAllPoolsInfo() external view returns (PoolViewInfo[] memory) {
        PoolViewInfo[] memory info = new PoolViewInfo[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            PoolInfo storage p = pools[i];
            
            uint256 duration = p.currentDuration;
            uint256 multiplier = p.currentMultiplier;
            uint256 rTotal = 0;
            uint256 rClaimed = 0;

            if (p.currentRoundId > 0) {
                RoundInfo storage r = rounds[i][p.currentRoundId];
                duration = r.duration;
                multiplier = r.multiplier;
                rTotal = r.totalEligibleUsers; 
                rClaimed = r.joinedUsers;     
            }
            
            uint256 outstanding = (p.poolTotalCommittedAmount > p.poolTotalClaimed) 
                ? (p.poolTotalCommittedAmount - p.poolTotalClaimed) 
                : 0;

            info[i] = PoolViewInfo(
                i, p.name, p.isStaking, p.currentRoundId, p.totalFunded, duration, multiplier, rTotal, rClaimed,
                p.poolTotalVestedBase, p.poolTotalCommittedAmount, p.poolTotalClaimed, outstanding
            );
        }
        return info;
    }

    function getUserPoolRoundStatus(address user, uint256 poolId) external view returns (uint256 currentRoundId, bool[] memory isJoined) {
        /// @dev Staking pool does not use merkle join flags
        if (pools[poolId].isStaking) return (0, new bool[](0));
        currentRoundId = pools[poolId].currentRoundId;
        isJoined = new bool[](currentRoundId);
        for (uint256 i = 0; i < currentRoundId; i++) {
            isJoined[i] = hasUserJoinedRound[user][poolId][i + 1];
        }
    }

    function getUserDetailedDashboard(address user, uint256 offset, uint256 limit) external view returns (DashboardItem[] memory items, uint256 total) {
        total = 0;
        for (uint256 i = 0; i < poolCount; i++) {
            total += userVestingHistory[user][i].length;
        }

        if (offset >= total) {
            return (new DashboardItem[](0), total);
        }

        uint256 count = limit;
        if (offset + count > total) {
            count = total - offset;
        }

        items = new DashboardItem[](count);
        uint256 currentGlobalIdx = 0;
        uint256 itemsIdx = 0;

        for (uint256 i = 0; i < poolCount; i++) {
            UserVesting[] storage history = userVestingHistory[user][i];
            uint256 len = history.length;
            
            if (currentGlobalIdx + len > offset) {
                uint256 startLocal = (offset > currentGlobalIdx) ? (offset - currentGlobalIdx) : 0;
                
                for (uint256 j = startLocal; j < len; j++) {
                    if (itemsIdx >= count) break;

                    UserVesting storage v = history[j];
                    string memory pName = pools[i].name;
                    
                    uint256 totalVestingAmount = (v.baseAmount * v.multiplier) / DENOMINATOR;
                    uint256 currentVestable = _calculateLinearVesting(v.startTime, v.duration, totalVestingAmount);

                    uint256 remaining = (totalVestingAmount > v.releasedAmount) ? (totalVestingAmount - v.releasedAmount) : 0;

                    items[itemsIdx] = DashboardItem({
                        poolId: i,
                        poolName: pName,
                        roundId: v.roundId,
                        baseAmount: v.baseAmount,
                        totalVestingAmount: totalVestingAmount,
                        releasedAmount: v.releasedAmount,
                        claimableNow: (currentVestable > v.releasedAmount) ? (currentVestable - v.releasedAmount) : 0,
                        remaining: remaining,
                        startTime: v.startTime,
                        endTime: v.startTime + v.duration,
                        multiplier: v.multiplier,
                        isCompleted: v.isCompleted
                    });
                    itemsIdx++;
                }
            }
            currentGlobalIdx += len;
            if (itemsIdx >= count) break;
        }
    }
}
