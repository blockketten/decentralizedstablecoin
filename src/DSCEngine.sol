// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

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
    error DSCEngine__HealthFactorBelowThreshold(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__TransferToBurnFailed();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Additional precision for chainlink price feeds
    uint256 private constant PRECISION = 1e18; // Precision for calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Value of 50 implies a CDP needs to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

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
        address indexed user,
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
     * @notice Follows CEI - Check, Effects, Interact pattern
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param amountCollateral The amount of collateral to be deposited
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        external
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
    ) external moreThanZero(amountCollateral) nonReentrant {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] -= amountCollateral; // transaction will revert if user tries to redeem more collateral than they have
        emit CollateralRedeemed(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            msg.sender,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__RedeemCollateralFailed();
        }
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }
    /**
     * @notice follows CEI - Check, Effects, Interact pattern
     * @param amountDscToMint The amount of stablecoin tokens to be minted
     * @notice Minted stablecoins must have more collateral value than the threshold collateralization ratio
     *
     *
     */

    function mintDsc(
        uint256 amountDscToMint
    ) external moreThanZero(amountDscToMint) nonReentrant {
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
        s_dscMinted[msg.sender] -= amountDscToBurn;
        bool success = i.dsc.transferFrom(
            msg.sender,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferToBurnFailed();
        }
        i_dsc.burn(amountDscToBurn);
        _revertIfHealthFactorBelowThreshold(msg.sender); // Unlikely that burning DSC will ever negatively impact health ratio, but it's good to check
    }

    function liquidate() external {}

    function getHealthFactor() external {}

    /*//////////////////////////////////////////////////////////////
                     PRIVATE AND INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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

    function _HealthFactor(address user) private view returns (uint256) {
        // get total DSC minted by user
        // get value of total collateral deposited by user
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // Health factor = collateral value / DSC minted. If this value is less than 1, the user is at risk of liquidation
        // example 1: 150 USD worth of ETH and 100 DSC tokens. 150 * 50 = 7500. 7500 / 100 = 75. Health factor is 75/100 = 0.75, which is less than 1, so the user is at risk of liquidation
        // example2 : 1000 USD worth of ETH and 100 DSC tokens. 1000 * 50 / 100 = 500. Health factor is 500 / 100 = 5, which is greater than 1, so the user is not at risk of liquidation
    }

    /**
     * @notice reverts transaction if health factor is below threshold
     */
    function _revertIfHealthFactorBelowThreshold(address user) internal view {
        uint256 userhealthFactor = _HealthFactor(user);
        if (userhealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowThreshold(userhealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                   PUBLIC AND EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
        (, int256 price, , , ) = priceFeed.latestRoundData(); //If the price of ETH is $2000, then the price returned will be 2000 * 10^8
        return
            (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }
}
