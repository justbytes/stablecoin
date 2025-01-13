pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSL} from "../mocks/MockMoreDebtDSL.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSL} from "../mocks/MockFailedMintDSL.sol";

contract DSLEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

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
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");

    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() external {
        deployer = new DeployDSL();
        (dsl, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, wethTokenAddress, wbtcTokenAddress,) = config.activeNetworkConfig();
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
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsl = new MockFailedTransferFrom();
        tokenAddresses.push(address(mockDsl));
        priceFeedAddresses.push(ethUsdPriceFeed);
        vm.prank(owner);
        DSLEngine mockDslEngine = new DSLEngine(tokenAddresses, priceFeedAddresses, address(mockDsl));
        mockDsl.mint(USER, AMOUNT_OF_COLLATERAL);

        vm.prank(owner);
        mockDsl.transferOwnership(address(mockDslEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsl)).approve(address(mockDslEngine), AMOUNT_OF_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSLEngine.DSLEngine__TransferFromFailed.selector);
        mockDslEngine.depositCollateral(address(mockDsl), AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
    }

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

        vm.startPrank(LIQUIDATOR);

        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsl.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDslMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDepositedCollateralAmount = engine.getTokenAmountFromUsd(wethTokenAddress, collateralValueInUsd);
        assertEq(totalDslMinted, 0);
        assertEq(expectedDepositedCollateralAmount, AMOUNT_OF_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT COLLATERAL AND MINT DSL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfMintedDslBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amount = (AMOUNT_OF_COLLATERAL * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amount, engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL));
        vm.expectRevert(
            abi.encodeWithSelector(DSLEngine.DSLEngine__HealthFactorIsBroken.selector, USER, expectedHealthFactor)
        );
        engine.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amount);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsl() {
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);
        engine.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsl {
        uint256 userBalance = dsl.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                           MINT DSL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSL mockDsl = new MockFailedMintDSL();
        tokenAddresses.push(wethTokenAddress);
        priceFeedAddresses.push(ethUsdPriceFeed);
        address owner = msg.sender;
        vm.prank(owner);
        DSLEngine mockDslEngine = new DSLEngine(tokenAddresses, priceFeedAddresses, address(mockDsl));
        mockDsl.transferOwnership(address(mockDslEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(mockDslEngine), AMOUNT_OF_COLLATERAL);

        vm.expectRevert(DSLEngine.DSLEngine__MintFailed.selector);
        mockDslEngine.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.expectRevert(DSLEngine.DSLEngine__ZeroAmountNotAllowed.selector);
        engine.mintDSL(0);
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // Get price from price feed
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        // Calculate the amount that would break the health factor
        uint256 amount = (AMOUNT_OF_COLLATERAL * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION;

        vm.startPrank(USER);
        // Calculate expected health factor
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amount, engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL));

        // Expect revert with the calculated health factor
        vm.expectRevert(
            abi.encodeWithSelector(DSLEngine.DSLEngine__HealthFactorIsBroken.selector, USER, expectedHealthFactor)
        );
        engine.mintDSL(amount);
        vm.stopPrank();
    }

    function testCanMintDSLWithSufficientCollateral() public depositedCollateral {
        uint256 collateralValueInUsd = engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        uint256 amount = collateralValueInUsd / 2; // Maintaining healthy collateral ratio

        vm.startPrank(USER);
        engine.mintDSL(amount);
        vm.stopPrank();

        (uint256 totalDslMinted,) = engine.getAccountInformation(USER);
        assertEq(totalDslMinted, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               BURN TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfBurnAmountIsZero() public {
        vm.expectRevert(DSLEngine.DSLEngine__ZeroAmountNotAllowed.selector);
        engine.burnDSL(0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.startPrank(USER);
        vm.expectRevert(DSLEngine.DSLEngine__BurnAmountIsGreaterThanUserBalance.selector);
        engine.burnDSL(1e18);
        vm.stopPrank();
    }

    function testCanBurnDSL() public depositedCollateralAndMintedDsl {
        // Arrange
        vm.startPrank(USER);
        dsl.approve(address(engine), amountToMint);

        // Get initial balances
        uint256 initialDslBalance = dsl.balanceOf(USER);
        (uint256 initialDslMinted,) = engine.getAccountInformation(USER);

        // Act
        engine.burnDSL(amountToMint);

        // Assert
        uint256 finalDslBalance = dsl.balanceOf(USER);
        (uint256 finalDslMinted,) = engine.getAccountInformation(USER);

        assertEq(finalDslBalance, initialDslBalance - amountToMint);
        assertEq(finalDslMinted, initialDslMinted - amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    // this test needs it's own setup

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsl = new MockFailedTransfer();
        tokenAddresses.push(address(mockDsl));
        priceFeedAddresses.push(ethUsdPriceFeed);
        vm.prank(owner);
        DSLEngine mockDslEngine = new DSLEngine(tokenAddresses, priceFeedAddresses, address(mockDsl));
        mockDsl.mint(USER, AMOUNT_OF_COLLATERAL);

        vm.prank(owner);
        mockDsl.transferOwnership(address(mockDslEngine));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsl)).approve(address(mockDslEngine), AMOUNT_OF_COLLATERAL);
        // Act / Assert
        mockDslEngine.depositCollateral(address(mockDsl), AMOUNT_OF_COLLATERAL);
        vm.expectRevert(DSLEngine.DSLEngine__RedeemCollateralTransferFailed.selector);
        mockDslEngine.redeemCollateral(address(mockDsl), AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
    }

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

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(engine));
        emit CollateralRedeemed(USER, USER, wethTokenAddress, AMOUNT_OF_COLLATERAL);
        vm.startPrank(USER);
        engine.redeemCollateral(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsl {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsl {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSL mockDsl = new MockMoreDebtDSL(ethUsdPriceFeed);
        tokenAddresses.push(wethTokenAddress);
        priceFeedAddresses.push(ethUsdPriceFeed);
        address owner = msg.sender;
        vm.prank(owner);
        DSLEngine mockDsce = new DSLEngine(tokenAddresses, priceFeedAddresses, address(mockDsl));
        mockDsl.transferOwnership(address(mockDsce));

        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(mockDsce), AMOUNT_OF_COLLATERAL);
        mockDsce.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Setup the liquidator with small collateral
        uint256 collateralToCover = 1 ether;
        ERC20Mock(wethTokenAddress).mint(LIQUIDATOR, collateralToCover);

        // Setup the liquidator
        vm.startPrank(LIQUIDATOR);

        ERC20Mock(wethTokenAddress).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDSL(wethTokenAddress, collateralToCover, amountToMint);
        mockDsl.approve(address(mockDsce), debtToCover);

        console2.log("Before price change", mockDsce.getHealthFactor(USER));
        // Drop the price to make user's position liquidatable
        int256 ethUsdUpdatedPrice = 18e8; // $18 per ETH
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        console2.log("After price change", mockDsce.getHealthFactor(USER));

        // Act/Assert
        vm.expectRevert(DSLEngine.DSLEngine__HealthFactorIsNotImproved.selector);
        mockDsce.liquidate(wethTokenAddress, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsl {
        uint256 collateralToCover = 1 ether;
        ERC20Mock(wethTokenAddress).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wethTokenAddress).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSL(wethTokenAddress, collateralToCover, amountToMint);
        dsl.approve(address(engine), amountToMint);

        vm.expectRevert(DSLEngine.DSLEngine__HealthFactorIsNotBroken.selector);
        engine.liquidate(wethTokenAddress, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        // User deposits collateral and mints DSL
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);
        engine.depositCollateralAndMintDSL(wethTokenAddress, AMOUNT_OF_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Drop the price to make user's position liquidatable
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Setup liquidator
        uint256 collateralToCover = 20 ether;
        ERC20Mock(wethTokenAddress).mint(LIQUIDATOR, collateralToCover);

        // Liquidator deposits collateral and mints DSL
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wethTokenAddress).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSL(wethTokenAddress, collateralToCover, amountToMint); // Mint the same amount as user's debt
        dsl.approve(address(engine), amountToMint);

        // Perform liquidation
        engine.liquidate(wethTokenAddress, USER, amountToMint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(wethTokenAddress).balanceOf(LIQUIDATOR);
        console2.log("liquidatorWethBalance", liquidatorWethBalance);
        console2.log("amountToMint", engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint));
        console2.log("getTokenAmountFromUsd", engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint));
        console2.log("engine.getLiquidationBonus()", engine.getLiquidationBonus());
        uint256 expectedWeth = engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint)
            + (engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint) / engine.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint)
            + (engine.getTokenAmountFromUsd(wethTokenAddress, amountToMint) / engine.getLiquidationBonus());

        uint256 usdAmountLiquidated = engine.getUsdValue(wethTokenAddress, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = engine.getCollateralTokenPriceFeed(wethTokenAddress);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], wethTokenAddress);
        assertEq(collateralTokens[1], wbtcTokenAddress);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInformation(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(USER, wethTokenAddress);
        assertEq(collateralBalance, AMOUNT_OF_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(wethTokenAddress).approve(address(engine), AMOUNT_OF_COLLATERAL);
        engine.depositCollateral(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = engine.getUsdValue(wethTokenAddress, AMOUNT_OF_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsl() public view {
        address dslAddress = engine.getDsl();
        assertEq(dslAddress, address(dsl));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
