
# Decentralized Stablecoin

## Overview

This repository contains smart contracts for a decentralized stablecoin that aims to maintain a 1:1 price peg with the US dollar. The smart contracts and scripts are written in Solidity, using the Foundry toolchain. The design of the stablecoin is a simplified version of MakerDAO and DAI: deposited WETH and WBTC are used as collateral against which stablecoins can be minted. In other words, the stablecoins issued by this protocol are actually representations of collateralized debt positions (CDPs). The protocol aims to maintain a 200% collateral-to-debt ratio; this overcollateralization is meant to provide a significant enough buffer to price shocks that the protocol always remains fully collateralized. When an individual borrowing account's health ratio falls below the minimum health ratio, their position can be liquidated by anyone. The liquidator will receive a reward in the form of 10% of the value of the stablecoins burned. It is possible only partially liquidate a user's position, so long as their health ratio is brought back to an acceptable level.

The DSCEngine contract owns the "DecentralizedStablecoin" ERC-20 token contract and is responsible for almost all of the protocol logic. It leverages Chainlink price feeds to determine the USD value of collateral whenever a function that relies on this information is called. 

## Table of Contents

- [Decentralized Stablecoin](#decentralized-stablecoin)
  - [Overview](#overview)
  - [Table of Contents](#table-of-contents)
  - [Getting Started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Installation](#installation)
    - [Deployment on Anvil](#deployment-on-anvil)
    - [Deployment on Ethereum Sepolia](#deployment-on-ethereum-sepolia)
    - [Testing](#testing)
  - [Contract Details](#contract-details)
    - [Imports](#imports)
    - [Errors](#errors)
    - [State Variables](#state-variables)
    - [Events](#events)
    - [Modifiers](#modifiers)
    - [Constructor](#constructor)
    - [External Functions](#external-functions)
    - [Public Functions](#public-functions)
    - [Private and Internal Functions](#private-and-internal-functions)
    - [Public and External View Functions](#public-and-external-view-functions)
  - [Using the Contracts](#using-the-contracts)
  - [Future Improvements](#future-improvements)
  - [License](#license)

## Getting Started

These instructions will help you set up the project on your local machine for development and testing purposes.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/)
- A small balance of Sepolia $ETH + $WETH and/or $WBTC : These can be acquired from faucets and/or directly from the WETH contract on Sepolia

### Installation

Clone the repository and install the necessary dependencies:

```bash
git clone https://github.com/yourusername/DecentralizedStablecoin.git
cd DecentralizedStablecoin
make install
```
### Deployment on Anvil

To deploy on the Anvil local network:

1. Open a second terminal and pass 

```bash
anvil
```
to initiate a local Anvil network

2. Return to the first terminal and pass

```bash
make deploy
```

The make file contains all the values and logic to deploy the contracts on the Anvil network without any further input.

Mock ERC20 and Chainlink V3 aggregator contracts will be deployed to the Anvil network, to ensure that price feed and ERC-20 tokens interactions work. 

### Deployment on Ethereum Sepolia

To deploy the smart contract on Ethereum Sepolia, you need to configure environment variables and deploy the contract using Foundry.

1. Create a keystore that encrypts and stores your private key securely:

```bash
cast wallet import <keystore account name> –interactive
```

You will need to type in your private key and then a password that you must remember to decrypt the private key later.

2. Create a `.env` file in the project root and add your environment variables:

```env
SEPOLIA_RPC_URL=<Your Sepolia RPC URL>
ACCOUNT=<Your keystore account name>
ETHERSCAN_API_KEY=<Your Etherscan API Key>
```

3.  Deploy the contract the contract on Sepolia:

```bash
make deploy ARGS="--network sepolia"
```

You will need to enter the aforementioned keystore password to complete the deployment

### Testing

The contracts in this repo are tested with a variety of unit and fuzz tests. The fuzz tests have an accompying handler script, to ensure that the fuzz testing performed is useful.

To run the tests, use the following command:

```bash
forge test
```

## Contract Details

### Imports

- `DecentralizedStableCoin`: The stablecoin contract that users interact with for minting and burning stablecoins.
- `ReentrancyGuard`: A module from OpenZeppelin to prevent reentrancy attacks.
- `IERC20`: Interface for interacting with ERC20 tokens, allowing deposits and transfers.
- `AggregatorV3Interface`: Chainlink's interface for accessing price feed data.
- `OracleLib`: Library for interacting with oracle price data to ensure up-to-date and accurate price information.

### Errors

- `DSCEngine__NeedsToBeMoreThanZero`: Thrown when an operation involving a zero amount is attempted.
- `DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength`: Thrown when there is a mismatch in the lengths of token and price feed address arrays during initialization.
- `DSCEngine__CollateralTokenNotSupported`: Thrown when an unsupported token is used as collateral.
- `DSCEngine__DepositCollateralFailed`: Thrown when depositing collateral fails.
- `DSCEngine__RedeemCollateralFailed`: Thrown when redeeming collateral fails.
- `DSCEngine__healthFactorBelowThreshold`: Thrown when a user's health factor is below the acceptable threshold.
- `DSCEngine__MintFailed`: Thrown when minting stablecoins fails.
- `DSCEngine__TransferToBurnFailed`: Thrown when a transfer for burning stablecoins fails.
- `DSCEngine__healthFactorTooHighToBeLiquidated`: Thrown when attempting to liquidate a position with a health factor above the liquidation threshold.
- `DSCEngine__healthFactorNotImproved`: Thrown when a liquidation attempt does not improve a user's health factor.

### State Variables

- `ADDITIONAL_FEED_PRECISION`: Additional precision factor for Chainlink price feeds.
- `PRECISION`: General precision used for calculations in the contract.
- `LIQUIDATION_THRESHOLD`: The threshold percentage above which positions must remain collateralized.
- `LIQUIDATION_PRECISION`: Used to calculate the liquidation threshold.
- `MIN_HEALTH_FACTOR`: Minimum health factor required to avoid liquidation.
- `LIQUIDATION_BONUS`: Bonus percentage given to liquidators.
- `s_priceFeeds`: Maps token addresses to their respective Chainlink price feed addresses.
- `s_collateralDeposited`: Maps user addresses to their collateral deposits, allowing tracking of collateral type and amount.
- `s_dscMinted`: Maps user addresses to the amount of DSC minted by each user.
- `s_collateralTokenAddresses`: An array storing the addresses of allowed collateral tokens.
- `i_dsc`: An immutable reference to the Decentralized Stable Coin instance.

### Events

- `CollateralDeposited`: Emitted when a user deposits collateral, containing user address, token address, and deposit amount.
- `CollateralRedeemed`: Emitted when collateral is redeemed, containing addresses involved and the amount redeemed.

### Modifiers

- `moreThanZero`: Ensures that any input amount is greater than zero, preventing zero-value operations.
- `isAllowedCollateralToken`: Ensures that the collateral token used is supported by checking if a price feed is available.

### Constructor

Initializes the contract with arrays of token addresses and price feed addresses, ensuring both arrays have matching lengths. It sets up price feed mappings and records the collateral tokens allowed within the system. The constructor also sets the address of the Decentralized Stable Coin contract.

### External Functions

- `depositCollateralAndMintDsc`: Allows users to deposit collateral and mint stablecoins in one transaction. The function takes the collateral token address, collateral amount, and the amount of stablecoin to mint as parameters.
- `redeemCollateralForDsc`: Allows users to redeem collateral and burn stablecoins in a single transaction. The function takes the collateral token address, collateral amount, and the amount of stablecoin to burn as parameters.

### Public Functions

- `redeemCollateral`: Redeems a specified amount of collateral for a user, checking the user's health factor post-redemption to ensure it remains above the threshold.
- `liquidate`: Allows any user to liquidate an undercollateralized position. The liquidator repays a portion of the debt, burns DSC, and receives the corresponding collateral plus a liquidation bonus.
- `mintDsc`: Mints a specified amount of DSC for the caller, ensuring that the collateralization ratio remains above the threshold.
- `burnDsc`: Burns a specified amount of DSC from the caller's balance, checking the health factor afterward to ensure it remains stable.
- `depositCollateral`: Deposits a specified amount of a given collateral token for the caller, transferring the tokens to the contract and updating internal records.

### Private and Internal Functions

- `_burnDsc`: Internal function to handle the burning of DSC, reducing the user's minted DSC balance and interacting with the DSC contract.
- `_redeemCollateral`: Internal function to facilitate the redemption of collateral, adjusting user balances and transferring tokens.
- `_getAccountInformation`: Internal view function to retrieve a user's total DSC minted and collateral value in USD.
- `_healthFactor`: Calculates a user's health factor, a measure of collateralization, by comparing total DSC minted against collateral value.
- `_calculateHealthFactor`: Internal pure function for calculating the health factor, preventing division by zero errors by returning max value for unminted collateral positions.
- `_revertIfHealthFactorBelowThreshold`: Internal view function to revert transactions if the user's health factor is below the minimum threshold.

### Public and External View Functions

- `calculateHealthFactor`: Exposes the internal health factor calculation logic for external users.
- `getTokenAmountFromUsd`: Converts a USD amount to the equivalent token amount using the current price feed.
- `getAccountCollateralValue`: Retrieves the total collateral value in USD for a given user by summing up the values of deposited tokens.
- `getUsdValue`: Calculates the USD value of a specified token amount using its price feed.
- `getAccountInformation`: Provides external access to a user's total DSC minted and collateral value.
- `getPrecision`: Returns the precision constant used in calculations.
- `getAdditionalFeedPrecision`: Returns the additional precision constant for price feeds.
- `getLiquidationThreshold`: Returns the liquidation threshold percentage.
- `getLiquidationBonus`: Returns the liquidation bonus percentage.
- `getLiquidationPrecision`: Returns the liquidation precision constant.
- `getMinHealthFactor`: Returns the minimum health factor constant.
- `getCollateralTokens`: Returns the array of supported collateral token addresses.
- `getDsc`: Returns the address of the Decentralized Stable Coin contract.
- `getCollateralTokenPriceFeed`: Returns the price feed address for a given token.
- `getHealthFactor`: Retrieves a user's current health factor.
- `getCollateralBalanceOfUser`: Provides the balance of a specified collateral token held by a user.

## Using the Contracts

Remember to manually approve the DSCEngine contract to transfer WETH and/or WBTC tokens on your behalf by calling the approve() function on the WTH and/or WBTC contract(s) before attempting to deposit them as collateral into the DSCEngine contract. Failing to do this will cause the deposit transaction to revert.

## Future Improvements

This protocol assumes that overall collateralization always remains above 100%. If collateral prices were to fall rapidly enough and the overall collateralization fell below 100%, it would not be possible to pay the 10% bonus to liquidators without making the protocol even more insolvent. This is a known bug and would require a more sophisticated architecture overall to solve.

Testing coverage could be improved by writing more tests, particulary more invariant tests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
