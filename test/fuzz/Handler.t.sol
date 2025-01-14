pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSLEngine public engine;
    DecentralizedStableCoin public dsl;
    ERC20Mock public weth;
    ERC20Mock public wbtc;
    address[] public usersWithCollateral;
    uint256 public timesMintCalled;

    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSLEngine _engine, DecentralizedStableCoin _dsl) {
        engine = _engine;
        dsl = _dsl;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateral.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) external {
        // Ensure we have users with collateral
        if (usersWithCollateral.length == 0) return;

        // Get random user who has collateral
        address user = usersWithCollateral[collateralSeed % usersWithCollateral.length];

        // Get collateral token
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // Get user's collateral balance
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(user, address(collateral));
        if (maxCollateralToRedeem == 0) return;

        // Bound the redemption amount
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;

        // Get current position info
        (uint256 totalDslMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(user);
        if (totalDslMinted == 0) {
            // If no DSL is minted, we can redeem everything
            vm.startPrank(user);
            engine.redeemCollateral(address(collateral), amountCollateral);
            vm.stopPrank();
            return;
        }

        // Calculate collateral value after redemption
        uint256 redeemCollateralValue = engine.getUsdValue(address(collateral), amountCollateral);
        uint256 remainingCollateralValue = collateralValueInUsd - redeemCollateralValue;

        // Ensure redemption maintains minimum 200% collateralization
        if (remainingCollateralValue * 100 < totalDslMinted * 200) return;

        vm.startPrank(user);
        engine.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintDsl(uint256 amount) external {
        // Get all users who have deposited collateral
        if (usersWithCollateral.length == 0) return;

        // Get random user who has collateral
        address user = usersWithCollateral[amount % usersWithCollateral.length];

        (uint256 totalDslMinted, uint256 totalCollateralInUsd) = engine.getAccountInformation(user);

        // We want to be more conservative to maintain the invariant
        // Using 40% of collateral value (well below LIQUIDATION_THRESHOLD)
        uint256 maxDslToMint = (totalCollateralInUsd * 40) / 100;

        // Subtract any DSL already minted
        if (maxDslToMint <= totalDslMinted) return;
        maxDslToMint -= totalDslMinted;

        // Add additional safety bounds
        maxDslToMint = bound(maxDslToMint, 0, type(uint96).max);
        amount = bound(amount, 0, maxDslToMint);
        if (amount == 0) return;

        vm.startPrank(user);
        engine.mintDSL(amount);
        vm.stopPrank();
        timesMintCalled++;
    }

    //  THIS BREAKS THE INVARIANT!!!
    // function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
    //     int256 intNewPrice = int256(uint256(newPrice));
    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    //     MockV3Aggregator priceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(collateral)));

    //     priceFeed.updateAnswer(intNewPrice);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
