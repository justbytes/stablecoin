pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {Script} from "forge-std/Script.sol";
import {DSLEngine} from "../src/DSLEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSL is Script {
    address[] public s_tokenAddresses;
    address[] public s_priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSLEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (
            address wethPriceFeedAddress,
            address wbtcPriceFeedAddress,
            address wethTokenAddress,
            address wbtcTokenAddress,
            uint256 deployerKey
        ) = config.activeNetworkConfig();

        s_tokenAddresses = [wethTokenAddress, wbtcTokenAddress];
        s_priceFeedAddresses = [wethPriceFeedAddress, wbtcPriceFeedAddress];

        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin dsl = new DecentralizedStableCoin();
        DSLEngine engine = new DSLEngine(s_tokenAddresses, s_priceFeedAddresses, address(dsl));

        dsl.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (dsl, engine, config);
    }
}
