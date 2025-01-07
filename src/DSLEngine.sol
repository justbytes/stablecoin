pragma solidity ^0.8.16;

// Imports
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    error DSLEngine__CollateralNotSupported();
    error DSLEngine__TokenAndPriceFeedLengthMismatch();
    error DSLEngine__TransferFailed();
    error DSLEngine__HealthFactorIsBroken();

    /*//////////////////////////////////////////////////////////////
                                 STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    DecentralizedStableCoin private immutable i_dsl;
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSLMinted) private s_amountDSLMinted;
    address[] private s_collateralTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSLEngine__ZeroAmountNotAllowed();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSLEngine__CollateralNotSupported();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     */
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dslAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSLEngine__TokenAndPriceFeedLengthMismatch();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }

        i_dsl = DecentralizedStableCoin(_dslAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL & PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function depositCollateralAndMintDSL(address tokenCollateralAddress, uint256 amountOfCollateral) external {}

    /**
     * @notice Deposit collateral only if its is a supported token and the amount is more than 0
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountOfCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        external
        moreThanZero(amountOfCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountOfCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountOfCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountOfCollateral);
        if (!success) {
            revert DSLEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSL() external {}

    function redeemCollateral() external {}

    function mintDSL(uint256 amountToMint) external moreThanZero(amountToMint) nonReentrant {
        s_amountDSLMinted[msg.sender] += amountToMint;

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSL() external {}

    function liquidate() external {}

    /*//////////////////////////////////////////////////////////////
                    INTERNAL & PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        if (_healthFactor(user) < 1) {
            revert DSLEngine__HealthFactorIsBroken();
        }
    }

    /**
     * @notice Returns how close a user is to being liquidated
     * @param user The address of the user
     * @return The health factor of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDslMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return totalDslMinted / collateralValueInUsd;
    }

    /*//////////////////////////////////////////////////////////////
                   VIEW & PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getHealthFactor() external view returns (uint256) {}

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            uint256 price = getUsdValue(token, amount);
            totalCollateralValue += price;
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // TODO Implement AggregatorV3Interface
        return 0;
    }
}
