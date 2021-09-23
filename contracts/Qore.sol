// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
      ___       ___       ___       ___       ___
     /\  \     /\__\     /\  \     /\  \     /\  \
    /::\  \   /:/ _/_   /::\  \   _\:\  \    \:\  \
    \:\:\__\ /:/_/\__\ /::\:\__\ /\/::\__\   /::\__\
     \::/  / \:\/:/  / \:\::/  / \::/\/__/  /:/\/__/
     /:/  /   \::/  /   \::/  /   \:\__\    \/__/
     \/__/     \/__/     \/__/     \/__/

*
* MIT License
* ===========
*
* Copyright (c) 2021 QubitFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IQToken.sol";
import "./interfaces/IQValidator.sol";
import "./interfaces/IFlashLoanReceiver.sol";

import "./QoreAdmin.sol";

contract Qore is QoreAdmin {
    using SafeMath for uint;

    /* ========== CONSTANT VARIABLES ========== */

    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint public constant FLASHLOAN_FEE = 5e14; // 0.05%

    /* ========== STATE VARIABLES ========== */

    mapping(address => address[]) public marketListOfUsers; // (account => qTokenAddress[])
    mapping(address => mapping(address => bool)) public usersOfMarket; // (qTokenAddress => (account => joined))
    address[] public totalUserList; // do not use

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Qore_init();
    }

    /* ========== MODIFIERS ========== */

    modifier onlyMemberOfMarket(address qToken) {
        require(usersOfMarket[qToken][msg.sender], "Qore: must enter market");
        _;
    }

    modifier onlyMarket() {
        bool fromMarket = false;
        for (uint i = 0; i < markets.length; i++) {
            if (msg.sender == markets[i]) {
                fromMarket = true;
                break;
            }
        }
        require(fromMarket == true, "Qore: caller should be market");
        _;
    }

    /* ========== VIEWS ========== */

    function allMarkets() external view override returns (address[] memory) {
        return markets;
    }

    function marketInfoOf(address qToken) external view override returns (QConstant.MarketInfo memory) {
        return marketInfos[qToken];
    }

    function marketListOf(address account) external view override returns (address[] memory) {
        return marketListOfUsers[account];
    }

    function checkMembership(address account, address qToken) external view override returns (bool) {
        return usersOfMarket[qToken][account];
    }

    function accountLiquidityOf(address account) external view override returns (uint collateralInUSD, uint supplyInUSD, uint borrowInUSD) {
        return IQValidator(qValidator).getAccountLiquidity(account);
    }

    function distributionInfoOf(address market) external view override returns (QConstant.DistributionInfo memory) {
        return qDistributor.distributionInfoOf(market);
    }

    function accountDistributionInfoOf(address market, address account) external view override returns (QConstant.DistributionAccountInfo memory) {
        return qDistributor.accountDistributionInfoOf(market, account);
    }

    function apyDistributionOf(address market, address account) external view override returns (QConstant.DistributionAPY memory) {
        return qDistributor.apyDistributionOf(market, account);
    }

    function distributionSpeedOf(address qToken) external view override returns (uint supplySpeed, uint borrowSpeed) {
        QConstant.DistributionInfo memory distribution = qDistributor.distributionInfoOf(qToken);
        return (distribution.supplySpeed, distribution.borrowSpeed);
    }

    function boostedRatioOf(address market, address account) external view override returns (uint boostedSupplyRatio, uint boostedBorrowRatio) {
        return qDistributor.boostedRatioOf(market, account);
    }

    function accruedQubit(address account) external view override returns (uint) {
        return qDistributor.accruedQubit(markets, account);
    }

    function accruedQubit(address market, address account) external view override returns (uint) {
        address[] memory _markets = new address[](1);
        _markets[0] = market;
        return qDistributor.accruedQubit(_markets, account);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function enterMarkets(address[] memory qTokens) public override {
        for (uint i = 0; i < qTokens.length; i++) {
            _enterMarket(payable(qTokens[i]), msg.sender);
        }
    }

    function exitMarket(address qToken) external override onlyListedMarket(qToken) onlyMemberOfMarket(qToken) {
        QConstant.AccountSnapshot memory snapshot = IQToken(qToken).accruedAccountSnapshot(msg.sender);
        require(snapshot.borrowBalance == 0, "Qore: borrow balance must be zero");
        require(
            IQValidator(qValidator).redeemAllowed(qToken, msg.sender, snapshot.qTokenBalance),
            "Qore: cannot redeem"
        );

        _removeUserMarket(qToken, msg.sender);
        emit MarketExited(qToken, msg.sender);
    }

    function supply(address qToken, uint uAmount)
        external
        payable
        override
        onlyListedMarket(qToken)
        nonReentrant
        returns (uint)
    {
        uAmount = IQToken(qToken).underlying() == address(WBNB) ? msg.value : uAmount;

        uint qAmount = IQToken(qToken).supply{ value: msg.value }(msg.sender, uAmount);
        qDistributor.notifySupplyUpdated(qToken, msg.sender);

        return qAmount;
    }

    function redeemToken(address qToken, uint qAmount)
        external
        override
        onlyListedMarket(qToken)
        nonReentrant
        returns (uint)
    {
        uint uAmountRedeem = IQToken(qToken).redeemToken(msg.sender, qAmount);
        qDistributor.notifySupplyUpdated(qToken, msg.sender);

        return uAmountRedeem;
    }

    function redeemUnderlying(address qToken, uint uAmount)
        external
        override
        onlyListedMarket(qToken)
        nonReentrant
        returns (uint)
    {
        uint uAmountRedeem = IQToken(qToken).redeemUnderlying(msg.sender, uAmount);
        qDistributor.notifySupplyUpdated(qToken, msg.sender);

        return uAmountRedeem;
    }

    function borrow(address qToken, uint amount) external override onlyListedMarket(qToken) nonReentrant {
        _enterMarket(qToken, msg.sender);
        require(IQValidator(qValidator).borrowAllowed(qToken, msg.sender, amount), "Qore: cannot borrow");

        IQToken(payable(qToken)).borrow(msg.sender, amount);
        qDistributor.notifyBorrowUpdated(qToken, msg.sender);
    }

    function repayBorrow(address qToken, uint amount) external payable override onlyListedMarket(qToken) nonReentrant {
        IQToken(payable(qToken)).repayBorrow{ value: msg.value }(msg.sender, amount);
        qDistributor.notifyBorrowUpdated(qToken, msg.sender);
    }

    function repayBorrowBehalf(
        address qToken,
        address borrower,
        uint amount
    ) external payable override onlyListedMarket(qToken) nonReentrant {
        IQToken(payable(qToken)).repayBorrowBehalf{ value: msg.value }(msg.sender, borrower, amount);
        qDistributor.notifyBorrowUpdated(qToken, borrower);
    }

    function liquidateBorrow(
        address qTokenBorrowed,
        address qTokenCollateral,
        address borrower,
        uint amount
    ) external payable override nonReentrant {
        amount = IQToken(qTokenBorrowed).underlying() == address(WBNB) ? msg.value : amount;
        require(marketInfos[qTokenBorrowed].isListed && marketInfos[qTokenCollateral].isListed, "Qore: invalid market");
        require(usersOfMarket[qTokenCollateral][borrower], "Qore: not a collateral");
        require(marketInfos[qTokenCollateral].collateralFactor > 0, "Qore: not a collateral");
        require(
            IQValidator(qValidator).liquidateAllowed(qTokenBorrowed, borrower, amount, closeFactor),
            "Qore: cannot liquidate borrow"
        );

        uint qAmountToSeize = IQToken(qTokenBorrowed).liquidateBorrow{ value: msg.value }(
            qTokenCollateral,
            msg.sender,
            borrower,
            amount
        );
        IQToken(qTokenCollateral).seize(msg.sender, borrower, qAmountToSeize);
        qDistributor.notifyTransferred(qTokenCollateral, borrower, msg.sender);
        qDistributor.notifyBorrowUpdated(qTokenBorrowed, borrower);
    }

    function claimQubit() external override nonReentrant {
        qDistributor.claimQubit(markets, msg.sender);
    }

    function claimQubit(address market) external override nonReentrant {
        address[] memory _markets = new address[](1);
        _markets[0] = market;
        qDistributor.claimQubit(_markets, msg.sender);
    }

    function transferTokens(address spender, address src, address dst, uint amount) external override nonReentrant onlyMarket {
        IQToken(msg.sender).transferTokensInternal(spender, src, dst, amount);
        qDistributor.notifyTransferred(msg.sender, src, dst);
    }

    /* ========== RESTRICTED FUNCTION FOR WHITELIST ========== */

    function flashLoan(address receiverAddress, address[] calldata markets, uint[] calldata amounts, bytes calldata params) external override onlyWhitelisted {
        require(markets.length == amounts.length, "Qore: inconsistent arguments");

        uint[] memory fees = new uint[](markets.length);
        address[] memory underlyings = new address[](markets.length);

        IFlashLoanReceiver receiver = IFlashLoanReceiver(receiverAddress);

        // send asset to receiver
        for (uint i = 0; i < markets.length; i++) {
            IQToken market = IQToken(markets[i]);
            underlyings[i] = market.underlying();
            require(market.getCash() > amounts[i], "Qore: not enough reserve");

            fees[i] = amounts[i].mul(FLASHLOAN_FEE).div(1e18);

            market.transferUnderlyingTo(receiverAddress, amounts[i]);
        }

        require(receiver.executeOperation(markets, amounts, fees, msg.sender, params),
            "Qore: invalid flash loan executor");

        // bring back asset from receiver
        for (uint i = 0; i < markets.length; i++) {
            IQToken market = IQToken(markets[i]);

            market.transferUnderlyingFromWithFee(receiverAddress, amounts[i], fees[i]);

            emit FlashLoan(receiverAddress, msg.sender,
            underlyings[i],
            amounts[i],
            fees[i]);
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _enterMarket(address qToken, address _account) internal onlyListedMarket(qToken) {
        if (!usersOfMarket[qToken][_account]) {
            usersOfMarket[qToken][_account] = true;
            marketListOfUsers[_account].push(qToken);
            emit MarketEntered(qToken, _account);
        }
    }

    function _removeUserMarket(address qTokenToExit, address _account) private {
        require(marketListOfUsers[_account].length > 0, "Qore: cannot pop user market");
        delete usersOfMarket[qTokenToExit][_account];

        uint length = marketListOfUsers[_account].length;
        for (uint i = 0; i < length; i++) {
            if (marketListOfUsers[_account][i] == qTokenToExit) {
                marketListOfUsers[_account][i] = marketListOfUsers[_account][length - 1];
                marketListOfUsers[_account].pop();
                break;
            }
        }
    }
}
