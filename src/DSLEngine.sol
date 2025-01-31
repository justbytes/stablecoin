pragma solidity ^0.8.16;

// Imports
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/OracleLib.sol";

/// @title DSLEngine
/// @author justbytes
/// @notice This contract should always be overcollateralized
/// @notice This contract is used to maintain a 1 token == $1 peg
/// @notice This contract handles all the logic for minting and redeeming DSL as well as depositing and withdrawing collateral
contract DSLEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSLEngine__ZeroAmountNotAllowed();
    error DSLEngine__CollateralNotSupported(address tokenAddress);
    error DSLEngine__TokenAndPriceFeedLengthMismatch();
    error DSLEngine__TransferFromFailed();
    error DSLEngine__HealthFactorIsBroken(address user, uint256 healthFactor);
    error DSLEngine__MintFailed();
    error DSLEngine__RedeemCollateralTransferFailed();
    error DSLEngine__BurnDSLTransferFromFailed();
    error DSLEngine__HealthFactorIsNotBroken();
    error DSLEngine__HealthFactorIsNotImproved();
    error DSLEngine__BurnAmountIsGreaterThanUserBalance();

    // Types
    using OracleLib for AggregatorV3Interface;
    /*//////////////////////////////////////////////////////////////
                                 STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 10;

    DecentralizedStableCoin private immutable i_dsl;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSLMinted) private s_amountDSLMinted;

    address[] private s_collateralTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSLEngine__ZeroAmountNotAllowed();
        }
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSLEngine__CollateralNotSupported(tokenAddress);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address _dslAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSLEngine__TokenAndPriceFeedLengthMismatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsl = DecentralizedStableCoin(_dslAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function depositCollateralAndMintDSL(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        uint256 amountOfDSLToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountOfCollateral);
        mintDSL(amountOfDSLToMint);
    }

    /**
     * @notice Deposit collateral only if its is a supported token and the amount is more than 0
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountOfCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        public
        moreThanZero(amountOfCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountOfCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountOfCollateral);
        if (!success) {
            revert DSLEngine__TransferFromFailed();
        }
    }

    function redeemCollateralForDSL(
        address tokenCollateralAddress,
        uint256 amountOfCollateral,
        uint256 amountOfDSLToBurn
    ) external {
        burnDSL(amountOfDSLToBurn);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountOfCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        external
        moreThanZero(amountOfCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountOfCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDSL(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        uint256 previousAmountDSLMinted = s_amountDSLMinted[msg.sender];
        s_amountDSLMinted[msg.sender] = previousAmountDSLMinted + amountToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsl.mint(msg.sender, amountToMint);
        if (!minted) {
            s_amountDSLMinted[msg.sender] = previousAmountDSLMinted;
            revert DSLEngine__MintFailed();
        }
    }

    function burnDSL(uint256 amount) public moreThanZero(amount) {
        _burnDSL(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // May need to be removed
    }

    function _burnDSL(uint256 amountOfDSLToBurn, address onBehalfOf, address dslFrom) private {
        // Check if user has enough DSL to burn first
        if (amountOfDSLToBurn > s_amountDSLMinted[onBehalfOf]) {
            revert DSLEngine__BurnAmountIsGreaterThanUserBalance();
        }

        // Only subtract after we've confirmed user has enough
        s_amountDSLMinted[onBehalfOf] -= amountOfDSLToBurn;

        // Burn the DSL
        bool success = i_dsl.transferFrom(dslFrom, address(this), amountOfDSLToBurn);
        if (!success) {
            revert DSLEngine__BurnDSLTransferFromFailed();
        }
        i_dsl.burn(amountOfDSLToBurn);
    }

    function liquidate(address collateralAddressToLiquidate, address userToBeLiquidated, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(userToBeLiquidated);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSLEngine__HealthFactorIsNotBroken();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralAddressToLiquidate, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(userToBeLiquidated, msg.sender, collateralAddressToLiquidate, totalCollateralToRedeem);

        _burnDSL(debtToCover, userToBeLiquidated, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(userToBeLiquidated);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSLEngine__HealthFactorIsNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountOfCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountOfCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountOfCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountOfCollateral);
        if (!success) {
            revert DSLEngine__RedeemCollateralTransferFailed();
        }
    }

    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDslMinted, uint256 collateralValueInUsd)
    {
        totalDslMinted = s_amountDSLMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // Check for enough collateral
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSLEngine__HealthFactorIsBroken(user, healthFactor);
        }
    }

    /**
     * @notice Returns how close a user is to being liquidated
     * @param user The address of the user
     * @return The health factor of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDslMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return calculateHealthFactor(totalDslMinted, collateralValueInUsd);
    }

    function calculateHealthFactor(uint256 totalDslMinted, uint256 collateralValueInUsd)
        public
        pure
        returns (uint256)
    {
        if (totalDslMinted == 0) return type(uint256).max;
        uint256 collateralValueWithThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueWithThreshold * PRECISION) / totalDslMinted;
    }

    /*//////////////////////////////////////////////////////////////
                   VIEW & PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getHealthFactor() external view returns (uint256) {}

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValue) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        // Price feeds have 8 decimals, but we want everything in terms of WEI (18 decimals)
        // ETH/USD price feed example: If ETH is $2000, answer will be 2000_00000000
        // We multiply by 1e10 to get it to 1e18 precision
        uint256 price = uint256(answer) * ADDITIONAL_FEED_PRECISION;
        // amount is in WEI (18 decimals)
        // price is now in 18 decimals
        // We divide by PRECISION (1e18) to cancel out the extra precision
        return (price * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address collateralAddressToLiquidate, uint256 usdAmountInWei)
        public
        view
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralAddressToLiquidate]);
        (, int256 answer,,,) = OracleLib.staleCheckLatestRoundData(priceFeed);
        return (usdAmountInWei * PRECISION) / (uint256(answer) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDslMinted, uint256 collateralValueInUsd)
    {
        (totalDslMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getDsl() external view returns (address) {
        return address(i_dsl);
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }
}
