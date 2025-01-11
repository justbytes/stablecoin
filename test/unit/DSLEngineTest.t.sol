pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSLEngineTest is Test {
    DeployDSL public deployer;
    HelperConfig public config;
    DecentralizedStableCoin public dsl;
    DSLEngine public engine;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public wethTokenAddress;
    address public wbtcTokenAddress;
    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_OF_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant PRECISION = 1e18;
    uint256 public amountToMint = 100 ether;

    function setUp() external {
        deployer = new DeployDSL();
        (dsl, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, wethTokenAddress, wbtcTokenAddress,) = config.activeNetworkConfig();
        console2.log("wethTokenAddress", wethTokenAddress);
        ERC20Mock(wethTokenAddress).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(wethTokenAddress);

        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSLEngine.DSLEngine__TokenAndPriceFeedLengthMismatch.selector);
        new DSLEngine(tokenAddresses, priceFeedAddresses, address(dsl));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18; // 15 * 2000 ($2000 is the initial price of the mock AggregatorV3Interface)
        uint256 actualUsd = engine.getUsdValue(wethTokenAddress, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWethAmount = 0.05 ether;
        uint256 actualWethAmount = engine.getTokenAmountFromUsd(wethTokenAddress, usdAmount);
        assertEq(actualWethAmount, expectedWethAmount);
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSITE COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);

        vm.expectRevert(DSLEngine.DSLEngine__ZeroAmountNotAllowed.selector);
        engine.depositCollateral(wethTokenAddress, 0);
        vm.stopPrank();
    }

    function testRevertIfCollateralIsNotAllowed() public {
        ERC20Mock randomToken = new ERC20Mock("Random", "RND", USER, AMOUNT_OF_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(DSLEngine.DSLEngine__CollateralNotSupported.selector, address(randomToken))
        );
        engine.depositCollateral(address(randomToken), AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);
        engine.depositCollateral(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDslMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDepositedCollateralAmount = engine.getTokenAmountFromUsd(wethTokenAddress, collateralValueInUsd);
        assertEq(totalDslMinted, 0);
        assertEq(expectedDepositedCollateralAmount, AMOUNT_OF_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                           MINT DSL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfMintAmountIsZero() public {
        vm.expectRevert(DSLEngine.DSLEngine__ZeroAmountNotAllowed.selector);
        engine.mintDSL(0);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // Get price from price feed
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        // Calculate the amount that would break the health factor
        uint256 amountToMint = (AMOUNT_OF_COLLATERAL * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;

        vm.startPrank(USER);
        // Calculate expected health factor
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL));

        // Expect revert with the calculated health factor
        vm.expectRevert(
            abi.encodeWithSelector(DSLEngine.DSLEngine__HealthFactorIsBroken.selector, USER, expectedHealthFactor)
        );
        engine.mintDSL(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDSLWithSufficientCollateral() public depositedCollateral {
        uint256 collateralValueInUsd = engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        uint256 amountToMint = collateralValueInUsd / 2; // Maintaining healthy collateral ratio

        vm.startPrank(USER);
        engine.mintDSL(amountToMint);
        vm.stopPrank();

        (uint256 totalDslMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDslMinted, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                      REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);
        engine.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amountToMint);
        vm.expectRevert(DSLEngine.DSLEngine__ZeroAmountNotAllowed.selector);
        engine.redeemCollateral(wethTokenAddress, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        engine.redeemCollateral(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        uint256 userBalance = ERC20Mock(wethTokenAddress).balanceOf(USER);
        assertEq(userBalance, AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
    }

    function testCantRedeemMoreThanDeposited() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(wethTokenAddress, AMOUNT_OF_COLLATERAL + 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    //fix this one
    // function testCantLiquidateGoodHealthFactor() public depositedCollateral {
    //     vm.startPrank(USER);
    //     vm.expectRevert(DSLEngine.DSLEngine__HealthFactorIsNotBroken.selector);
    //     engine.liquidate(wethTokenAddress, USER, 1);
    //     vm.stopPrank();
    // }

    // fix this one
    // function testCanLiquidateBasicScenario() public depositedCollateral {
    //     // Setup: USER mints maximum DSL
    //     uint256 collateralValueInUsd = engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL);
    //     uint256 maxDslToMint = (collateralValueInUsd * 50) / 100; // 50% collateral ratio
    //     vm.startPrank(USER);
    //     engine.mintDSL(maxDslToMint);
    //     vm.stopPrank();

    //     // Setup: Price drops by 50%
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8); // Price drops to $1000

    //     // Setup: Liquidator gets some DSL
    //     address liquidator = makeAddr("liquidator");
    //     uint256 debtToCover = 1 ether;
    //     engine.mintDSL(debtToCover);

    //     // Liquidation
    //     vm.startPrank(liquidator);
    //     engine.liquidate(wethTokenAddress, USER, debtToCover);
    //     vm.stopPrank();

    //     (uint256 userDslMinted,) = engine.getAccountInformation(USER);
    //     assertLt(userDslMinted, maxDslToMint);
    // }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], wethTokenAddress);
        assertEq(collateralTokens[1], wbtcTokenAddress);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, wethTokenAddress);
        assertEq(collateralBalance, AMOUNT_OF_COLLATERAL);
    }
}
