pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSLEngineTest is Test {
    DeployDSL public deployer;
    HelperConfig public config;
    DecentralizedStableCoin public dsl;
    DSLEngine public engine;
    address public ethUsdPriceFeed;
    address public wethTokenAddress;
    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_OF_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() external {
        deployer = new DeployDSL();
        (dsl, engine, config) = deployer.run();
        (ethUsdPriceFeed,, wethTokenAddress,,) = config.activeNetworkConfig();
        ERC20Mock(wethTokenAddress).mint(USER, STARTING_ERC20_BALANCE);
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
}
