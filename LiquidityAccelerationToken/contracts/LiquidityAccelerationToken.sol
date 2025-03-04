// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// OpenZeppelin imports for ERC20 interface, access control, security, and cryptography.
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Interface for a mintable LAT token.
interface ILatToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Interface for a treasury vault that holds staked tokens.
interface ITreasuryVault {
    function withdraw(address recipient, uint256 amount) external;
}

/// @title LiquidityAccelerationToken
/// @notice This contract mimics a Solana Anchor program by implementing epoch‑based trading rewards,
/// off‑chain signature verification, staking (with vesting, weighted rewards, and inactivity slashing),
/// early withdrawal penalties, and a separate treasury vault for staked tokens.
/// It also includes reentrancy protection and an emergency pause.
contract LiquidityAccelerationToken is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    // ======================================
    // State Variables & Configurations
    // ======================================
    
    ILatToken public latToken;

    uint256 public tradeRewardRate;
    uint256 public stakeRewardRate;
    uint256 public totalTrades;
    uint256 public epochTradeVolume;
    uint256 public tradeEpochDuration; // in seconds for trade reward claims
    uint256 public poolTradingVolume;
    uint256 public poolVolumeThreshold;
    uint256 public poolBoostMultiplier;
    uint256 public earlyWithdrawalFee = 10; // 10% penalty for early withdrawals

    // Epoch-based rewards (checkpoint mechanism)
    uint256 public lastEpochBlock;
    uint256 public epochDuration; // in blocks (e.g. ~6500 blocks ~ 1 day)

    // Inactivity slashing parameters
    uint256 public inactivitySlashingTime = 30 days;
    uint256 public inactivityPenaltyRate = 20; // 20% slash if inactive

    // Maximum claimable reward per claim to prevent runaway minting.
    uint256 public maxClaimable = 1_000_000 * 10**18;

    // Emergency pause mechanism.
    bool public paused;

    // To ensure initialization happens only once.
    bool public initialized;

    // Nonces for replay protection in claim functions.
    mapping(address => uint256) public nonces;

    // Off-chain signature timestamp tracking.
    mapping(address => uint256) public lastSignedClaim;

    // Maker rebates and taker fees (for fee/rebate recording).
    mapping(address => uint256) public makerRebates;
    mapping(address => uint256) public takerFees;

    // Liquidity boost multipliers per trader (default 100 means no boost).
    mapping(address => uint256) public liquidityBoostMultiplier;

    // Trader statistics.
    struct TraderStats {
        uint256 tradeCount;
        uint256 totalVolume;
        uint256 pendingTradeRewards;
        uint256 lastClaim;
    }
    mapping(address => TraderStats) public traderStats;

    // Staking information.
    struct Stake {
        uint256 amount;
        uint256 lastUpdated;
        uint256 stakeStart;
    }
    mapping(address => Stake) public stakes;

    // Staked weight mapping to reward long-term stakers.
    mapping(address => uint256) public stakedWeight;

    // Vesting schedule structure for future extension.
    struct VestingEntry {
        uint256 totalReward;
        uint256 claimed;
        uint256 startTime;
        uint256 duration; // in seconds
    }
    mapping(address => VestingEntry[]) public vestingSchedules;

    // Treasury vault address where staked tokens are held.
    address public vaultAddress;

    // ======================================
    // Events
    // ======================================
    event TradeRecorded(address indexed trader, uint256 tradeVolume, bool isMaker);
    event TradeRewardsClaimed(address indexed trader, uint256 reward);
    event StakeLat(address indexed trader, uint256 amount);
    event StakeRewardsClaimed(address indexed trader, uint256 reward);
    event StakeWithdrawn(address indexed trader, uint256 amountAfterPenalty, uint256 penalty);
    event LiquidityMultiplierUpdated(address indexed trader, uint256 multiplier);
    event Paused(bool isPaused);

    // ======================================
    // Modifiers
    // ======================================
    
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    // ======================================
    // Constructor
    // ======================================
    constructor() Ownable(msg.sender) {}

    // ======================================
    // Initialization
    // ======================================
    
    /// @notice Initializes the global state. Can only be called once by the owner.
    /// @param _latToken The mintable LAT token.
    /// @param _tradeRewardRate Base reward rate for trades.
    /// @param _stakeRewardRate Base reward rate for staking.
    /// @param _tradeEpochDuration Duration (in seconds) for trade reward epochs.
    /// @param _poolVolumeThreshold Threshold to trigger liquidity pool boost.
    /// @param _poolBoostMultiplier Boost multiplier (in percentage) for staking rewards.
    /// @param _epochDuration Epoch duration in blocks (for checkpointing).
    /// @param _vaultAddress The treasury vault address to hold staked tokens.
    function initialize(
        ILatToken _latToken,
        uint256 _tradeRewardRate,
        uint256 _stakeRewardRate,
        uint256 _tradeEpochDuration,
        uint256 _poolVolumeThreshold,
        uint256 _poolBoostMultiplier,
        uint256 _epochDuration,
        address _vaultAddress
    ) external onlyOwner {
        require(!initialized, "Already initialized");
        latToken = _latToken;
        tradeRewardRate = _tradeRewardRate;
        stakeRewardRate = _stakeRewardRate;
        totalTrades = 0;
        epochTradeVolume = 0;
        tradeEpochDuration = _tradeEpochDuration;
        poolTradingVolume = 0;
        poolVolumeThreshold = _poolVolumeThreshold;
        poolBoostMultiplier = _poolBoostMultiplier;
        epochDuration = _epochDuration;
        lastEpochBlock = block.number;
        vaultAddress = _vaultAddress;
        initialized = true;
    }

    /// @notice Emergency pause function to disable critical functions.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    // ======================================
    // Trade Recording & Reward Claiming
    // ======================================

    /// @notice Records a trade and updates global and per-trader statistics.
    /// If a new epoch has started, the epoch trade volume is reset.
    /// Also records maker rebates or taker fees.
    /// @param tradeVolume The volume of the trade.
    /// @param isMaker Whether the trader is a market maker.
    function recordTrade(uint256 tradeVolume, bool isMaker) external whenNotPaused nonReentrant {
        require(initialized, "Not initialized");

        // Epoch checkpoint: Reset epoch volume if the epoch duration (in blocks) has passed.
        if (block.number >= lastEpochBlock + epochDuration) {
            epochTradeVolume = 0;
            lastEpochBlock = block.number;
        }

        totalTrades += 1;
        epochTradeVolume += tradeVolume;
        poolTradingVolume += tradeVolume;

        TraderStats storage stats = traderStats[msg.sender];
        stats.tradeCount += 1;
        stats.totalVolume += tradeVolume;

        // Dynamic multiplier: 150% if global epoch volume is below threshold.
        uint256 multiplier = epochTradeVolume < poolVolumeThreshold ? 150 : 100;
        uint256 reward = (tradeVolume * tradeRewardRate * multiplier) / 100;
        stats.pendingTradeRewards += reward;

        // Record maker rebate or taker fee (example: 1%).
        if (isMaker) {
            makerRebates[msg.sender] += tradeVolume / 100;
        } else {
            takerFees[msg.sender] += tradeVolume / 100;
        }

        // Initialize last claim time on first trade.
        if (stats.lastClaim == 0) {
            stats.lastClaim = block.timestamp;
        }

        emit TradeRecorded(msg.sender, tradeVolume, isMaker);
    }

    /// @notice Allows traders to claim accumulated trade rewards after the epoch duration.
    /// Uses a nonce and off‑chain EIP‑712 style signature for replay protection.
    /// @param expectedNonce The expected nonce for msg.sender.
    /// @param signature The signature over (msg.sender, expectedNonce).
    function claimTradeRewards(uint256 expectedNonce, bytes memory signature) external whenNotPaused nonReentrant {
        require(initialized, "Not initialized");
        require(nonces[msg.sender] == expectedNonce, "Invalid nonce");
        require(verifySignature(msg.sender, expectedNonce, signature), "Invalid signature");

        nonces[msg.sender]++;

        TraderStats storage stats = traderStats[msg.sender];
        require(block.timestamp >= stats.lastClaim + tradeEpochDuration, "Epoch duration not ended");
        uint256 reward = stats.pendingTradeRewards;
        require(reward > 0, "No pending rewards");
        require(reward <= maxClaimable, "Reward exceeds max claimable");

        // Reset pending rewards and update claim timestamp.
        stats.pendingTradeRewards = 0;
        stats.lastClaim = block.timestamp;

        latToken.mint(msg.sender, reward);
        emit TradeRewardsClaimed(msg.sender, reward);
    }

    // ======================================
    // Staking & Reward Claiming
    // ======================================

    /// @notice Stakes LAT tokens by transferring them to a treasury vault.
    /// The user must approve this contract beforehand.
    /// Also updates the staked weight (used for long‑term reward multipliers).
    /// @param amount The amount of LAT tokens to stake.
    function stakeLat(uint256 amount) external whenNotPaused nonReentrant {
        require(initialized, "Not initialized");
        // Transfer tokens from the user directly to the vault.
        require(latToken.transferFrom(msg.sender, vaultAddress, amount), "Transfer failed");

        Stake storage s = stakes[msg.sender];
        if (s.stakeStart == 0) {
            s.stakeStart = block.timestamp;
            stakedWeight[msg.sender] = 100; // Base weight.
        } else {
            // Increase weight for long-term stakers.
            stakedWeight[msg.sender] += 10;
        }
        s.amount += amount;
        s.lastUpdated = block.timestamp;

        emit StakeLat(msg.sender, amount);
    }

    /// @notice Claims staking rewards based on the staked amount and elapsed time.
    /// Applies pool boosts, liquidity boosts, staked weight, and inactivity slashing if applicable.
    /// Uses nonce-based replay protection.
    /// @param expectedNonce The expected nonce for msg.sender.
    function claimStakeRewards(uint256 expectedNonce) external whenNotPaused nonReentrant {
        require(initialized, "Not initialized");
        require(nonces[msg.sender] == expectedNonce, "Invalid nonce");
        nonces[msg.sender]++;

        Stake storage s = stakes[msg.sender];
        require(s.stakeStart != 0, "No stake found");

        uint256 elapsed = block.timestamp - s.lastUpdated;
        require(elapsed > 0, "No time elapsed");

        // Calculate effective stake reward rate.
        uint256 effectiveStakeRewardRate = stakeRewardRate;
        if (poolTradingVolume > poolVolumeThreshold) {
            effectiveStakeRewardRate = (stakeRewardRate * poolBoostMultiplier) / 100;
        }
        // Apply additional liquidity boost (default multiplier is 100).
        uint256 liquidityMultiplier = liquidityBoostMultiplier[msg.sender] == 0
            ? 100
            : liquidityBoostMultiplier[msg.sender];
        effectiveStakeRewardRate = (effectiveStakeRewardRate * liquidityMultiplier) / 100;

        // Base reward calculation.
        uint256 reward = s.amount * effectiveStakeRewardRate * elapsed;

        // Apply staked weight multiplier.
        reward = (reward * stakedWeight[msg.sender]) / 100;

        // Apply inactivity slashing if the staker has been inactive for too long.
        if (block.timestamp > s.lastUpdated + inactivitySlashingTime) {
            uint256 penalty = (reward * inactivityPenaltyRate) / 100;
            reward = reward - penalty;
        }

        s.lastUpdated = block.timestamp;
        latToken.mint(msg.sender, reward);
        emit StakeRewardsClaimed(msg.sender, reward);
    }

    /// @notice Withdraws staked LAT tokens from the treasury vault.
    /// If withdrawn before 7 days from staking, an early withdrawal fee is applied.
    /// @param amount The amount of staked tokens to withdraw.
    function withdrawStake(uint256 amount) external whenNotPaused nonReentrant {
        require(initialized, "Not initialized");
        Stake storage s = stakes[msg.sender];
        require(amount <= s.amount, "Insufficient staked amount");

        uint256 penalty = 0;
        // Apply penalty if withdrawing before 7 days have elapsed since staking.
        if (block.timestamp < s.stakeStart + 7 days) {
            penalty = (amount * earlyWithdrawalFee) / 100;
        }
        uint256 amountAfterPenalty = amount - penalty;
        s.amount -= amount;

        // Withdraw the tokens for the user from the vault.
        ITreasuryVault(vaultAddress).withdraw(msg.sender, amountAfterPenalty);
        // Withdraw the penalty amount to the owner.
        if (penalty > 0) {
            ITreasuryVault(vaultAddress).withdraw(owner(), penalty);
        }

        emit StakeWithdrawn(msg.sender, amountAfterPenalty, penalty);
    }

    // ======================================
    // Administration & Utility
    // ======================================

    /// @notice Admin-only function to update a trader's liquidity boost multiplier.
    /// @param trader The address of the trader.
    /// @param lpTokens The amount of liquidity provider tokens held (if > 0, multiplier is set to 120).
    function updateLiquidityMultiplier(address trader, uint256 lpTokens) external onlyOwner {
        liquidityBoostMultiplier[trader] = lpTokens > 0 ? 120 : 100;
        emit LiquidityMultiplierUpdated(trader, liquidityBoostMultiplier[trader]);
    }

    // ======================================
    // Off‑chain Signature Verification (EIP‑712 style)
    // ======================================

    /// @notice Verifies that the provided signature is valid for (signer, expectedNonce) using the Ethereum Signed Message format.
    /// @param signer The expected signer address.
    /// @param expectedNonce The expected nonce to prevent replay attacks.
    /// @param signature The ECDSA signature to verify.
    /// @return True if the signature is valid, false otherwise.
      function verifySignature(address signer, uint256 expectedNonce, bytes memory signature) internal pure returns (bool) {
             bytes32 messageHash = keccak256(abi.encodePacked(signer, expectedNonce));
             bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
             return ECDSA.recover(ethSignedMessageHash, signature) == signer;
        }
}
