//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DSC.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    DeployDSC public deployDSC;
    HelperConfig public config;

    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 1 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_DSC_MINTED = 500e18;
    uint256 public constant REDEEM_AMOUNT = 0.5 ether;

    function setUp() public {
        deployDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployDSC.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
    }

    /////////////////////////////////////////////
    ///////////DEPOSIT COLLATERAL TESTS//////////
    /////////////////////////////////////////////

    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // approve the contract to spend the collateral
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertsIfTokenCollateralIsNotSupported() public {
        vm.startPrank(user);
        ERC20Mock mockToken = new ERC20Mock("Mock Token", "MOCK", user, 18);
        // ERC20Mock(mockToken).mint(user, AMOUNT_COLLATERAL);
        ERC20Mock(mockToken).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(mockToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCollateralDepositedGetsRecorded() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userCollateralBalance = dscEngine.getUserCollateralDeposited(user, weth);
        assertEq(userCollateralBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    /////////// MINT DSC TESTS///////////////////
    /////////////////////////////////////////////

    modifier DepositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        _;
        vm.stopPrank();
    }

    // Your test deposits 1 WETH as collateral and tries to mint 1000 DSC.
    // With your mock price feeds, 1 WETH = $2000, so 1 WETH = $2,000 collateral.
    // If your liquidation threshold is 50% (i.e., 200% collateralization), the user should only be able to mint up to $1,000 DSC.
    // Minting 1000 DSC ($1000 if DSC is $1) should not revert, but minting 2,000 DSC

    function testMintDSCRevertsIfHealthFactorIsTooLow() public DepositedCollateral {
        vm.startPrank(user);
        // uint256 expectedHealthFactor = dscEngine.getHealthFactor(user);
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 minted = 2000e18;
        uint256 threshold = (collateralValue * 50) / 100; // 50% threshold
        uint256 expectedHealthFactor = (threshold * 1e18) / minted;
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBelowThreshold.selector, expectedHealthFactor)
        );
        dscEngine.mintDSC(2000e18); // This should fail due to low health factor
        vm.stopPrank();
    }

    function testMintDSCUpdatesDSCBalance() public DepositedCollateral {
        vm.startPrank(user);
        uint256 initialDSCBalance = dsc.balanceOf(user);
        dscEngine.mintDSC(AMOUNT_DSC_MINTED);
        uint256 newDSCBalance = dsc.balanceOf(user);
        assertEq(newDSCBalance, initialDSCBalance + AMOUNT_DSC_MINTED, "DSC balance should increase after minting");
        vm.stopPrank();
    }

    function testMintDSCUpdatesHealthFactor() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialHealthFactor = dscEngine.getHealthFactor(user);
        dscEngine.mintDSC(AMOUNT_DSC_MINTED);
        uint256 newHealthFactor = dscEngine.getHealthFactor(user);
        assertGt(initialHealthFactor, newHealthFactor, "Health factor should decrease after minting DSC");
        vm.stopPrank();
    }

    function testMintDSCRevertsIfAmountIsZero() public DepositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDSC(0); // Minting 0 DSC should revert
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    ///////////REDEEM COLLATERAL TESTS///////////
    /////////////////////////////////////////////

    modifier HasMintedDSC() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDSC(AMOUNT_DSC_MINTED); // Mint 500 DSC
        _;
        vm.stopPrank();
    }

    // Your test deposits 1 WETH as collateral and tries to mint 500 DSC.
    // With your mock price feeds, 1 WETH = $2,000, so 1 WETH = $2,000 collateral.
    // If your liquidation threshold is 50% (i.e., 200% collateralization), the user must keep at least $1,000 collateral for 500 DSC minted.
    // The user can redeem up to 0.5 WETH ($1,000), leaving 0.5 WETH ($1,000) as collateral.
    // Redeeming more than 0.5 WETH will drop the health factor below the threshold and revert.

    function testRedeemCollateralRevertsIfHealthFactorIsTooLow() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialCollateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 redeemAmountInUSD = dscEngine.getPriceInUSD(weth, 0.9 ether); // Redeem 0.9 WETH
        uint256 collateralValueAfterRedeem = initialCollateralValue - redeemAmountInUSD;
        uint256 threshold = (collateralValueAfterRedeem * 50) / 100; // 50% threshold
        uint256 expectedHealthFactor = (threshold * 1e18) / AMOUNT_DSC_MINTED;
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBelowThreshold.selector, expectedHealthFactor)
        );
        dscEngine.redeemCollateral(weth, 0.9 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralUpdatesHealthFactor() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialHealthFactor = dscEngine.getHealthFactor(user);
        dscEngine.redeemCollateral(weth, REDEEM_AMOUNT);
        uint256 newHealthFactor = dscEngine.getHealthFactor(user);
        assertGt(initialHealthFactor, newHealthFactor, "Health factor should decrease after redeeming collateral");
        vm.stopPrank();
    }

    function testRedeemCollateralUpdatesCollateralValue() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialCollateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 redeemAmountInUSD = dscEngine.getPriceInUSD(weth, REDEEM_AMOUNT);
        dscEngine.redeemCollateral(weth, REDEEM_AMOUNT);
        uint256 newCollateralValue = dscEngine.getAccountCollateralValue(user);
        assertEq(
            newCollateralValue,
            initialCollateralValue - redeemAmountInUSD,
            "Collateral value should decrease after redeeming collateral"
        );
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsIfAmountIsZero() public HasMintedDSC {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0); // Redeeming 0 WETH should revert
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    /////////// BURN DSC TESTS///////////////////
    /////////////////////////////////////////////

    function testBurnDSCUpdatesDSCBalance() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialDSCBalance = dsc.balanceOf(user);
        uint256 amountToBurn = AMOUNT_DSC_MINTED;
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDSC(amountToBurn);
        uint256 newDSCBalance = dsc.balanceOf(user);
        assertEq(newDSCBalance, initialDSCBalance - amountToBurn, "DSC balance should decrease after burning");
        vm.stopPrank();
    }

    function testBurnDSCRevertsIfAmountIsZero() public HasMintedDSC {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDSC(0); // Burning 0 DSC should revert
        vm.stopPrank();
    }

    function testBurnDSCUpdatesHealthFactor() public HasMintedDSC {
        vm.startPrank(user);
        uint256 initialHealthFactor = dscEngine.getHealthFactor(user);
        uint256 amountToBurn = AMOUNT_DSC_MINTED / 2;
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDSC(amountToBurn);
        uint256 newHealthFactor = dscEngine.getHealthFactor(user);
        assertGt(newHealthFactor, initialHealthFactor, "Health factor should increase after burning DSC");
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    /////////// LIQUIDATE TESTS//////////////////
    /////////////////////////////////////////////

    function testLiquidateUserRevertsIfHealthFactorIsAboveThreshold() public HasMintedDSC {
        vm.startPrank(liquidator);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorAboveThreshold.selector, userHealthFactor)
        );
        dscEngine.liquidate(weth, user, AMOUNT_DSC_MINTED);
        vm.stopPrank();
    }

    function testLiquidateUserUpdatesCollateralAndDSCBalance() public HasMintedDSC {
        // The `HasMintedDSC` modifier runs as `user`. We are currently pranking as `user`.
        // We transfer the minted DSC from the user to the liquidator to set up the test.
        dsc.transfer(liquidator, AMOUNT_DSC_MINTED);
        vm.stopPrank(); // End the prank on `user` from the modifier.

        uint256 LiquidationAmount = AMOUNT_DSC_MINTED; // Amount of LiquidationAmount
        // Make the user's position unhealthy by dropping the collateral price
        // Initial WETH price is $2000. User has 1 WETH ($2000) and 500 DSC debt. HF = 2.
        // To make HF < 1, collateral value must be < $1000. We set WETH price to $999.
        int256 newWethPrice = 999e8; // $999 with 8 decimals
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(newWethPrice);

        // Get initial balances for the liquidator
        uint256 liquidatorInitialWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 liquidatorInitialDscBalance = dsc.balanceOf(liquidator);
        (, uint256 userInitialCollateralValueInUSD,) = dscEngine.getAccountInformation(user);

        // Liquidator approves the engine and liquidates the user
        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), LiquidationAmount);
        dscEngine.liquidate(weth, user, LiquidationAmount);
        vm.stopPrank();

        // Check final states
        uint256 liquidatorFinalWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 liquidatorFinalDscBalance = dsc.balanceOf(liquidator);
        (uint256 userFinalDscMinted, uint256 userFinalCollateralValueInUSD,) = dscEngine.getAccountInformation(user);

        // 1. Liquidator's DSC balance should decrease by the debt they covered.
        assertEq(liquidatorFinalDscBalance, liquidatorInitialDscBalance - LiquidationAmount);

        // 2. Liquidator should receive the user's collateral plus a bonus.
        uint256 tokenAmountFromDebt = dscEngine.getTokenAmountFromUsd(weth, LiquidationAmount);
        uint256 bonusCollateral = (tokenAmountFromDebt * 10) / 100; // LIQUIDATION_BONUS is 10%
        uint256 expectedCollateralReceived = tokenAmountFromDebt + bonusCollateral;
        assertEq(liquidatorFinalWethBalance, liquidatorInitialWethBalance + expectedCollateralReceived);

        // 3. User's DSC debt should be reduced to 0.
        assertEq(userFinalDscMinted, 0);

        // 4. User's collateral value should be reduced by the amount liquidated.
        uint256 collateralSeized = expectedCollateralReceived; // This is the WETH amount
        uint256 valueOfCollateralSeized = dscEngine.getPriceInUSD(weth, collateralSeized);
        assertEq(userFinalCollateralValueInUSD, userInitialCollateralValueInUSD - valueOfCollateralSeized);
    }

    // This test creates a scenario where a liquidation is possible (health factor < 1)
    // but the liquidation would not improve the user's health factor.
    // This happens when the user's collateralization is very low, close to the liquidation bonus.
    function testLiquidateRevertsIfHealthFactorNotImproved() public HasMintedDSC {
        dsc.transfer(liquidator, AMOUNT_DSC_MINTED);
        vm.stopPrank(); // End the prank on `user` from the modifier.

        int256 newWethPrice = 550e8; // $550 with 8 decimals
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(newWethPrice);

        vm.startPrank(liquidator);
        dsc.approve(address(dscEngine), AMOUNT_DSC_MINTED);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dscEngine.liquidate(weth, user, 100e18); // Liquidate a portion of the debt
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    ////////////PRICE TESTS/////////////////////
    /////////////////////////////////////////////

    function testGetTokenfromUsd() public view {
        uint256 amountInUSD = 1000e18; // $1000
        uint256 expectedTokenAmount = dscEngine.getTokenAmountFromUsd(weth, amountInUSD);
        assertEq(expectedTokenAmount, 5e17); // 1 WETH = $2000, so $1000 = 0.5 WETH
    }

    function testGetPriceInUSD() public view {
        uint256 ethamount = 5e18;
        uint256 priceInUSD = dscEngine.getPriceInUSD(weth, ethamount);
        assertEq(priceInUSD, 5e18 * 2000);
    }

    function testGetCollateralValueInUSD() public DepositedCollateral {
        vm.startPrank(user);
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dscEngine.getPriceInUSD(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue, "Collateral value should match the expected value");
        vm.stopPrank();
    }

    //////////////////////////////////////////////////
    /// REDEEM COLLATERAL FOR DSC TESTS //////////////
    //////////////////////////////////////////////////

    function testRedeemCollateralForDSC() public HasMintedDSC {
        vm.startPrank(user);
        uint256 collateralToRedeem = 0.1 ether;
        uint256 dscToBurn = 100e18;

        uint256 initialCollateral = dscEngine.getUserCollateralDeposited(user, weth);
        uint256 initialDscBalance = dsc.balanceOf(user);

        dsc.approve(address(dscEngine), dscToBurn);
        dscEngine.redeemCollateralforDSC(weth, collateralToRedeem, dscToBurn);

        uint256 finalCollateral = dscEngine.getUserCollateralDeposited(user, weth);
        uint256 finalDscBalance = dsc.balanceOf(user);

        assertEq(finalCollateral, initialCollateral - collateralToRedeem);
        assertEq(finalDscBalance, initialDscBalance - dscToBurn);
        vm.stopPrank();
    }

    function testDepositCollateralAndMintDSC() public {
        vm.startPrank(user);
        uint256 collateralToDeposit = 1 ether;
        uint256 dscToMint = 100e18;

        uint256 initialCollateral = dscEngine.getUserCollateralDeposited(user, weth);
        uint256 initialDscBalance = dsc.balanceOf(user);

        ERC20Mock(weth).approve(address(dscEngine), collateralToDeposit);
        dscEngine.depositCollateralAndMintDSC(weth, collateralToDeposit, dscToMint);

        uint256 finalCollateral = dscEngine.getUserCollateralDeposited(user, weth);
        uint256 finalDscBalance = dsc.balanceOf(user);

        assertEq(finalCollateral, initialCollateral + collateralToDeposit);
        assertEq(finalDscBalance, initialDscBalance + dscToMint);
        vm.stopPrank();
    }
}
