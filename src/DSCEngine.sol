// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author William Bailey
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1:1 peg with the US dollar.
 * The stable coin has exogenous collateral in the form of ETH and BTC, is dollar pegged, and algorithmically stable.
 * It is similar to DAI, if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 * This stablecoin should always be "overcollateralized".
 * wETH and wBTC positions will be liquidated if the value of the collateral falls below a certain threshold collateralization ratio.
 */

contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DSCEngine__NeedsToBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__CollateralTokenNotSupported();
    error DSCEngine__DepositCollateralFailed();
    error DSCEngine__RedeemCollateralFailed();
    error DSCEngine__healthFactorBelowThreshold(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__TransferToBurnFailed();
    error DSCEngine__healthFactorTooHighToBeLiquidated(
        uint256 userHealthFactor
    );
    error DSCEngine__healthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Additional precision for chainlink price feeds
    uint256 private constant PRECISION = 1e18; // Precision for calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Value of 50 implies a CDP needs to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds; // Mapping of token address to price feed address
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited; // Mapping of user address to mapping of token address to amount of collateral
    mapping(address user => uint256 amountDscMinted) private s_dscMinted; // Mapping of user address to amount of DSC minted
    address[] private s_collateralTokenAddresses; // Array of token addresses

    DecentralizedStableCoin private immutable i_dsc; // The Decentralized Stable Coin

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsToBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateralToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__CollateralTokenNotSupported();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(
        address[] memory tokensAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokensAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokensAddresses.length; i++) {
            s_priceFeeds[tokensAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokenAddresses.push(tokensAddresses[i]); // adds addresses of collateral tokens to array
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param amountCollateral The amount of collateral to be deposited
     * @param amountDscToMint The amount of stablecoin tokens to be minted
     * @notice This function is a convenience function that allows users to deposit collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param amountCollateral The amount of collateral to be redeemed
     * @param amountDscToBurn The amount of stablecoin tokens to be burned
     * @notice This function is a convenience function that allows users to redeem collateral and burn DSC in one transaction
     */

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral); //redeemCollateral() already checks health factor, not necessary to check again here
    }

    // in order to redeem collateral:
    // 1. check health factor to see if above 1 AFTER collateral pulled
    // 2. burn DSC
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    // If a user's position is nearing undercollateralization, anyone can call this function to liquidate the user's position
    // Liquidator takes $75 backing $50 of DSC, burns the DSC, and takes the collateral, walking away with $25 profit
    // Essentially, the liquidator is buying the collateral at a discount i.e. getting paid to liquidate unhealthy positions

    /*
     * @param collateral The address of the collateral token
     * @param user The address of the user to be liquidated; their _healthFactor must be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC to be burned
     * @notice You can partially liquidate a user, so long as it brings their health factor above the threshold
     * @notice This function assumes that the protocol is roughly is 200% overcollateralized. This is the only way to ensure that the liquidator will always make a profit
     * @notice The liquidators receive a 10% bonus on the amount of DSC they burn, as payment for their services
     * @notice If the protocol was 100% overcollateralized, it would not be possible to liquidate a user without taking a loss and/or putting the protocol at risk
     *
     * Follows CEI - Check, Effects, Interact pattern
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__healthFactorTooHighToBeLiquidated(
                startingUserHealthFactor
            );
        }
        // We want to burn their DSC debt and take their collateral
        // Example: Bad user: $140 worth of ETH, $100 DSC
        // debtToCover = $100. How much ETH is equivalent to $100?

        uint256 tokenAmountfromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountfromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // 10% bonus for liquidator
        uint256 totalCollateralToRedeem = tokenAmountfromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            collateral,
            totalCollateralToRedeem,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor < startingUserHealthFactor) {
            revert DSCEngine__healthFactorNotImproved();
        }
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    function getHealthFactor() external {}

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice follows CEI - Check, Effects, Interact pattern
     * @param amountDscToMint The amount of stablecoin tokens to be minted
     * @notice Minted stablecoins must have more collateral value than the threshold collateralization ratio
     *
     *
     */

    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorBelowThreshold(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(
        uint256 amountDscToBurn
    ) public moreThanZero(amountDscToBurn) {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender); // Unlikely that burning DSC will ever negatively impact health ratio, but it's good to check
    }

    /**
     * @notice Follows CEI - Check, Effects, Interact pattern
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param amountCollateral The amount of collateral to be deposited
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedCollateralToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__DepositCollateralFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                     PRIVATE AND INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /*
     * @dev Low-level internl function. Do not call unless function calling it is checking for health factor being broken
     */

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) public moreThanZero(amountDscToBurn) {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferToBurnFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; // transaction will revert if user tries to redeem more collateral than they have
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__RedeemCollateralFailed();
        }
    }

    /**
     * @notice Returns the health factor of a user (how close they are to liquidation)
     */

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        // get total DSC minted by user
        totalDscMinted = s_dscMinted[user];
        // get USD value of total collateral deposited by
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Returns the health factor of a user (how close they are to liquidation)
     */

    function _healthFactor(address user) private view returns (uint256) {
        // get total DSC minted by user
        // get value of total collateral deposited by user
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd); // Health factor = collateral value / DSC minted. If this value is less than 1, the user is at risk of liquidation
        // example 1: 150 USD worth of ETH and 100 DSC tokens. 150 * 50 = 7500. 7500 / 100 = 75. Health factor is 75/100 = 0.75, which is less than 1, so the user is at risk of liquidation
        // example2 : 1000 USD worth of ETH and 100 DSC tokens. 1000 * 50 / 100 = 500. Health factor is 500 / 100 = 5, which is greater than 1, so the user is not at risk of liquidation
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max; //This is needed if someone deposits collateral but has not DSC minted yet, which would cause a divide by zero error. With this line, the max uint256 value is returned, which is effectively infinity
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice reverts transaction if health factor is below threshold
     */
    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userhealthFactor = _healthFactor(user);
        if (userhealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__healthFactorBelowThreshold(userhealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                   PUBLIC AND EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData(); //If the price of ETH is $2000, then the price returned will be 2000 * 10^8
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through all tokens and get the summed value of the balance of each collateral token in USD

        for (uint256 i = 0; i < s_collateralTokenAddresses.length; i++) {
            address token = s_collateralTokenAddresses[i];
            uint256 amount = s_collateralDeposited[user][token];
            // uint256 price = IPriceFeed(s_priceFeeds[token]).getPrice();
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        //get price feed info
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData(); //If the price of ETH is $2000, then the price returned will be 2000 * 10^8
        return
            (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokenAddresses;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
