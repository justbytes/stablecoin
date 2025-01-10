pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;
    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public constant ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    struct NetworkConfig {
        address wethPriceFeedAddress;
        address wbtcPriceFeedAddress;
        address wethTokenAddress;
        address wbtcTokenAddress;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getAnvilConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethPriceFeedAddress: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcPriceFeedAddress: 0x5fb1616F78dA7aFC9FF79e0371741a747D2a7F22,
            wethTokenAddress: 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9,
            wbtcTokenAddress: 0xf5c1F61deC83a5994a0cb96d30f8cF7A074B045b,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethPriceFeedAddress != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator wethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator wbtcPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wethToken = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);
        ERC20Mock wbtcToken = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);
        vm.stopBroadcast();

        return NetworkConfig({
            wethPriceFeedAddress: address(wethPriceFeed),
            wbtcPriceFeedAddress: address(wbtcPriceFeed),
            wethTokenAddress: address(wethToken),
            wbtcTokenAddress: address(wbtcToken),
            deployerKey: ANVIL_PRIVATE_KEY
        });
    }
}
