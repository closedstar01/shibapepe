// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ShibaPepe Staking Contract
 * @dev Staking functionality - 2 Plans
 * @notice For Base Network only
 * @custom:security-note SHPE token must not be a fee-on-transfer or rebasing token.
 *         This contract assumes transfer amounts equal recorded amounts.
 * @custom:security-note Uses Ownable2Step for safer ownership transfer
 *
 * Plans:
 * - Plan 0: Flexible - 15% APY, no lock
 * - Plan 1: 6-month Lock - 80% APY, 180-day lock
 */
contract ShibaPepeStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== Token =====
    IERC20 public shpeToken;

    // ===== Constants =====
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MAX_APY_BASIS_POINTS = 100000; // 1000% max APY to prevent overflow
    uint256 public constant MIN_STAKE_AMOUNT = 100 * 1e18; // 100 SHPE minimum stake

    // ===== Plan Configuration =====
    struct StakingPlan {
        string name;           // Plan name
        uint256 lockDuration;  // Lock duration (seconds)
        uint256 apyBasisPoints; // Annual rate (10000 = 100%)
        uint256 bonusRate;     // Bonus rate (10000 = 100%)
        bool isActive;         // Active flag
    }

    mapping(uint256 => StakingPlan) public stakingPlans;
    uint256 public planCount;

    // ===== User Stake Info =====
    struct Stake {
        uint256 amount;           // Staked amount
        uint256 planId;           // Plan ID
        uint256 startTime;        // Stake start time
        uint256 lockEndTime;      // Lock end time
        uint256 lastClaimTime;    // Last reward claim time
        bool isActive;            // Active flag
    }

    // User address => Stake ID => Stake info
    mapping(address => mapping(uint256 => Stake)) public userStakes;
    // User address => Stake count
    mapping(address => uint256) public userStakeCount;

    // ===== Statistics =====
    uint256 public totalStaked;              // Total staked amount
    uint256 public totalRewardsPaid;         // Total rewards paid
    uint256 public rewardPool;               // Reward pool balance

    // ===== Events =====
    event Staked(address indexed user, uint256 stakeId, uint256 amount, uint256 planId);
    event Unstaked(address indexed user, uint256 stakeId, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 stakeId, uint256 reward);
    event RewardPoolFunded(uint256 amount);
    event PlanUpdated(uint256 planId, uint256 apyBasisPoints, uint256 bonusRate, bool isActive);
    event EmergencyRewardPoolWithdrawn(address indexed to, uint256 amount);

    // ===== Constructor =====
    /**
     * @notice Initializes the staking contract with SHPE token
     * @param _shpeToken Address of the SHPE token contract
     */
    constructor(address _shpeToken) Ownable(msg.sender) {
        require(_shpeToken != address(0), "Invalid token address");
        shpeToken = IERC20(_shpeToken);

        // Plan 0: Flexible (15% APY, no lock)
        stakingPlans[0] = StakingPlan({
            name: "Flexible",
            lockDuration: 0,
            apyBasisPoints: 1500,  // 15%
            bonusRate: 0,
            isActive: true
        });

        // Plan 1: 6-month Lock (80% APY, 180-day lock)
        stakingPlans[1] = StakingPlan({
            name: "6-month Lock",
            lockDuration: 15552000, // 180 days * 86400 seconds
            apyBasisPoints: 8000,   // 80%
            bonusRate: 0,           // No bonus
            isActive: true
        });

        planCount = 2;
    }

    // ===== User Functions =====

    /**
     * @dev Stake tokens
     * @param amount Amount to stake
     * @param planId Plan ID (0 or 1)
     * @notice PUBLIC FUNCTION - Users call this directly to stake tokens.
     *         No access control is required as this is a user-facing function.
     * @custom:security-note Access control intentionally omitted - user-facing function
     */
    function stake(uint256 amount, uint256 planId) external nonReentrant {
        require(amount >= MIN_STAKE_AMOUNT, "Below minimum stake amount");
        require(planId < planCount, "Invalid plan ID");
        require(stakingPlans[planId].isActive, "Plan is not active");

        // Transfer tokens
        shpeToken.safeTransferFrom(msg.sender, address(this), amount);

        // Create stake info
        uint256 stakeId = userStakeCount[msg.sender];
        StakingPlan memory plan = stakingPlans[planId];

        userStakes[msg.sender][stakeId] = Stake({
            amount: amount,
            planId: planId,
            startTime: block.timestamp,
            lockEndTime: block.timestamp + plan.lockDuration,
            lastClaimTime: block.timestamp,
            isActive: true
        });

        userStakeCount[msg.sender]++;
        totalStaked += amount;

        emit Staked(msg.sender, stakeId, amount, planId);
    }

    /**
     * @dev Unstake (after lock period ends)
     * @param stakeId Stake ID
     * @notice PUBLIC FUNCTION - Users call this directly to unstake tokens.
     *         Principal is always returned even if reward pool is insufficient.
     * @custom:security-note Access control intentionally omitted - user-facing function
     */
    function unstake(uint256 stakeId) external nonReentrant {
        Stake storage userStake = userStakes[msg.sender][stakeId];
        require(userStake.isActive, "Stake is not active");
        require(block.timestamp >= userStake.lockEndTime, "Still locked");

        // Calculate reward
        uint256 reward = _calculateReward(msg.sender, stakeId);

        // Add bonus (on lock period completion)
        uint256 bonus = 0;
        uint256 planBonusRate = stakingPlans[userStake.planId].bonusRate;
        if (planBonusRate != 0) {
            bonus = (userStake.amount * planBonusRate) / 10000;
        }

        // If reward pool is insufficient, pay what's available
        uint256 totalRewardRequested = reward + bonus;
        uint256 actualReward = totalRewardRequested;
        if (rewardPool < totalRewardRequested) {
            actualReward = rewardPool; // Pay what's available
        }

        // Principal + actual reward
        uint256 totalAmount = userStake.amount + actualReward;
        require(totalAmount != 0, "Nothing to withdraw");

        // Update stake info
        userStake.isActive = false;
        totalStaked -= userStake.amount;
        rewardPool -= actualReward;
        totalRewardsPaid += actualReward;

        // Return tokens (principal is always returned)
        shpeToken.safeTransfer(msg.sender, totalAmount);

        emit Unstaked(msg.sender, stakeId, userStake.amount, actualReward);
    }

    /**
     * @dev Claim reward only (stake continues)
     * @param stakeId Stake ID
     * @notice PUBLIC FUNCTION - Users call this directly to claim rewards.
     *         If reward pool is insufficient, pays available amount and advances
     *         lastClaimTime proportionally to preserve unpaid rewards.
     * @custom:security-note Access control intentionally omitted - user-facing function
     * @custom:security-note Uses proportional time advancement to track unpaid rewards
     */
    function claimReward(uint256 stakeId) external nonReentrant {
        Stake storage userStake = userStakes[msg.sender][stakeId];
        require(userStake.isActive, "Stake is not active");

        uint256 reward = _calculateReward(msg.sender, stakeId);
        require(reward != 0, "No reward to claim");

        // If reward pool is insufficient, pay what's available
        uint256 actualReward = reward;
        uint256 timeElapsed = block.timestamp - userStake.lastClaimTime;

        if (rewardPool < reward) {
            actualReward = rewardPool;
        }

        require(actualReward != 0, "Reward pool is empty");

        // Update reward info - advance lastClaimTime proportionally
        // This preserves unpaid rewards for future claims
        if (actualReward < reward && reward != 0) {
            // Partial payment: advance time proportionally
            uint256 timeToAdvance = (timeElapsed * actualReward) / reward;
            userStake.lastClaimTime += timeToAdvance;
        } else {
            // Full payment: advance to current time
            userStake.lastClaimTime = block.timestamp;
        }

        rewardPool -= actualReward;
        totalRewardsPaid += actualReward;

        // Send reward
        shpeToken.safeTransfer(msg.sender, actualReward);

        emit RewardClaimed(msg.sender, stakeId, actualReward);
    }

    // ===== Internal Functions =====

    /**
     * @dev Calculate reward (real-time per second)
     * @param user User address
     * @param stakeId Stake ID
     * @return Calculated reward amount
     * @custom:security-note Precision loss is negligible for 18-decimal tokens with large stakes
     */
    function _calculateReward(address user, uint256 stakeId) internal view returns (uint256) {
        Stake memory userStake = userStakes[user][stakeId];
        if (!userStake.isActive) return 0;

        uint256 apyBasisPoints = stakingPlans[userStake.planId].apyBasisPoints;
        uint256 timeElapsed = block.timestamp - userStake.lastClaimTime;

        // Reward = Principal * APY * Time Elapsed / 1 Year
        uint256 reward = (userStake.amount * apyBasisPoints * timeElapsed) / (SECONDS_PER_YEAR * 10000);

        return reward;
    }

    // ===== View Functions =====

    /**
     * @dev Get pending reward
     * @param user User address
     * @param stakeId Stake ID
     * @return Pending reward amount
     */
    function getPendingReward(address user, uint256 stakeId) external view returns (uint256) {
        return _calculateReward(user, stakeId);
    }

    /**
     * @dev Get all stake info for a user
     * @param user User address
     * @return stakes Array of user's stakes
     */
    function getUserStakes(address user) external view returns (Stake[] memory) {
        uint256 count = userStakeCount[user];
        Stake[] memory stakes = new Stake[](count);

        for (uint256 i = 0; i < count; i++) {
            stakes[i] = userStakes[user][i];
        }

        return stakes;
    }

    /**
     * @dev Get plan info
     * @param planId Plan ID
     * @return StakingPlan struct
     */
    function getPlanInfo(uint256 planId) external view returns (StakingPlan memory) {
        return stakingPlans[planId];
    }

    /**
     * @dev Get all plans info
     * @return plans Array of all staking plans
     */
    function getAllPlans() external view returns (StakingPlan[] memory) {
        StakingPlan[] memory plans = new StakingPlan[](planCount);
        for (uint256 i = 0; i < planCount; i++) {
            plans[i] = stakingPlans[i];
        }
        return plans;
    }

    /**
     * @dev Get staking statistics
     * @return _totalStaked Total amount staked
     * @return _totalRewardsPaid Total rewards paid out
     * @return _rewardPool Current reward pool balance
     */
    function getStakingStats() external view returns (
        uint256 _totalStaked,
        uint256 _totalRewardsPaid,
        uint256 _rewardPool
    ) {
        return (totalStaked, totalRewardsPaid, rewardPool);
    }

    // ===== Owner-Only Functions =====

    /**
     * @dev Fund reward pool
     * @param amount Amount to add to reward pool
     */
    function fundRewardPool(uint256 amount) external onlyOwner {
        require(amount != 0, "Amount must be greater than zero");
        shpeToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        emit RewardPoolFunded(amount);
    }

    /**
     * @dev Update plan
     * @param planId Plan ID to update
     * @param apyBasisPoints New APY in basis points (10000 = 100%)
     * @param bonusRate New bonus rate in basis points
     * @param isActive Whether the plan is active
     * @notice APY changes affect future reward calculations for existing stakes.
     *         Users can claim rewards periodically to lock in current rates.
     * @custom:security-note This is intentional design for operational flexibility
     * @custom:security-note APY is capped at MAX_APY_BASIS_POINTS to prevent overflow attacks
     */
    function updatePlan(
        uint256 planId,
        uint256 apyBasisPoints,
        uint256 bonusRate,
        bool isActive
    ) external onlyOwner {
        require(planId < planCount, "Invalid plan ID");
        require(apyBasisPoints <= MAX_APY_BASIS_POINTS, "APY exceeds maximum");
        require(bonusRate <= 10000, "Bonus rate exceeds 100%");
        stakingPlans[planId].apyBasisPoints = apyBasisPoints;
        stakingPlans[planId].bonusRate = bonusRate;
        stakingPlans[planId].isActive = isActive;
        emit PlanUpdated(planId, apyBasisPoints, bonusRate, isActive);
    }

    /**
     * @dev Emergency: Withdraw tokens from reward pool
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawRewardPool(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount != 0, "Amount must be greater than zero");
        require(amount <= rewardPool, "Amount exceeds reward pool");
        rewardPool -= amount;
        shpeToken.safeTransfer(to, amount);
        emit EmergencyRewardPoolWithdrawn(to, amount);
    }
}
