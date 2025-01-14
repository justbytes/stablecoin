pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSL} from "../../script/DeployDSL.s.sol";
import {DSLEngine} from "../../src/DSLEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DeployDSL public deployer;
    DSLEngine public engine;
    DecentralizedStableCoin public dsl;
    HelperConfig public config;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSL();
        (dsl, engine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        targetContract(address(engine));
    }

    function openInvariants_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsl.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));
        uint256 ethUsdValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 btcUsdValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        assert(ethUsdValue + btcUsdValue >= totalSupply);
    }
}

// Total supply of DSL should be less than the total collateral value

// Getter view functions should not revert
