//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DSC.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    /////////////////////////
    /////// Errors //////////
    /////////////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__PriceFeedsAndTokensAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__FailedToTransferCollateral();
    error DSCEngine__HealthFactorBelowThreshold(uint256 userHealthFactor);
    error DSCEngine__FailedToMintDSC();
    error DSCEngine__HealthFactorAboveThreshold(uint256 userHealthFactor);
    error DSCEngine__FailedToBurnDSC();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    /////// Variables ///////
    /////////////////////////

    uint256 private constant LIQIUDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRICE_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //10% liquidation bonus

    mapping(address token => address pricefeed) public s_priceFeeds;
    mapping(address user => mapping(address token => uint256)) private s_CollateralDeposited;
    mapping(address user => uint256 amountDSCminted) private s_amountDSCminted;

    address[] private s_CollateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////////
    /////// Events //////////
    /////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount);

    /////////////////////////
    /////// Modifiers ///////
    /////////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////////////////
    /////// Functions ///////
    /////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscaddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__PriceFeedsAndTokensAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            require(tokenAddresses[i] != address(0));
            require(priceFeedAddresses[i] != address(0));
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_CollateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscaddress);
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 tokenCollateralAmount,
        uint256 DSCamountToMint
    ) external {
        depositCollateral(tokenCollateralAddress, tokenCollateralAmount);
        mintDSC(DSCamountToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 tokenCollateralAmount)
        public
        moreThanZero(tokenCollateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_CollateralDeposited[msg.sender][tokenCollateralAddress] += tokenCollateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, tokenCollateralAmount);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), tokenCollateralAmount);
        if (!success) {
            revert DSCEngine__FailedToTransferCollateral();
        }
    }

    function mintDSC(uint256 DSCamountToMint) public nonReentrant moreThanZero(DSCamountToMint) {
        s_amountDSCminted[msg.sender] += DSCamountToMint;
        bool minted = i_dsc.mint(msg.sender, DSCamountToMint);
        if (!minted) {
            revert DSCEngine__FailedToMintDSC();
        }
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 tokenCollateralAmount) public nonReentrant moreThanZero(tokenCollateralAmount) isAllowedToken(tokenCollateralAddress) {
        _redeemCollateral(tokenCollateralAddress, tokenCollateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    function burnDSC (uint256 DSCamountToBurn) public nonReentrant moreThanZero(DSCamountToBurn) {
        _burnDSC(msg.sender, msg.sender, DSCamountToBurn);
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }

    function redeemCollateralforDSC(address tokenCollateralAddress,uint256 tokenCollateralAmount,uint256 DSCamountToBurn) public nonReentrant {
        _redeemCollateral(tokenCollateralAddress, tokenCollateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorBelowThreshold(msg.sender);
        _burnDSC(msg.sender, msg.sender, DSCamountToBurn);
    }

    function liquidate (address collateral, address user, uint256 debtToCover) public nonReentrant {
        uint256 startingUserHealthFactor = _healthfactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorAboveThreshold(startingUserHealthFactor);
        }
        uint256 tokenAmountFromDebt = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebt * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralRedeemed = tokenAmountFromDebt + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralRedeemed, user, msg.sender);
        _burnDSC(user, msg.sender, debtToCover);

        uint256 endingUserHealthFactor = _healthfactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor){
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorBelowThreshold(msg.sender);
    }
        

    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    ////////////  Internal & Private Functions  ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////

    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 tokenCollateralAmount,
        address from,
        address to
    ) private {
        s_CollateralDeposited[from][tokenCollateralAddress] -= tokenCollateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, tokenCollateralAmount);
        bool success = IERC20(tokenCollateralAddress).transfer(to, tokenCollateralAmount);
        if (!success) {
            revert DSCEngine__FailedToTransferCollateral();
        }
    }   

    function _burnDSC(address from, address to, uint256 DSCamountToBurn) private {
        s_amountDSCminted[from] -= DSCamountToBurn;
        bool success = i_dsc.transferFrom(to, address(this), DSCamountToBurn);
        if (!success) {
            revert DSCEngine__FailedToBurnDSC();
        }   
    }        

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 CollateralValueInUSD)
    {
        totalDSCMinted = s_amountDSCminted[user];
        CollateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthfactor(address user) private view returns (uint256 healthFactor) {
        (uint256 totalDSCMinted, uint256 CollateralValueInUSD) = _getAccountInformation(user);
        uint256 collateralValueAdjustedForThreshold = (CollateralValueInUSD * LIQIUDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        if (totalDSCMinted == 0) {
            return type(uint256).max;
        }
        healthFactor = (collateralValueAdjustedForThreshold * PRECISION) / totalDSCMinted;
    }

    function _revertIfHealthFactorBelowThreshold(address user) public view {
        uint256 userHealthFactor = _healthfactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBelowThreshold(userHealthFactor);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////\

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price,,,) = priceFeed.latestRoundData();
    return (usdAmountInWei * PRECISION) / (uint256(price) * PRICE_FEED_PRECISION);
    }

    //Loop over all tokens and calculate total collateral value in USD
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUSD) {
        for (uint256 i = 0; i < s_CollateralTokens.length; i++) {
            address token = s_CollateralTokens[i];
            uint256 amount = s_CollateralDeposited[user][token];
            totalCollateralValueInUSD += getPriceInUSD(token, amount);
        }
    }

    //Calculates the price of a token in USD based on the price feed for that token
    function getPriceInUSD(address token, uint256 amount) public view returns (uint256 priceInUSD) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        priceInUSD = ((uint256(price)*PRICE_FEED_PRECISION) * amount) / (PRECISION);
    }

    function getAccountInformation (address user)
        external
        view
        returns (
            uint256 totalDSCMinted,
            uint256 CollateralValueInUSD,
            uint256 healthFactor
        )
    {
        (totalDSCMinted, CollateralValueInUSD) = _getAccountInformation(user);
        healthFactor = _healthfactor(user);
    }

    function getUserCollateralDeposited(address user, address token) external view returns (uint256) {
        return s_CollateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthfactor(user);
    }
}
