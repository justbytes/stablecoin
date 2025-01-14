pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSL public deployer;
    DSLEngine public engine;
    DecentralizedStableCoin public dsl;
    HelperConfig public config;
    address weth;
    address wbtc;
    Handler public handler;

    function setUp() external {
        deployer = new DeployDSL();
        (dsl, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, dsl);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsl.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));
        uint256 ethUsdValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 btcUsdValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value", ethUsdValue);
        console.log("btc value", btcUsdValue);
        console.log("totalSupply", totalSupply);
        console.log("times mint called", handler.timesMintCalled());

        assert(ethUsdValue + btcUsdValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {}
}

// Total supply of DSL should be less than the total collateral value

// Getter view functions should not revert
