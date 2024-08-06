// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    //uint256 public deployerKey;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_DEBT = 5 ether;
    uint256 public amountToMint;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, , weth, ) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 5e18;
        // 5e18 * 2000/ETH = 10000e18
        uint expectedUsdValue = 10000e18; //Need to refactor this to use the actual price feed when testing with sepolia
        uint256 actualUsdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                  COLLATERAL MANAGEMENT FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsToBeMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        ranToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__CollateralTokenNotSupported.selector
        );
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting()
        public
        depositedCollateral
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                   MINTING AND BURNING FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        COMBINED FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (AMOUNT_COLLATERAL *
                (uint256(price) * dsce.getAdditionalFeedPrecision())) /
            dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            amountToMint,
            dsce.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__healthFactorBelowThreshold.selector,
                expectedHealthFactor
            )
        );
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      HEALTH FACTOR FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCalculateHealthFactor() public view {
        // Test with various collateral and debt values
        assertEq(
            dsce.calculateHealthFactor(50 ether, 100 ether),
            1 ether,
            "Health factor should be 1 for 200% collateralization"
        );
        assertEq(
            dsce.calculateHealthFactor(50 ether, 200 ether),
            2 ether,
            "Health factor should be 2 for 400% collateralization"
        );
        assertEq(
            dsce.calculateHealthFactor(50 ether, 50 ether),
            0.5 ether,
            "Health factor should be 0.5 for 100% collateralization"
        );
        // Test with zero debt
        assertEq(
            dsce.calculateHealthFactor(0, 100 ether),
            type(uint256).max,
            "Health factor should be max for zero debt"
        );

        // Test with zero collateral
        assertEq(
            dsce.calculateHealthFactor(100 ether, 0),
            0,
            "Health factor should be 0 for zero collateral"
        );
    }

    /*//////////////////////////////////////////////////////////////
                       LIQUIDATION FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetterFunctions() public view {
        assertEq(dsce.getAdditionalFeedPrecision(), 1e10);
        assertEq(dsce.getPrecision(), 1e18);
        assertEq(dsce.getLiquidationThreshold(), 50);
        assertEq(dsce.getLiquidationBonus(), 10);
        assertEq(dsce.getMinHealthFactor(), 1e18);
        assertEq(dsce.getDsc(), address(dsc));
    }
}
