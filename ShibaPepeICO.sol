// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// Chainlink Price Feed Interface
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @title ShibaPepe ICO Contract with Affiliate System
 * @dev ICO contract for purchasing SHPE tokens with ETH, USDC, or USDT
 * @notice For Base Network only
 *
 * 10-Stage Price Structure:
 * - Stage 1:  50B @ $0.000001  (100 in 8-digit precision)
 * - Stage 2:  50B @ $0.000002  (200 in 8-digit precision)
 * - Stage 3:  50B @ $0.000004  (400 in 8-digit precision)
 * - Stage 4:  40B @ $0.000008  (800 in 8-digit precision)
 * - Stage 5:  40B @ $0.00002   (2000 in 8-digit precision)
 * - Stage 6:  30B @ $0.00005   (5000 in 8-digit precision)
 * - Stage 7:  30B @ $0.0001    (10000 in 8-digit precision)
 * - Stage 8:  30B @ $0.00018   (18000 in 8-digit precision)
 * - Stage 9:  20B @ $0.00028   (28000 in 8-digit precision)
 * - Stage 10: 10B @ $0.00033   (33000 in 8-digit precision)
 *
 * Note: Prices can be adjusted based on sales performance via updateStagePrice()
 *
 * Features:
 * - Purchase with ETH: buyTokens(referrer)
 * - Purchase with USDC: buyTokensWithUSDC(amount, referrer) (requires approve)
 * - Purchase with USDT: buyTokensWithUSDT(amount, referrer) (requires approve)
 * - Automatic stage progression: Price updates automatically based on sales volume
 * - 5-tier affiliate system (Bronze 5% -> Silver 15% -> Gold 30% -> Diamond 40% -> Black 50%)
 * - Regular affiliates: Token rewards
 * - Ambassador affiliates: Rewards in same currency as purchase (ETH/USDC/USDT)
 * - Owner can set initial tier for any affiliate
 *
 * @custom:security-note This contract assumes USDC, USDT, and SHPE are standard ERC20 tokens
 *                       (not fee-on-transfer or rebasing). Base Network official tokens are used.
 * @custom:security-note Uses Ownable2Step for safer ownership transfer
 */
contract ShibaPepeICO is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ===== Tokens =====
    IERC20 public shpeToken;                    // SHPE Token
    IERC20 public usdcToken;                    // Base USDC
    IERC20 public usdtToken;                    // Base USDT

    // ===== Price Feed =====
    AggregatorV3Interface public ethPriceFeed;  // Chainlink ETH/USD
    AggregatorV3Interface public sequencerUptimeFeed;  // L2 Sequencer Uptime Feed

    // ===== L2 Sequencer Constants =====
    uint256 private constant GRACE_PERIOD_TIME = 3600; // 1 hour grace period after sequencer restart

    // ===== Stage Configuration =====
    struct Stage {
        uint256 supply;         // Supply for this stage
        uint256 priceUSD;       // USD price (8-digit precision: 100 = $0.000001)
        uint256 soldInStage;    // Amount sold in this stage
    }

    Stage[10] public stages;
    uint256 public currentStage;                // Current stage (0-9)
    uint256 public constant TOTAL_STAGES = 10;

    // ===== ICO Settings =====
    uint256 public minPurchaseETH;              // Minimum purchase amount ETH
    uint256 public minPurchaseUSDC;             // Minimum purchase amount USDC
    uint256 public minPurchaseUSDT;             // Minimum purchase amount USDT
    uint256 public totalTokensForSale;          // Total tokens for sale
    uint256 public tokensSold;                  // Tokens sold
    bool public icoActive;                      // ICO active flag

    // ===== Statistics =====
    uint256 public totalETHRaised;              // Total ETH raised
    uint256 public totalUSDCRaised;             // Total USDC raised
    uint256 public totalUSDTRaised;             // Total USDT raised

    // ===== User Purchase Info =====
    mapping(address => uint256) public purchasedAmount;  // Purchase amount per user

    // ===== Affiliate System =====
    mapping(address => uint256) public affiliateTotalUSD;    // Total referral amount (USD, 6-digit precision)
    mapping(address => uint256) public affiliateRewards;     // Total earned rewards (SHPE)
    mapping(address => uint256) public affiliateReferralCount; // Number of referrals
    mapping(address => bool) public isAmbassador;            // Ambassador flag
    address public marketingWallet;                          // Marketing wallet

    // ===== Ambassador Rewards (Same Currency as Purchase) =====
    mapping(address => uint256) public affiliateEthRewards;   // Total ETH rewards
    mapping(address => uint256) public affiliateUsdcRewards;  // Total USDC rewards
    mapping(address => uint256) public affiliateUsdtRewards;  // Total USDT rewards

    // ===== Initial Tier Override =====
    mapping(address => uint256) public affiliateInitialTier;  // 0=none, 500=Bronze, 1500=Silver, 3000=Gold, 4000=Diamond, 5000=Black

    // ===== Tier Thresholds (USD, 6-digit precision) =====
    uint256 public constant TIER_SILVER = 250 * 1e6;      // $250
    uint256 public constant TIER_GOLD = 2500 * 1e6;       // $2,500
    uint256 public constant TIER_DIAMOND = 10000 * 1e6;   // $10,000
    uint256 public constant TIER_BLACK = 50000 * 1e6;     // $50,000

    // ===== Events =====
    event TokensPurchasedWithETH(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 usdValue
    );
    event TokensPurchasedWithUSDC(
        address indexed buyer,
        uint256 usdcAmount,
        uint256 tokenAmount
    );
    event TokensPurchasedWithUSDT(
        address indexed buyer,
        uint256 usdtAmount,
        uint256 tokenAmount
    );
    event AffiliateReward(
        address indexed affiliate,
        address indexed buyer,
        uint256 rewardAmount,
        uint256 purchaseUSD
    );
    event AffiliateEthReward(
        address indexed affiliate,
        address indexed buyer,
        uint256 ethAmount,
        uint256 usdValue
    );
    event AffiliateUsdcReward(
        address indexed affiliate,
        address indexed buyer,
        uint256 usdcAmount,
        uint256 usdValue
    );
    event AffiliateUsdtReward(
        address indexed affiliate,
        address indexed buyer,
        uint256 usdtAmount,
        uint256 usdValue
    );
    event AffiliateTokenReward(
        address indexed affiliate,
        address indexed buyer,
        uint256 tokenAmount,
        uint256 usdValue
    );
    event AffiliateInitialTierSet(
        address indexed affiliate,
        uint256 tierRate
    );
    event ICOStarted(uint256 timestamp);
    event ICOStopped(uint256 timestamp);
    event StageAdvanced(uint256 oldStage, uint256 newStage, uint256 newPriceUSD);
    event FundsWithdrawn(address indexed to, uint256 ethAmount, uint256 usdcAmount, uint256 usdtAmount);
    event AmbassadorSet(address indexed ambassador, bool status);
    event MarketingWalletUpdated(address indexed newWallet);
    event StagePriceUpdated(uint256 indexed stageId, uint256 oldPrice, uint256 newPrice);
    event EmergencyPaused(uint256 timestamp);
    event EmergencyUnpaused(uint256 timestamp);
    event ETHPriceFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event SequencerUptimeFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event MinPurchaseUpdated(uint256 newMinETH, uint256 newMinUSDC, uint256 newMinUSDT);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event EmergencyTokenWithdrawn(address indexed token, address indexed to, uint256 amount);

    // ===== Constructor =====
    /**
     * @notice Initializes the ICO contract with token addresses and price feed
     * @param _shpeToken SHPE token contract address
     * @param _usdcToken USDC token contract address
     * @param _usdtToken USDT token contract address
     * @param _ethPriceFeed Chainlink ETH/USD price feed address
     * @param _sequencerUptimeFeed L2 Sequencer Uptime Feed address (Base: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433)
     * @param _marketingWallet Marketing wallet for affiliate token rewards
     */
    constructor(
        address _shpeToken,
        address _usdcToken,
        address _usdtToken,
        address _ethPriceFeed,
        address _sequencerUptimeFeed,
        address _marketingWallet
    ) Ownable(msg.sender) {
        require(_shpeToken != address(0), "Invalid SHPE token address");
        require(_usdcToken != address(0), "Invalid USDC token address");
        require(_usdtToken != address(0), "Invalid USDT token address");
        require(_ethPriceFeed != address(0), "Invalid ETH price feed address");
        require(_sequencerUptimeFeed != address(0), "Invalid sequencer feed address");
        require(_marketingWallet != address(0), "Invalid marketing wallet address");

        shpeToken = IERC20(_shpeToken);
        usdcToken = IERC20(_usdcToken);
        usdtToken = IERC20(_usdtToken);
        ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        marketingWallet = _marketingWallet;

        // Initialize 10-stage price structure
        // Total ICO fundraising target: ~$20.27M (~30億円 at 150 JPY/USD)
        // DEX listing price: $0.001
        // Stage 1:  50B @ $0.000001  (100 in 8-digit precision)
        stages[0] = Stage(50_000_000_000 * 1e18, 100, 0);
        // Stage 2:  50B @ $0.000002  (200 in 8-digit precision)
        stages[1] = Stage(50_000_000_000 * 1e18, 200, 0);
        // Stage 3:  50B @ $0.000004  (400 in 8-digit precision)
        stages[2] = Stage(50_000_000_000 * 1e18, 400, 0);
        // Stage 4:  40B @ $0.000008  (800 in 8-digit precision)
        stages[3] = Stage(40_000_000_000 * 1e18, 800, 0);
        // Stage 5:  40B @ $0.00002   (2000 in 8-digit precision)
        stages[4] = Stage(40_000_000_000 * 1e18, 2000, 0);
        // Stage 6:  30B @ $0.00005   (5000 in 8-digit precision)
        stages[5] = Stage(30_000_000_000 * 1e18, 5000, 0);
        // Stage 7:  30B @ $0.0001    (10000 in 8-digit precision)
        stages[6] = Stage(30_000_000_000 * 1e18, 10000, 0);
        // Stage 8:  30B @ $0.00018   (18000 in 8-digit precision)
        stages[7] = Stage(30_000_000_000 * 1e18, 18000, 0);
        // Stage 9:  20B @ $0.00028   (28000 in 8-digit precision)
        stages[8] = Stage(20_000_000_000 * 1e18, 28000, 0);
        // Stage 10: 10B @ $0.00033   (33000 in 8-digit precision)
        stages[9] = Stage(10_000_000_000 * 1e18, 33000, 0);

        currentStage = 0;

        // Minimum purchase amounts
        minPurchaseETH = 0.001 ether;           // 0.001 ETH
        minPurchaseUSDC = 5 * 1e6;              // 5 USDC (6 decimals)
        minPurchaseUSDT = 5 * 1e6;              // 5 USDT (6 decimals)

        // Total tokens for sale: 350B (sum of all stages)
        totalTokensForSale = 350_000_000_000 * 1e18;

        // ICO starts in inactive state
        icoActive = false;
    }

    // ===== Modifiers =====
    modifier whenICOActive() {
        require(icoActive, "ICO is not active");
        _;
    }

    modifier hasEnoughTokens(uint256 amount) {
        require(tokensSold + amount <= totalTokensForSale, "Not enough tokens available");
        require(shpeToken.balanceOf(address(this)) >= amount, "Insufficient token balance in contract");
        _;
    }

    // ===== Price Calculation Functions =====

    /**
     * @dev Get ETH price (Chainlink, 8-digit precision)
     * @notice Includes L2 sequencer uptime check and price data freshness check
     * @return ETH price in USD with 8 decimal precision
     */
    function getETHPrice() public view returns (uint256) {
        // Check L2 Sequencer status first
        _checkSequencerUptime();

        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethPriceFeed.latestRoundData();

        require(price > 0, "Invalid ETH price");
        require(updatedAt > 0, "Price not updated");
        require(answeredInRound >= roundId, "Stale price data");
        // Ensure price was updated within the last 20 minutes (Base heartbeat ~20min)
        require(block.timestamp - updatedAt < 1200, "Price data too old");

        return uint256(price);
    }

    /**
     * @dev Check L2 Sequencer uptime status
     * @notice Reverts if sequencer is down or grace period hasn't passed after restart
     */
    function _checkSequencerUptime() internal view {
        (
            /*uint80 roundId*/,
            int256 answer,
            uint256 startedAt,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = sequencerUptimeFeed.latestRoundData();

        // answer == 0: Sequencer is up
        // answer == 1: Sequencer is down
        bool isSequencerUp = answer == 0;
        require(isSequencerUp, "Sequencer is down");

        // Ensure grace period has passed since sequencer came back up
        uint256 timeSinceUp = block.timestamp - startedAt;
        require(timeSinceUp > GRACE_PERIOD_TIME, "Grace period not over");
    }

    /**
     * @dev Get current SHPE price (USD, 8-digit precision)
     * @return Current token price in USD with 8 decimal precision
     */
    function getTokenPriceUSD() public view returns (uint256) {
        return stages[currentStage].priceUSD;
    }

    /**
     * @dev Calculate token amount from ETH
     * @param ethAmount ETH amount (wei)
     * @return tokenAmount Purchasable SHPE amount
     */
    function calculateTokensFromETH(uint256 ethAmount) public view returns (uint256) {
        uint256 ethPriceUSD = getETHPrice(); // 8-digit precision
        // ETH -> USD conversion (8-digit precision)
        uint256 usdValue = (ethAmount * ethPriceUSD) / 1e18;
        // USD -> SHPE conversion (using current stage price)
        uint256 tokenPriceUSD = getTokenPriceUSD();
        return (usdValue * 1e18) / tokenPriceUSD;
    }

    /**
     * @dev Calculate token amount from USDC
     * @param usdcAmount USDC amount (6 decimals)
     * @return tokenAmount Purchasable SHPE amount
     */
    function calculateTokensFromUSDC(uint256 usdcAmount) public view returns (uint256) {
        // USDC (6-digit) -> USD (8-digit) conversion
        uint256 usdValue = usdcAmount * 100;  // 6-digit -> 8-digit
        // USD -> SHPE conversion (using current stage price)
        uint256 tokenPriceUSD = getTokenPriceUSD();
        return (usdValue * 1e18) / tokenPriceUSD;
    }

    /**
     * @dev Calculate token amount from USDT
     * @param usdtAmount USDT amount (6 decimals)
     * @return tokenAmount Purchasable SHPE amount
     */
    function calculateTokensFromUSDT(uint256 usdtAmount) public view returns (uint256) {
        // USDT (6-digit) -> USD (8-digit) conversion
        uint256 usdValue = usdtAmount * 100;  // 6-digit -> 8-digit
        // USD -> SHPE conversion (using current stage price)
        uint256 tokenPriceUSD = getTokenPriceUSD();
        return (usdValue * 1e18) / tokenPriceUSD;
    }

    /**
     * @dev Get current price per SHPE in ETH (dynamic calculation)
     * @return Current token price in ETH (wei)
     */
    function getCurrentPriceInETH() external view returns (uint256) {
        uint256 ethPriceUSD = getETHPrice(); // 8-digit precision
        uint256 tokenPriceUSD = getTokenPriceUSD();
        // 1 SHPE = tokenPriceUSD / ethPriceUSD ETH
        // Return in wei: (tokenPriceUSD * 1e18) / ethPriceUSD
        return (tokenPriceUSD * 1e18) / ethPriceUSD;
    }

    /**
     * @dev Get current price per SHPE in USDC
     * @return Current token price in USDC (6 decimals)
     */
    function getCurrentPriceInUSDC() external view returns (uint256) {
        uint256 tokenPriceUSD = getTokenPriceUSD();
        // tokenPriceUSD (8-digit) -> USDC (6-digit)
        return tokenPriceUSD / 100;
    }

    /**
     * @dev Convert ETH amount to USD (6-digit precision)
     * @param ethAmount ETH amount in wei
     * @return USD value with 6 decimal precision
     */
    function getEthUsdValue(uint256 ethAmount) public view returns (uint256) {
        uint256 ethPriceUSD = getETHPrice(); // 8-digit precision
        // purchaseUSD = (ETH amount * ETH price) / 1e20 -> convert to 6-digit precision
        return (ethAmount * ethPriceUSD) / 1e20;
    }

    // ===== Affiliate Functions =====

    /**
     * @dev Get affiliate reward rate (basis points: 10000 = 100%)
     * @param affiliate Affiliate address
     * @return Reward rate in basis points
     * @notice Considers both cumulative sales and initial tier override
     */
    function getAffiliateRate(address affiliate) public view returns (uint256) {
        uint256 totalUSD = affiliateTotalUSD[affiliate];

        // Calculate tier rate based on cumulative sales
        uint256 salesBasedRate;
        if (totalUSD >= TIER_BLACK) salesBasedRate = 5000;        // 50% - Black
        else if (totalUSD >= TIER_DIAMOND) salesBasedRate = 4000; // 40% - Diamond
        else if (totalUSD >= TIER_GOLD) salesBasedRate = 3000;    // 30% - Gold
        else if (totalUSD >= TIER_SILVER) salesBasedRate = 1500;  // 15% - Silver
        else salesBasedRate = 500;                                 // 5% - Bronze

        // Return the higher of sales-based rate or initial tier override
        uint256 initialRate = affiliateInitialTier[affiliate];
        return salesBasedRate > initialRate ? salesBasedRate : initialRate;
    }

    /**
     * @dev Process affiliate reward (for ETH purchases)
     * @param referrer Referrer address
     * @param buyer Buyer address
     * @param ethAmount ETH amount spent
     * @param tokenAmount Tokens purchased
     * @param purchaseUSD Purchase value in USD
     */
    function _processAffiliateRewardETH(
        address referrer,
        address buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 purchaseUSD
    ) internal {
        if (referrer == address(0) || referrer == buyer) return;

        // Update cumulative referral amount
        affiliateTotalUSD[referrer] += purchaseUSD;
        affiliateReferralCount[referrer]++;

        // Ambassadors receive ETH rewards (same currency as purchase)
        if (isAmbassador[referrer]) {
            uint256 rewardRate = getAffiliateRate(referrer);
            uint256 ethReward = (ethAmount * rewardRate) / 10000;

            // Check contract balance
            if (address(this).balance >= ethReward && ethReward != 0) {
                (bool success, ) = payable(referrer).call{value: ethReward}("");
                require(success, "ETH transfer failed");

                affiliateEthRewards[referrer] += ethReward;
                emit AffiliateEthReward(referrer, buyer, ethReward, purchaseUSD);
            }
        } else {
            // Regular affiliates: Token rewards
            _processTokenReward(referrer, buyer, tokenAmount, purchaseUSD);
        }
    }

    /**
     * @dev Process affiliate reward (for USDC purchases)
     * @param referrer Referrer address
     * @param buyer Buyer address
     * @param usdcAmount USDC amount spent
     * @param tokenAmount Tokens purchased
     * @param purchaseUSD Purchase value in USD
     */
    function _processAffiliateRewardUSDC(
        address referrer,
        address buyer,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 purchaseUSD
    ) internal {
        if (referrer == address(0) || referrer == buyer) return;

        // Update cumulative referral amount
        affiliateTotalUSD[referrer] += purchaseUSD;
        affiliateReferralCount[referrer]++;

        // Ambassadors receive USDC rewards (same currency as purchase)
        if (isAmbassador[referrer]) {
            uint256 rewardRate = getAffiliateRate(referrer);
            uint256 usdcReward = (usdcAmount * rewardRate) / 10000;

            // Check contract USDC balance
            uint256 contractUsdcBalance = usdcToken.balanceOf(address(this));
            if (contractUsdcBalance >= usdcReward && usdcReward != 0) {
                usdcToken.safeTransfer(referrer, usdcReward);

                affiliateUsdcRewards[referrer] += usdcReward;
                emit AffiliateUsdcReward(referrer, buyer, usdcReward, purchaseUSD);
            }
        } else {
            // Regular affiliates: Token rewards
            _processTokenReward(referrer, buyer, tokenAmount, purchaseUSD);
        }
    }

    /**
     * @dev Process affiliate reward (for USDT purchases)
     * @param referrer Referrer address
     * @param buyer Buyer address
     * @param usdtAmount USDT amount spent
     * @param tokenAmount Tokens purchased
     * @param purchaseUSD Purchase value in USD
     */
    function _processAffiliateRewardUSDT(
        address referrer,
        address buyer,
        uint256 usdtAmount,
        uint256 tokenAmount,
        uint256 purchaseUSD
    ) internal {
        if (referrer == address(0) || referrer == buyer) return;

        // Update cumulative referral amount
        affiliateTotalUSD[referrer] += purchaseUSD;
        affiliateReferralCount[referrer]++;

        // Ambassadors receive USDT rewards (same currency as purchase)
        if (isAmbassador[referrer]) {
            uint256 rewardRate = getAffiliateRate(referrer);
            uint256 usdtReward = (usdtAmount * rewardRate) / 10000;

            // Check contract USDT balance
            uint256 contractUsdtBalance = usdtToken.balanceOf(address(this));
            if (contractUsdtBalance >= usdtReward && usdtReward != 0) {
                usdtToken.safeTransfer(referrer, usdtReward);

                affiliateUsdtRewards[referrer] += usdtReward;
                emit AffiliateUsdtReward(referrer, buyer, usdtReward, purchaseUSD);
            }
        } else {
            // Regular affiliates: Token rewards
            _processTokenReward(referrer, buyer, tokenAmount, purchaseUSD);
        }
    }

    /**
     * @dev Process token reward
     * @param referrer Referrer address
     * @param buyer Buyer address
     * @param tokenAmount Tokens purchased
     * @param purchaseUSD Purchase value in USD
     * @notice Rewards are skipped (not reverted) if marketing wallet lacks allowance or balance
     * @custom:security-note Silently skips reward if marketing wallet has insufficient balance/allowance
     *         to avoid blocking purchases
     */
    function _processTokenReward(
        address referrer,
        address buyer,
        uint256 tokenAmount,
        uint256 purchaseUSD
    ) internal {
        address _marketingWallet = marketingWallet;
        if (_marketingWallet == address(0)) return;

        // Calculate reward
        uint256 rewardRate = getAffiliateRate(referrer);
        uint256 rewardAmount = (tokenAmount * rewardRate) / 10000;

        if (rewardAmount == 0) return;

        // Check if marketing wallet has sufficient allowance AND balance
        uint256 allowance = shpeToken.allowance(_marketingWallet, address(this));
        uint256 marketingBalance = shpeToken.balanceOf(_marketingWallet);

        if (allowance >= rewardAmount && marketingBalance >= rewardAmount) {
            // Send reward from marketing wallet
            shpeToken.safeTransferFrom(_marketingWallet, referrer, rewardAmount);
            affiliateRewards[referrer] += rewardAmount;

            emit AffiliateTokenReward(referrer, buyer, rewardAmount, purchaseUSD);
        }
        // If insufficient allowance or balance, skip reward silently to avoid blocking purchases
    }

    // ===== Purchase with ETH =====

    /**
     * @dev Purchase SHPE tokens by sending ETH with slippage protection
     * @param referrer Referrer address (address(0) if none)
     * @param minTokensOut Minimum tokens expected (0 to skip check)
     * @param deadline Transaction deadline timestamp (0 to skip check)
     * @notice PUBLIC FUNCTION - Users call this directly to purchase tokens.
     *         No access control is required as this is the primary purchase interface.
     *         Properly handles purchases that span multiple price stages.
     *         Includes slippage and deadline protection against MEV/sandwich attacks.
     * @custom:security-note Access control intentionally omitted - user-facing function
     * @custom:security-note Slippage protection prevents MEV attacks
     */
    function buyTokens(
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused whenICOActive {
        _buyTokensInternal(referrer, minTokensOut, deadline);
    }

    /**
     * @dev Internal function for ETH purchases
     * @param referrer Referrer address
     * @param minTokensOut Minimum tokens expected (0 to skip)
     * @param deadline Transaction deadline timestamp (0 to skip)
     */
    function _buyTokensInternal(
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) internal {
        require(msg.value >= minPurchaseETH, "Below minimum purchase amount");
        if (deadline != 0) {
            require(block.timestamp <= deadline, "Transaction expired");
        }

        uint256 ethPriceUSD = getETHPrice(); // 8-digit precision
        // ETH -> USD conversion (8-digit precision)
        uint256 usdValue8 = (msg.value * ethPriceUSD) / 1e18;

        // Process purchase across stages
        uint256 tokenAmount = _processPurchaseAcrossStages(msg.sender, usdValue8);

        // Slippage check
        if (minTokensOut != 0) {
            require(tokenAmount >= minTokensOut, "Slippage: tokens below minimum");
        }

        totalETHRaised += msg.value;
        purchasedAmount[msg.sender] += tokenAmount;

        // Process affiliate reward
        uint256 purchaseUSD = getEthUsdValue(msg.value);
        _processAffiliateRewardETH(referrer, msg.sender, msg.value, tokenAmount, purchaseUSD);

        emit TokensPurchasedWithETH(msg.sender, msg.value, tokenAmount, purchaseUSD);
    }

    // ===== Purchase with USDC =====

    /**
     * @dev Purchase SHPE tokens with USDC with slippage protection
     * @param usdcAmount USDC amount (6 decimals)
     * @param referrer Referrer address (address(0) if none)
     * @param minTokensOut Minimum tokens expected (0 to skip check)
     * @param deadline Transaction deadline timestamp (0 to skip check)
     * @notice PUBLIC FUNCTION - Users call this directly to purchase tokens with USDC.
     *         No access control is required as this is a user-facing purchase interface.
     *         Requires prior approve(). Properly handles purchases that span multiple price stages.
     *         Includes slippage and deadline protection against MEV/sandwich attacks.
     * @custom:security-note Access control intentionally omitted - user-facing function
     * @custom:security-note Slippage protection prevents MEV attacks
     */
    function buyTokensWithUSDC(
        uint256 usdcAmount,
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused whenICOActive {
        _buyTokensWithUSDCInternal(usdcAmount, referrer, minTokensOut, deadline);
    }

    /**
     * @dev Internal function for USDC purchases
     * @param usdcAmount USDC amount to spend
     * @param referrer Referrer address
     * @param minTokensOut Minimum tokens expected (0 to skip)
     * @param deadline Transaction deadline timestamp (0 to skip)
     */
    function _buyTokensWithUSDCInternal(
        uint256 usdcAmount,
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) internal {
        require(usdcAmount != 0, "Amount must be greater than zero");
        require(usdcAmount >= minPurchaseUSDC, "Below minimum purchase amount");
        if (deadline != 0) {
            require(block.timestamp <= deadline, "Transaction expired");
        }

        // USDC (6-digit) -> USD (8-digit) conversion
        uint256 usdValue8 = usdcAmount * 100;

        // Transfer USDC to contract
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Process purchase across stages
        uint256 tokenAmount = _processPurchaseAcrossStages(msg.sender, usdValue8);

        // Slippage check
        if (minTokensOut != 0) {
            require(tokenAmount >= minTokensOut, "Slippage: tokens below minimum");
        }

        totalUSDCRaised += usdcAmount;
        purchasedAmount[msg.sender] += tokenAmount;

        // Process affiliate reward (USDC is already USD-denominated, 6-digit precision)
        _processAffiliateRewardUSDC(referrer, msg.sender, usdcAmount, tokenAmount, usdcAmount);

        emit TokensPurchasedWithUSDC(msg.sender, usdcAmount, tokenAmount);
    }

    // ===== Purchase with USDT =====

    /**
     * @dev Purchase SHPE tokens with USDT with slippage protection
     * @param usdtAmount USDT amount (6 decimals)
     * @param referrer Referrer address (address(0) if none)
     * @param minTokensOut Minimum tokens expected (0 to skip check)
     * @param deadline Transaction deadline timestamp (0 to skip check)
     * @notice PUBLIC FUNCTION - Users call this directly to purchase tokens with USDT.
     *         No access control is required as this is a user-facing purchase interface.
     *         Requires prior approve(). Properly handles purchases that span multiple price stages.
     *         Includes slippage and deadline protection against MEV/sandwich attacks.
     * @custom:security-note Access control intentionally omitted - user-facing function
     * @custom:security-note Slippage protection prevents MEV attacks
     */
    function buyTokensWithUSDT(
        uint256 usdtAmount,
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused whenICOActive {
        _buyTokensWithUSDTInternal(usdtAmount, referrer, minTokensOut, deadline);
    }

    /**
     * @dev Internal function for USDT purchases
     * @param usdtAmount USDT amount to spend
     * @param referrer Referrer address
     * @param minTokensOut Minimum tokens expected (0 to skip)
     * @param deadline Transaction deadline timestamp (0 to skip)
     */
    function _buyTokensWithUSDTInternal(
        uint256 usdtAmount,
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    ) internal {
        require(usdtAmount != 0, "Amount must be greater than zero");
        require(usdtAmount >= minPurchaseUSDT, "Below minimum purchase amount");
        if (deadline != 0) {
            require(block.timestamp <= deadline, "Transaction expired");
        }

        // USDT (6-digit) -> USD (8-digit) conversion
        uint256 usdValue8 = usdtAmount * 100;

        // Transfer USDT to contract
        usdtToken.safeTransferFrom(msg.sender, address(this), usdtAmount);

        // Process purchase across stages
        uint256 tokenAmount = _processPurchaseAcrossStages(msg.sender, usdValue8);

        // Slippage check
        if (minTokensOut != 0) {
            require(tokenAmount >= minTokensOut, "Slippage: tokens below minimum");
        }

        totalUSDTRaised += usdtAmount;
        purchasedAmount[msg.sender] += tokenAmount;

        // Process affiliate reward (USDT is already USD-denominated, 6-digit precision)
        _processAffiliateRewardUSDT(referrer, msg.sender, usdtAmount, tokenAmount, usdtAmount);

        emit TokensPurchasedWithUSDT(msg.sender, usdtAmount, tokenAmount);
    }

    // ===== Internal Functions =====

    /**
     * @dev Calculate tokens from USD value across multiple stages (view only)
     * @param usdValue8 USD value with 8 decimal precision
     * @return totalTokens Total tokens purchasable across stages
     */
    function _calculateTokensAcrossStages(uint256 usdValue8) internal view returns (uint256 totalTokens) {
        uint256 remainingUSD = usdValue8;
        uint256 tempStage = currentStage;
        totalTokens = 0;

        while (remainingUSD > 0 && tempStage < TOTAL_STAGES) {
            Stage memory stage = stages[tempStage];
            uint256 remainingInStage = stage.supply > stage.soldInStage ?
                stage.supply - stage.soldInStage : 0;

            if (remainingInStage == 0) {
                tempStage++;
                continue;
            }

            // Calculate max tokens purchasable at this stage price
            uint256 tokensAtThisPrice = (remainingUSD * 1e18) / stage.priceUSD;

            if (tokensAtThisPrice <= remainingInStage) {
                // Can purchase all with remaining USD at this stage
                totalTokens += tokensAtThisPrice;
                break;
            } else {
                // Can only purchase remaining tokens in this stage
                totalTokens += remainingInStage;
                // Calculate USD spent on this stage
                uint256 usdSpent = (remainingInStage * stage.priceUSD) / 1e18;
                remainingUSD = remainingUSD > usdSpent ? remainingUSD - usdSpent : 0;
                tempStage++;
            }
        }

        return totalTokens;
    }

    /**
     * @dev Process purchase and properly distribute tokens across stages
     * @param buyer Buyer address to receive tokens
     * @param usdValue8 USD value of purchase with 8 decimal precision
     * @return tokenAmount Total tokens purchased and transferred
     */
    function _processPurchaseAcrossStages(address buyer, uint256 usdValue8) internal returns (uint256 tokenAmount) {
        uint256 remainingUSD = usdValue8;
        tokenAmount = 0;

        while (remainingUSD > 0 && currentStage < TOTAL_STAGES) {
            Stage storage stage = stages[currentStage];
            uint256 remainingInStage = stage.supply > stage.soldInStage ?
                stage.supply - stage.soldInStage : 0;

            if (remainingInStage == 0) {
                uint256 oldStage = currentStage;
                currentStage++;
                if (currentStage < TOTAL_STAGES) {
                    emit StageAdvanced(oldStage, currentStage, stages[currentStage].priceUSD);
                }
                continue;
            }

            // Calculate max tokens purchasable at this stage price
            uint256 tokensAtThisPrice = (remainingUSD * 1e18) / stage.priceUSD;

            uint256 tokensToBuy;
            if (tokensAtThisPrice <= remainingInStage) {
                // Can purchase all with remaining USD at this stage
                tokensToBuy = tokensAtThisPrice;
                remainingUSD = 0;
            } else {
                // Can only purchase remaining tokens in this stage
                tokensToBuy = remainingInStage;
                // Calculate USD spent on this stage
                uint256 usdSpent = (remainingInStage * stage.priceUSD) / 1e18;
                remainingUSD = remainingUSD > usdSpent ? remainingUSD - usdSpent : 0;
            }

            // Update stage sold amount
            stage.soldInStage += tokensToBuy;
            tokenAmount += tokensToBuy;

            // Check if stage is complete and advance
            if (stage.soldInStage >= stage.supply && currentStage < TOTAL_STAGES - 1) {
                uint256 oldStage = currentStage;
                currentStage++;
                emit StageAdvanced(oldStage, currentStage, stages[currentStage].priceUSD);
            }
        }

        // Verify and transfer tokens
        require(tokenAmount != 0, "No tokens to purchase");
        require(tokensSold + tokenAmount <= totalTokensForSale, "Not enough tokens available");
        require(shpeToken.balanceOf(address(this)) >= tokenAmount, "Insufficient token balance in contract");

        tokensSold += tokenAmount;
        shpeToken.safeTransfer(buyer, tokenAmount);

        // Auto-stop when sold out
        if (tokensSold >= totalTokensForSale) {
            icoActive = false;
            emit ICOStopped(block.timestamp);
        }

        return tokenAmount;
    }

    // ===== Dashboard View Functions =====

    /**
     * @dev Get affiliate information
     * @param affiliate Affiliate address
     * @return totalUSD Total USD value of referrals
     * @return totalRewards Total token rewards earned
     * @return currentRate Current reward rate in basis points
     * @return referralCount Number of referrals
     * @return tierName Current tier name
     */
    function getAffiliateInfo(address affiliate) external view returns (
        uint256 totalUSD,
        uint256 totalRewards,
        uint256 currentRate,
        uint256 referralCount,
        string memory tierName
    ) {
        totalUSD = affiliateTotalUSD[affiliate];
        totalRewards = affiliateRewards[affiliate];
        currentRate = getAffiliateRate(affiliate);
        referralCount = affiliateReferralCount[affiliate];

        if (currentRate >= 5000) tierName = "Black";
        else if (currentRate >= 4000) tierName = "Diamond";
        else if (currentRate >= 3000) tierName = "Gold";
        else if (currentRate >= 1500) tierName = "Silver";
        else tierName = "Bronze";
    }

    /**
     * @dev Get next tier information
     * @param affiliate Affiliate address
     * @return nextTierThreshold USD threshold for next tier
     * @return remaining USD remaining to reach next tier
     * @return nextTierName Name of next tier
     * @notice Considers both cumulative sales and initial tier override
     */
    function getNextTierInfo(address affiliate) external view returns (
        uint256 nextTierThreshold,
        uint256 remaining,
        string memory nextTierName
    ) {
        uint256 currentRate = getAffiliateRate(affiliate);
        uint256 totalUSD = affiliateTotalUSD[affiliate];

        // Based on current effective rate, determine next tier
        if (currentRate >= 5000) {
            return (0, 0, "MAX");
        } else if (currentRate >= 4000) {
            // Currently Diamond, next is Black
            uint256 neededUSD = TIER_BLACK > totalUSD ? TIER_BLACK - totalUSD : 0;
            return (TIER_BLACK, neededUSD, "Black");
        } else if (currentRate >= 3000) {
            // Currently Gold, next is Diamond
            uint256 neededUSD = TIER_DIAMOND > totalUSD ? TIER_DIAMOND - totalUSD : 0;
            return (TIER_DIAMOND, neededUSD, "Diamond");
        } else if (currentRate >= 1500) {
            // Currently Silver, next is Gold
            uint256 neededUSD = TIER_GOLD > totalUSD ? TIER_GOLD - totalUSD : 0;
            return (TIER_GOLD, neededUSD, "Gold");
        } else {
            // Currently Bronze, next is Silver
            uint256 neededUSD = TIER_SILVER > totalUSD ? TIER_SILVER - totalUSD : 0;
            return (TIER_SILVER, neededUSD, "Silver");
        }
    }

    /**
     * @dev Get ambassador information
     * @param affiliate Affiliate address
     * @return isAmbassadorStatus Whether the address is an ambassador
     * @return currentRate Current reward rate in basis points
     * @return initialTierRate Initial tier rate override
     * @return totalUsdSales Total USD sales referred
     * @return totalEthRewards Total ETH rewards earned
     * @return totalUsdcRewards Total USDC rewards earned
     * @return totalUsdtRewards Total USDT rewards earned
     */
    function getAmbassadorInfo(address affiliate) external view returns (
        bool isAmbassadorStatus,
        uint256 currentRate,
        uint256 initialTierRate,
        uint256 totalUsdSales,
        uint256 totalEthRewards,
        uint256 totalUsdcRewards,
        uint256 totalUsdtRewards
    ) {
        return (
            isAmbassador[affiliate],
            getAffiliateRate(affiliate),
            affiliateInitialTier[affiliate],
            affiliateTotalUSD[affiliate],
            affiliateEthRewards[affiliate],
            affiliateUsdcRewards[affiliate],
            affiliateUsdtRewards[affiliate]
        );
    }

    /**
     * @dev Get ICO status
     * @return active Whether ICO is active
     * @return sold Tokens sold
     * @return remaining Tokens remaining
     * @return priceUSD Current price in USD
     * @return ethPrice Current ETH price in USD
     */
    function getICOStatus() external view returns (
        bool active,
        uint256 sold,
        uint256 remaining,
        uint256 priceUSD,
        uint256 ethPrice
    ) {
        return (
            icoActive,
            tokensSold,
            totalTokensForSale - tokensSold,
            getTokenPriceUSD(),
            getETHPrice()
        );
    }

    /**
     * @dev Get current stage information
     * @return stageNumber Current stage number (1-indexed)
     * @return supply Total supply for this stage
     * @return priceUSD Price in USD for this stage
     * @return soldInStage Tokens sold in this stage
     * @return remainingInStage Tokens remaining in this stage
     */
    function getCurrentStageInfo() external view returns (
        uint256 stageNumber,
        uint256 supply,
        uint256 priceUSD,
        uint256 soldInStage,
        uint256 remainingInStage
    ) {
        Stage memory current = stages[currentStage];
        return (
            currentStage + 1, // 1-indexed for display
            current.supply,
            current.priceUSD,
            current.soldInStage,
            current.supply > current.soldInStage ? current.supply - current.soldInStage : 0
        );
    }

    /**
     * @dev Get all stages information
     * @return supplies Array of supplies for all stages
     * @return prices Array of prices for all stages
     * @return soldAmounts Array of sold amounts for all stages
     */
    function getAllStagesInfo() external view returns (
        uint256[10] memory supplies,
        uint256[10] memory prices,
        uint256[10] memory soldAmounts
    ) {
        for (uint256 i = 0; i < TOTAL_STAGES; i++) {
            supplies[i] = stages[i].supply;
            prices[i] = stages[i].priceUSD;
            soldAmounts[i] = stages[i].soldInStage;
        }
    }

    /**
     * @dev Get user purchase information
     * @param user User address
     * @return purchased Total tokens purchased by user
     * @return balance Current token balance of user
     */
    function getUserPurchaseInfo(address user) external view returns (
        uint256 purchased,
        uint256 balance
    ) {
        purchased = purchasedAmount[user];
        balance = shpeToken.balanceOf(user);
    }

    /**
     * @dev Get contract ETH balance
     * @return Contract ETH balance in wei
     */
    function getContractETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Get remaining tokens
     * @return Number of tokens remaining for sale
     */
    function getRemainingTokens() external view returns (uint256) {
        return totalTokensForSale - tokensSold;
    }

    // ===== Owner-Only Functions =====

    /**
     * @dev Set ambassador status and initial tier
     * @param _ambassador Target address
     * @param _status Ambassador status (true = ambassador, receives rewards in purchase currency)
     * @param _initialTierRate Initial tier rate in basis points (500=Bronze, 1500=Silver, 3000=Gold, 4000=Diamond, 5000=Black)
     */
    function setAmbassador(address _ambassador, bool _status, uint256 _initialTierRate) external onlyOwner {
        require(_ambassador != address(0), "Invalid address");
        require(_initialTierRate <= 5000, "Rate cannot exceed 50%"); // Max Black tier

        isAmbassador[_ambassador] = _status;
        if (_initialTierRate != 0) {
            affiliateInitialTier[_ambassador] = _initialTierRate;
        }

        emit AmbassadorSet(_ambassador, _status);
        if (_initialTierRate != 0) {
            emit AffiliateInitialTierSet(_ambassador, _initialTierRate);
        }
    }

    /**
     * @dev Set initial tier for any affiliate (including regular affiliates)
     * @param affiliate Target address
     * @param tierRate Tier rate in basis points (500=Bronze, 1500=Silver, 3000=Gold, 4000=Diamond, 5000=Black)
     */
    function setAffiliateInitialTier(address affiliate, uint256 tierRate) external onlyOwner {
        require(affiliate != address(0), "Invalid address");
        require(tierRate <= 5000, "Rate cannot exceed 50%"); // Max Black tier

        affiliateInitialTier[affiliate] = tierRate;
        emit AffiliateInitialTierSet(affiliate, tierRate);
    }

    /**
     * @dev Start ICO
     * @notice Requires tokens to be deposited in contract first
     */
    function startICO() external onlyOwner {
        require(!icoActive, "ICO is already active");
        require(shpeToken.balanceOf(address(this)) > 0, "No tokens in contract");
        icoActive = true;
        emit ICOStarted(block.timestamp);
    }

    /**
     * @dev Stop ICO
     * @notice Can be restarted with startICO()
     */
    function stopICO() external onlyOwner {
        require(icoActive, "ICO is not active");
        icoActive = false;
        emit ICOStopped(block.timestamp);
    }

    /**
     * @dev Emergency pause (pause all functions)
     * @notice Unlike stopICO, this immediately pauses all purchase functions using OpenZeppelin Pausable
     */
    function emergencyPause() external onlyOwner {
        _pause();
        emit EmergencyPaused(block.timestamp);
    }

    /**
     * @dev Unpause emergency pause
     * @notice Resumes normal contract operations
     */
    function emergencyUnpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpaused(block.timestamp);
    }

    /**
     * @dev Set marketing wallet
     * @param _wallet New marketing wallet address
     */
    function setMarketingWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "Invalid address");
        marketingWallet = _wallet;
        emit MarketingWalletUpdated(_wallet);
    }

    /**
     * @dev Update price feed
     * @param _priceFeed New Chainlink ETH/USD price feed address
     * @notice Price feed must return 8-digit precision
     * @custom:security-note Centralized risk acknowledged - owner can change price feed
     */
    function setETHPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid price feed address");
        address oldFeed = address(ethPriceFeed);
        ethPriceFeed = AggregatorV3Interface(_priceFeed);
        emit ETHPriceFeedUpdated(oldFeed, _priceFeed);
    }

    /**
     * @dev Update L2 Sequencer Uptime Feed
     * @param _sequencerFeed New L2 Sequencer Uptime Feed address
     * @custom:security-note Centralized risk acknowledged - owner can change sequencer feed
     */
    function setSequencerUptimeFeed(address _sequencerFeed) external onlyOwner {
        require(_sequencerFeed != address(0), "Invalid sequencer feed address");
        address oldFeed = address(sequencerUptimeFeed);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerFeed);
        emit SequencerUptimeFeedUpdated(oldFeed, _sequencerFeed);
    }

    /**
     * @dev Update stage price (for emergencies)
     * @param stageId Stage ID (0-9)
     * @param newPriceUSD New price (8-digit precision)
     * @notice Price changes take effect immediately. Users should verify current prices before purchasing.
     * @custom:security-note Owner price control is intentional for ICO operational flexibility.
     *                       StagePriceUpdated event is emitted for transparency.
     */
    function updateStagePrice(uint256 stageId, uint256 newPriceUSD) external onlyOwner {
        require(stageId < TOTAL_STAGES, "Invalid stage");
        require(newPriceUSD != 0, "Price must be greater than 0");
        uint256 oldPrice = stages[stageId].priceUSD;
        stages[stageId].priceUSD = newPriceUSD;
        emit StagePriceUpdated(stageId, oldPrice, newPriceUSD);
    }

    /**
     * @dev Update minimum purchase amounts
     */
    function setMinPurchase(uint256 newMinETH, uint256 newMinUSDC, uint256 newMinUSDT) external onlyOwner {
        minPurchaseETH = newMinETH;
        minPurchaseUSDC = newMinUSDC;
        minPurchaseUSDT = newMinUSDT;
        emit MinPurchaseUpdated(newMinETH, newMinUSDC, newMinUSDT);
    }

    /**
     * @dev Withdraw funds
     * @param to Recipient address
     * @notice Withdraws remaining balance after VIP affiliate ETH rewards
     * @custom:security-note Uses call() instead of transfer() for better compatibility
     */
    function withdrawFunds(address to) external nonReentrant onlyOwner {
        require(to != address(0), "Invalid address");

        uint256 ethBalance = address(this).balance;
        uint256 usdcBalance = usdcToken.balanceOf(address(this));
        uint256 usdtBalance = usdtToken.balanceOf(address(this));

        if (ethBalance != 0) {
            (bool success, ) = payable(to).call{value: ethBalance}("");
            require(success, "ETH transfer failed");
        }

        if (usdcBalance != 0) {
            usdcToken.safeTransfer(to, usdcBalance);
        }

        if (usdtBalance != 0) {
            usdtToken.safeTransfer(to, usdtBalance);
        }

        emit FundsWithdrawn(to, ethBalance, usdcBalance, usdtBalance);
    }

    /**
     * @dev Withdraw remaining tokens (after ICO ends)
     * @param to Recipient address
     */
    function withdrawRemainingTokens(address to) external onlyOwner {
        require(!icoActive, "ICO must be stopped first");
        require(to != address(0), "Invalid address");

        uint256 remainingTokens = shpeToken.balanceOf(address(this));
        if (remainingTokens != 0) {
            shpeToken.safeTransfer(to, remainingTokens);
            emit TokensWithdrawn(to, remainingTokens);
        }
    }

    /**
     * @dev Emergency: Rescue any ERC20 token (except SHPE during active ICO)
     * @param token Token address to withdraw
     * @param to Recipient address
     * @notice Use withdrawRemainingTokens() to withdraw SHPE after ICO ends
     * @custom:security-note SHPE token protected during active ICO to prevent accidental withdrawal
     */
    function emergencyWithdrawToken(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(token != address(0), "Invalid token address");

        // Prevent withdrawing SHPE during active ICO - use withdrawRemainingTokens() instead
        if (token == address(shpeToken)) {
            require(!icoActive, "Use withdrawRemainingTokens for SHPE after ICO ends");
        }

        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        if (balance != 0) {
            tokenContract.safeTransfer(to, balance);
            emit EmergencyTokenWithdrawn(token, to, balance);
        }
    }
}
