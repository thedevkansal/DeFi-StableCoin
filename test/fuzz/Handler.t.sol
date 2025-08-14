// Handler is going to narrow down the way we call function

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DSC.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsc = _dsc;
        dsce = _dsce;
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateralToken = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateralToken.mint(msg.sender, amountCollateral); // ensure the user has enough collateral
        collateralToken.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateralToken), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateralToken = _getCollateralFromSeed(collateralSeed);
        address collateralAddress = address(collateralToken);
        uint256 maxAmountUserHas = dsce.getUserCollateralDeposited(msg.sender, collateralAddress);
        if (maxAmountUserHas == 0) {
            return;
        }

        (uint256 totalDscMinted, uint256 collateralValueInUsd,) = dsce.getAccountInformation(msg.sender);
        uint256 maxRedeemableFromHf;
        if (totalDscMinted > 0) {
            uint256 minCollateralValueInUsd = totalDscMinted * 2;
            if (collateralValueInUsd > minCollateralValueInUsd) {
                uint256 redeemableValueInUsd = collateralValueInUsd - minCollateralValueInUsd;
                maxRedeemableFromHf = dsce.getTokenAmountFromUsd(collateralAddress, redeemableValueInUsd);
            } else {
                maxRedeemableFromHf = 0;
            }
        } else {
            maxRedeemableFromHf = maxAmountUserHas;
        }

        uint256 maxToRedeem = maxRedeemableFromHf;
        if (maxToRedeem > maxAmountUserHas) {
            maxToRedeem = maxAmountUserHas;
        }
        amountCollateral = bound(amountCollateral, 0, maxToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        vm.startPrank(msg.sender);
        dsce.redeemCollateral(collateralAddress, amountCollateral);
        vm.stopPrank();
    }

    function mintDSC(uint256 addressSeed, uint256 amount) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd,) = dsce.getAccountInformation(sender);

        uint256 halfCollateralValue = collateralValueInUsd / 2;
        if (halfCollateralValue <= totalDscMinted) {
            return;
        }
        uint256 maxDscToMint = halfCollateralValue - totalDscMinted;

        amount = bound(amount, 1, maxDscToMint);
        if (amount <= 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDSC(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function burnDSC(uint256 addressSeed, uint256 amount) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        uint256 dscBalance = dsc.balanceOf(sender);
        if (dscBalance == 0) {
            return;
        }

        amount = bound(amount, 0, dscBalance);
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dsc.approve(address(dsce), amount);
        dsce.burnDSC(amount);
        vm.stopPrank();
    }
}
