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
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../interfaces/IPriceCalculator.sol";
import "../interfaces/IQToken.sol";
import "../interfaces/IQore.sol";
import "../interfaces/IDashboard.sol";
import "../interfaces/IQubitLocker.sol";
import "../interfaces/IBEP20.sol";


contract DashboardBSC is IDashboard, OwnableUpgradeable {
    using SafeMath for uint;

    /* ========== CONSTANT VARIABLES ========== */

    address private constant QBT = 0x17B7163cf1Dbd286E262ddc68b553D899B93f526;
    IPriceCalculator public constant priceCalculator = IPriceCalculator(0x20E5E35ba29dC3B540a1aee781D0814D5c77Bce6);

    /* ========== STATE VARIABLES ========== */

    IQore public qore;
    IQubitLocker public qubitLocker;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setQore(address _qore) external onlyOwner {
        require(_qore != address(0), "DashboardBSC: invalid qore address");
        require(address(qore) == address(0), "DashboardBSC: qore already set");
        qore = IQore(_qore);
    }

    function setLocker(address _qubitLocker) external onlyOwner {
        require(_qubitLocker != address(0), "DashboardBSC: invalid locker address");
        qubitLocker = IQubitLocker(_qubitLocker);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function qubitDataOf(address[] memory markets, address account) public view override returns (QubitData memory) {
        QubitData memory qubit;
        qubit.marketList = new MarketData[](markets.length);
        qubit.membershipList = new MembershipData[](markets.length);

        if (account != address(0)) {
            qubit.accountAcc = accountAccDataOf(account);
            qubit.locker = lockerDataOf(account);
        }

        for (uint i = 0; i < markets.length; i++) {
            qubit.marketList[i] = marketDataOf(markets[i]);

            if (account != address(0)) {
                qubit.membershipList[i] = membershipDataOf(markets[i], account);
            }
        }

        qubit.marketAverageBoostedRatio = _calculateAccMarketAverageBoostedRatio(markets);
        return qubit;
    }

    function marketDataOf(address market) public view override returns (MarketData memory) {
        MarketData memory marketData;
        QConstant.DistributionAPY memory apyDistribution = qore.apyDistributionOf(market, address(0));
        QConstant.DistributionInfo memory distributionInfo = qore.distributionInfoOf(market);
        IQToken qToken = IQToken(market);
        marketData.qToken = market;

        marketData.apySupply = qToken.supplyRatePerSec().mul(365 days);
        marketData.apyBorrow = qToken.borrowRatePerSec().mul(365 days);
        marketData.apySupplyQBT = apyDistribution.apySupplyQBT;
        marketData.apyBorrowQBT = apyDistribution.apyBorrowQBT;

        marketData.totalSupply = qToken.totalSupply().mul(qToken.exchangeRate()).div(1e18);
        marketData.totalBorrows = qToken.totalBorrow();
        marketData.totalBoostedSupply = distributionInfo.totalBoostedSupply;
        marketData.totalBoostedBorrow = distributionInfo.totalBoostedBorrow;

        marketData.cash = qToken.getCash();
        marketData.reserve = qToken.totalReserve();
        marketData.reserveFactor = qToken.reserveFactor();
        marketData.collateralFactor = qore.marketInfoOf(market).collateralFactor;
        marketData.exchangeRate = qToken.exchangeRate();
        marketData.borrowCap = qore.marketInfoOf(market).borrowCap;
        marketData.accInterestIndex = qToken.getAccInterestIndex();
        return marketData;
    }

    function membershipDataOf(address market, address account) public view override returns (MembershipData memory) {
        MembershipData memory membershipData;
        QConstant.DistributionAPY memory apyDistribution = qore.apyDistributionOf(market, account);
        QConstant.DistributionAccountInfo memory accountDistributionInfo = qore.accountDistributionInfoOf(market, account);

        membershipData.qToken = market;
        membershipData.membership = qore.checkMembership(account, market);
        membershipData.supply = IQToken(market).underlyingBalanceOf(account);
        membershipData.borrow = IQToken(market).borrowBalanceOf(account);
        membershipData.boostedSupply = accountDistributionInfo.boostedSupply;
        membershipData.boostedBorrow = accountDistributionInfo.boostedBorrow;
        membershipData.apyAccountSupplyQBT = apyDistribution.apyAccountSupplyQBT;
        membershipData.apyAccountBorrowQBT = apyDistribution.apyAccountBorrowQBT;
        return membershipData;
    }

    function accountAccDataOf(address account) public view override returns (AccountAccData memory) {
        AccountAccData memory accData;
        accData.accruedQubit = qore.accruedQubit(account);
        (accData.collateralInUSD,, accData.borrowInUSD) = qore.accountLiquidityOf(account);

        address[] memory markets = qore.allMarkets();
        uint[] memory prices = priceCalculator.getUnderlyingPrices(markets);
        for (uint i = 0; i < markets.length; i++) {
            accData.supplyInUSD = accData.supplyInUSD.add(IQToken(markets[i]).underlyingBalanceOf(account).mul(prices[i]).div(1e18));
        }
        uint totalValueInUSD = accData.supplyInUSD.add(accData.borrowInUSD);
        (accData.accApySupply, accData.accApySupplyQBT) = _calculateAccAccountSupplyAPYOf(account, markets, prices, totalValueInUSD);
        (accData.accApyBorrow, accData.accApyBorrowQBT) = _calculateAccAccountBorrowAPYOf(account, markets, prices, totalValueInUSD);
        accData.averageBoostedRatio = _calculateAccAccountAverageBoostedRatio(account, markets);
        return accData;
    }

    function lockerDataOf(address account) public view override returns (LockerData memory) {
        LockerData memory lockerInfo;

        lockerInfo.totalLocked = qubitLocker.totalBalance();
        lockerInfo.locked = qubitLocker.balanceOf(account);

        (uint totalScore, ) = qubitLocker.totalScore();
        lockerInfo.totalScore = totalScore;
        lockerInfo.score = qubitLocker.scoreOf(account);

        lockerInfo.available = qubitLocker.availableOf(account);
        lockerInfo.expiry = qubitLocker.expiryOf(account);
        return lockerInfo;
    }

    function totalValueLockedOf(address[] memory markets) public view returns (uint totalSupplyInUSD) {
        uint[] memory prices = priceCalculator.getUnderlyingPrices(markets);
        for (uint i = 0; i < markets.length; i++) {
            uint supplyInUSD = IQToken(markets[i]).getCash().mul(IQToken(markets[i]).exchangeRate()).div(1e18);
            totalSupplyInUSD = totalSupplyInUSD.add(supplyInUSD.mul(prices[i]).div(1e18));
        }
        return totalSupplyInUSD;
    }

    function totalCirculating() public view returns (uint) {
        return IBEP20(QBT).totalSupply()
                .sub(IBEP20(QBT).balanceOf(0xa7bc9a205A46017F47949F5Ee453cEBFcf42121b))      // reward Lock
                .sub(IBEP20(QBT).balanceOf(0xB224eD67C2F89Ae97758a9DB12163A6f30830EB2))      // developer's Supply Lock
                .sub(IBEP20(QBT).balanceOf(0x4c97c901B5147F8C1C7Ce3c5cF3eB83B44F244fE))      // MND Vault Lock
                .sub(IBEP20(QBT).balanceOf(0xB56290bEfc4216dc2A526a9022A76A1e4FDf122b))      // marketing Treasury
                .sub(IBEP20(QBT).balanceOf(0xAAf5d0dB947F835287b9432F677A51e9a1a01a35))      // security Treasury
                .sub(IBEP20(QBT).balanceOf(0xc7939B1Fa2E7662592b4d11dbE3C331bEE18FC85))      // Dev Treasury
//                .sub(qubitLocker.balanceOf(0x12C62464D8CF4a9Ca6f2EEAd1d7954A9fC21d053))      // QubitPool (lock forever)
                .sub(qubitLocker.totalBalance())                                             // QubitLocker
                .sub(IBEP20(QBT).balanceOf(0x67B806ab830801348ce719E0705cC2f2718117a1))      // reward Distributor (QDistributor)
                .sub(IBEP20(QBT).balanceOf(0xD1ad1943b70340783eD9814ffEdcAaAe459B6c39))      // PCB QBT-BNB pool reward lock
                .sub(IBEP20(QBT).balanceOf(0x89c527764f03BCb7dC469707B23b79C1D7Beb780));     // Orbit Bridge lock (displayed in Klaytn instead)
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _calculateAccAccountSupplyAPYOf(address account, address[] memory markets, uint[] memory prices, uint totalValueInUSD) private view returns (uint accApySupply, uint accApySupplyQBT) {
        for (uint i = 0; i < markets.length; i++) {
            QConstant.DistributionAPY memory apyDistribution = qore.apyDistributionOf(markets[i], account);

            uint supplyInUSD = IQToken(markets[i]).underlyingBalanceOf(account).mul(prices[i]).div(1e18);
            accApySupply = accApySupply.add(supplyInUSD.mul(IQToken(markets[i]).supplyRatePerSec().mul(365 days)).div(1e18));
            accApySupplyQBT = accApySupplyQBT.add(supplyInUSD.mul(apyDistribution.apyAccountSupplyQBT).div(1e18));
        }

        accApySupply = totalValueInUSD > 0 ? accApySupply.mul(1e18).div(totalValueInUSD) : 0;
        accApySupplyQBT = totalValueInUSD > 0 ? accApySupplyQBT.mul(1e18).div(totalValueInUSD) : 0;
    }

    function _calculateAccAccountBorrowAPYOf(address account, address[] memory markets, uint[] memory prices, uint totalValueInUSD) private view returns (uint accApyBorrow, uint accApyBorrowQBT) {
        for (uint i = 0; i < markets.length; i++) {
            QConstant.DistributionAPY memory apyDistribution = qore.apyDistributionOf(markets[i], account);

            uint borrowInUSD = IQToken(markets[i]).borrowBalanceOf(account).mul(prices[i]).div(1e18);
            accApyBorrow = accApyBorrow.add(borrowInUSD.mul(IQToken(markets[i]).borrowRatePerSec().mul(365 days)).div(1e18));
            accApyBorrowQBT = accApyBorrowQBT.add(borrowInUSD.mul(apyDistribution.apyAccountBorrowQBT).div(1e18));
        }

        accApyBorrow = totalValueInUSD > 0 ? accApyBorrow.mul(1e18).div(totalValueInUSD) : 0;
        accApyBorrowQBT = totalValueInUSD > 0 ? accApyBorrowQBT.mul(1e18).div(totalValueInUSD) : 0;
    }

    function _calculateAccAccountAverageBoostedRatio(address account, address[] memory markets) public view returns (uint averageBoostedRatio) {
        uint accBoostedCount = 0;
        for (uint i = 0; i < markets.length; i++) {
            (uint boostedSupplyRatio, uint boostedBorrowRatio) = qore.boostedRatioOf(markets[i], account);

            if (boostedSupplyRatio > 0) {
                averageBoostedRatio = averageBoostedRatio.add(boostedSupplyRatio);
                accBoostedCount++;
            }

            if (boostedBorrowRatio > 0) {
                averageBoostedRatio = averageBoostedRatio.add(boostedBorrowRatio);
                accBoostedCount++;
            }
        }
        return accBoostedCount > 0 ? averageBoostedRatio.div(accBoostedCount) : 0;
    }

    function _calculateAccMarketAverageBoostedRatio(address[] memory markets) public view returns (uint averageBoostedRatio) {
        uint accValueInUSD = 0;
        uint accBoostedValueInUSD = 0;

        uint[] memory prices = priceCalculator.getUnderlyingPrices(markets);
        for (uint i = 0; i < markets.length; i++) {
            QConstant.DistributionInfo memory distributionInfo = qore.distributionInfoOf(markets[i]);

            accBoostedValueInUSD = accBoostedValueInUSD.add(distributionInfo.totalBoostedSupply.mul(IQToken(markets[i]).exchangeRate()).mul(prices[i]).div(1e36));
            accBoostedValueInUSD = accBoostedValueInUSD.add(distributionInfo.totalBoostedBorrow.mul(IQToken(markets[i]).getAccInterestIndex()).mul(prices[i]).div(1e36));

            accValueInUSD = accValueInUSD.add(IQToken(markets[i]).totalSupply().mul(IQToken(markets[i]).exchangeRate()).mul(prices[i]).div(1e36));
            accValueInUSD = accValueInUSD.add(IQToken(markets[i]).totalBorrow().mul(prices[i]).div(1e18));
        }
        return accValueInUSD > 0 ? accBoostedValueInUSD.mul(1e18).div(accValueInUSD) : 0;
    }
}
