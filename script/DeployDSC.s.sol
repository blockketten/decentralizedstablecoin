// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
// Importing the 'DecentralizedStableCoin' contract from the source directory, which will be
// deployed by this script.

import {DSCEngine} from "../src/DSCEngine.sol";
// Importing the 'DSCEngine' contract from the source directory, which serves as the core
// logic and management layer for the Decentralized Stable Coin system.

import {HelperConfig} from "./HelperConfig.s.sol";

// Definition of the 'DeployDSC' contract, which extends the 'Script' contract.
// This contract is responsible for deploying the Decentralized Stable Coin system.
contract DeployDSC is Script {
    address[] public tokenAddresses;
    // An array to store the addresses of tokens that will be supported by the DSCEngine.

    address[] public priceFeedAddresses;
    // An array to store the addresses of price feeds corresponding to each supported token.

    // The 'run' function is the main entry point for the deployment script. It returns
    // instances of the deployed contracts: DecentralizedStableCoin, DSCEngine, and HelperConfig.
    function run()
        external
        returns (DecentralizedStableCoin, DSCEngine, HelperConfig)
    {
        // Create an instance of the HelperConfig contract to access network-specific configuration.
        HelperConfig helperConfig = new HelperConfig();

        // Call the 'activeNetworkConfig' function from HelperConfig to retrieve:
        // - Addresses of price feeds for WETH and WBTC
        // - Addresses of the WETH and WBTC tokens
        // - The deployer's private key
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc
        ) = helperConfig.activeNetworkConfig();

        // Store the token addresses (WETH, WBTC) in the 'tokenAddresses' array.
        tokenAddresses = [weth, wbtc];

        // Store the price feed addresses (WETH/USD, WBTC/USD) in the 'priceFeedAddresses' array.
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // Begin broadcasting transactions with the Foundry VM, using the deployer's private key.
        vm.startBroadcast();

        DecentralizedStableCoin dsc = new DecentralizedStableCoin();

        console.log("Chain being deployed on is", block.chainid);
        console.log(
            "Token addresses are:",
            tokenAddresses[0],
            tokenAddresses[1]
        );
        console.log(
            "Price feed addresses are:",
            priceFeedAddresses[0],
            priceFeedAddresses[1]
        );

        console.log("DecentralizedStableCoin deployed at:", address(dsc));
        console.log("Current owner of DSC:", dsc.owner());

        // Pause for 15 seconds
        vm.sleep(15);

        // Deploy the DSCEngine contract, passing the token addresses, price feed addresses,
        // and the address of the newly deployed DecentralizedStableCoin contract.
        DSCEngine engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );
        console.log("DSCEngine deployed at:", address(engine));

        // Pause for another 15 seconds
        vm.sleep(15);

        // Transfer the ownership of the DecentralizedStableCoin contract to the DSCEngine contract.
        // This allows DSCEngine to manage and control the stable coin.
        console.log("Current owner of DSC before transfer:", dsc.owner());
        console.log("Address attempting to transfer ownership:", msg.sender);
        dsc.transferOwnership(address(engine));

        console.log("Ownership of DSC transferred to:", dsc.owner());
        // Pause for another 15 seconds
        vm.sleep(15);

        // Stop broadcasting transactions. This signifies the end of the deployment process.
        vm.stopBroadcast();

        // Return the deployed contract instances and the configuration used for deployment.
        return (dsc, engine, helperConfig);
    }
}
