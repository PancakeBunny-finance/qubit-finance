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

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "../library/WhitelistUpgradeable.sol";
import "../library/SafeToken.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IQDistributor.sol";
import "../interfaces/IQubitLocker.sol";
import "../interfaces/IQToken.sol";
import "../interfaces/IQore.sol";
import "../interfaces/IPriceCalculator.sol";

contract QDistributor is IQDistributor, WhitelistUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMath for uint;
    using SafeToken for address;

    /* ========== CONSTANT VARIABLES ========== */

    address private constant QBT = 0x17B7163cf1Dbd286E262ddc68b553D899B93f526;

    uint public constant BOOST_PORTION = 150;
    uint public constant BOOST_MAX = 250;
    uint private constant LAUNCH_TIMESTAMP = 1629784800;

    IQore public constant qore = IQore(0xF70314eb9c7Fe7D88E6af5aa7F898b3A162dcd48);
    IQubitLocker public constant qubitLocker = IQubitLocker(0xB8243be1D145a528687479723B394485cE3cE773);
    IPriceCalculator public constant priceCalculator = IPriceCalculator(0x20E5E35ba29dC3B540a1aee781D0814D5c77Bce6);

    /* ========== STATE VARIABLES ========== */

    mapping(address => QConstant.DistributionInfo) public distributions;
    mapping(address => mapping(address => QConstant.DistributionAccountInfo)) public accountDistributions;

    /* ========== MODIFIERS ========== */

    modifier updateDistributionOf(address market) {
        QConstant.DistributionInfo storage dist = distributions[market];
        if (dist.accruedAt == 0) {
            dist.accruedAt = block.timestamp;
        }

        uint timeElapsed = block.timestamp > dist.accruedAt ? block.timestamp.sub(dist.accruedAt) : 0;
        if (timeElapsed > 0) {
            if (dist.totalBoostedSupply > 0) {
                dist.accPerShareSupply = dist.accPerShareSupply.add(
                    dist.supplySpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedSupply)
                );
            }

            if (dist.totalBoostedBorrow > 0) {
                dist.accPerShareBorrow = dist.accPerShareBorrow.add(
                    dist.borrowSpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedBorrow)
                );
            }
        }
        dist.accruedAt = block.timestamp;
        _;
    }

    modifier onlyQore() {
        require(msg.sender == address(qore), "QDistributor: caller is not Qore");
        _;
    }

    /* ========== EVENTS ========== */

    event QubitDistributionSpeedUpdated(address indexed qToken, uint supplySpeed, uint borrowSpeed);
    event QubitClaimed(address indexed user, uint amount);

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __WhitelistUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setQubitDistributionSpeed(address qToken, uint supplySpeed, uint borrowSpeed) external onlyOwner updateDistributionOf(qToken) {
        QConstant.DistributionInfo storage dist = distributions[qToken];
        dist.supplySpeed = supplySpeed;
        dist.borrowSpeed = borrowSpeed;
        emit QubitDistributionSpeedUpdated(qToken, supplySpeed, borrowSpeed);
    }

    // For reward distribution to different network (such as Klaytn)
    function withdrawReward(address receiver, uint amount) external onlyOwner {
        QBT.safeTransfer(receiver, amount);
    }

    /* ========== VIEWS ========== */

    function accruedQubit(address[] calldata markets, address account) external view override returns (uint) {
        uint amount = 0;
        for (uint i = 0; i < markets.length; i++) {
            amount = amount.add(_accruedQubit(markets[i], account));
        }
        return amount;
    }

    function distributionInfoOf(address market) external view override returns (QConstant.DistributionInfo memory) {
        return distributions[market];
    }

    function accountDistributionInfoOf(address market, address account) external view override returns (QConstant.DistributionAccountInfo memory) {
        return accountDistributions[market][account];
    }

    function apyDistributionOf(address market, address account) external view override returns (QConstant.DistributionAPY memory) {
        (uint apySupplyQBT, uint apyBorrowQBT) = _calculateMarketDistributionAPY(market);
        (uint apyAccountSupplyQBT, uint apyAccountBorrowQBT) = _calculateAccountDistributionAPY(market, account);
        return QConstant.DistributionAPY(apySupplyQBT, apyBorrowQBT, apyAccountSupplyQBT, apyAccountBorrowQBT);
    }

    function boostedRatioOf(address market, address account) external view override returns (uint boostedSupplyRatio, uint boostedBorrowRatio) {
        uint accountSupply = IQToken(market).balanceOf(account);
        uint accountBorrow = IQToken(market).borrowBalanceOf(account).mul(1e18).div(IQToken(market).getAccInterestIndex());

        boostedSupplyRatio = accountSupply > 0 ? accountDistributions[market][account].boostedSupply.mul(1e18).div(accountSupply) : 0;
        boostedBorrowRatio = accountBorrow > 0 ? accountDistributions[market][account].boostedBorrow.mul(1e18).div(accountBorrow) : 0;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function notifySupplyUpdated(address market, address user) external override nonReentrant onlyQore updateDistributionOf(market) {
        if (block.timestamp < LAUNCH_TIMESTAMP)
            return;

        QConstant.DistributionInfo storage dist = distributions[market];
        QConstant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) {
            uint accQubitPerShare = dist.accPerShareSupply.sub(userInfo.accPerShareSupply);
            userInfo.accruedQubit = userInfo.accruedQubit.add(accQubitPerShare.mul(userInfo.boostedSupply).div(1e18));
        }
        userInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSupply = _calculateBoostedSupply(market, user);
        dist.totalBoostedSupply = dist.totalBoostedSupply.add(boostedSupply).sub(userInfo.boostedSupply);
        userInfo.boostedSupply = boostedSupply;
    }

    function notifyBorrowUpdated(address market, address user) external override nonReentrant onlyQore updateDistributionOf(market) {
        if (block.timestamp < LAUNCH_TIMESTAMP)
            return;

        QConstant.DistributionInfo storage dist = distributions[market];
        QConstant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedBorrow > 0) {
            uint accQubitPerShare = dist.accPerShareBorrow.sub(userInfo.accPerShareBorrow);
            userInfo.accruedQubit = userInfo.accruedQubit.add(accQubitPerShare.mul(userInfo.boostedBorrow).div(1e18));
        }
        userInfo.accPerShareBorrow = dist.accPerShareBorrow;

        uint boostedBorrow = _calculateBoostedBorrow(market, user);
        dist.totalBoostedBorrow = dist.totalBoostedBorrow.add(boostedBorrow).sub(userInfo.boostedBorrow);
        userInfo.boostedBorrow = boostedBorrow;
    }

    function notifyTransferred(address qToken, address sender, address receiver) external override nonReentrant onlyQore updateDistributionOf(qToken) {
        if (block.timestamp < LAUNCH_TIMESTAMP)
            return;

        require(sender != receiver, "QDistributor: invalid transfer");
        QConstant.DistributionInfo storage dist = distributions[qToken];
        QConstant.DistributionAccountInfo storage senderInfo = accountDistributions[qToken][sender];
        QConstant.DistributionAccountInfo storage receiverInfo = accountDistributions[qToken][receiver];

        if (senderInfo.boostedSupply > 0) {
            uint accQubitPerShare = dist.accPerShareSupply.sub(senderInfo.accPerShareSupply);
            senderInfo.accruedQubit = senderInfo.accruedQubit.add(
                accQubitPerShare.mul(senderInfo.boostedSupply).div(1e18)
            );
        }
        senderInfo.accPerShareSupply = dist.accPerShareSupply;

        if (receiverInfo.boostedSupply > 0) {
            uint accQubitPerShare = dist.accPerShareSupply.sub(receiverInfo.accPerShareSupply);
            receiverInfo.accruedQubit = receiverInfo.accruedQubit.add(
                accQubitPerShare.mul(receiverInfo.boostedSupply).div(1e18)
            );
        }
        receiverInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSenderSupply = _calculateBoostedSupply(qToken, sender);
        uint boostedReceiverSupply = _calculateBoostedSupply(qToken, receiver);
        dist.totalBoostedSupply = dist
            .totalBoostedSupply
            .add(boostedSenderSupply)
            .add(boostedReceiverSupply)
            .sub(senderInfo.boostedSupply)
            .sub(receiverInfo.boostedSupply);
        senderInfo.boostedSupply = boostedSenderSupply;
        receiverInfo.boostedSupply = boostedReceiverSupply;
    }

    function claimQubit(address[] calldata markets, address account) external override onlyQore {
        uint amount = 0;
        uint userScore = qubitLocker.scoreOf(account);
        (uint totalScore, ) = qubitLocker.totalScore();

        for (uint i = 0; i < markets.length; i++) {
            amount = amount.add(_claimQubit(markets[i], account, userScore, totalScore));
        }

        amount = Math.min(amount, IBEP20(QBT).balanceOf(address(this)));
        QBT.safeTransfer(account, amount);
        emit QubitClaimed(account, amount);
    }

    function kick(address user) external override nonReentrant {
        if (block.timestamp < LAUNCH_TIMESTAMP)
            return;

        uint userScore = qubitLocker.scoreOf(user);
        require(userScore == 0, "QDistributor: kick not allowed");
        (uint totalScore, ) = qubitLocker.totalScore();

        address[] memory markets = qore.allMarkets();
        for (uint i = 0; i < markets.length; i++) {
            address market = markets[i];
            QConstant.DistributionAccountInfo memory userInfo = accountDistributions[market][user];
            if (userInfo.boostedSupply > 0) _updateSupplyOf(market, user, userScore, totalScore);
            if (userInfo.boostedBorrow > 0) _updateBorrowOf(market, user, userScore, totalScore);
        }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _accruedQubit(address market, address user) private view returns (uint) {
        QConstant.DistributionInfo memory dist = distributions[market];
        QConstant.DistributionAccountInfo memory userInfo = accountDistributions[market][user];

        uint amount = userInfo.accruedQubit;
        uint accPerShareSupply = dist.accPerShareSupply;
        uint accPerShareBorrow = dist.accPerShareBorrow;

        uint timeElapsed = block.timestamp > dist.accruedAt ? block.timestamp.sub(dist.accruedAt) : 0;
        if (
            timeElapsed > 0 ||
            (accPerShareSupply != userInfo.accPerShareSupply) ||
            (accPerShareBorrow != userInfo.accPerShareBorrow)
        ) {
            if (dist.totalBoostedSupply > 0) {
                accPerShareSupply = accPerShareSupply.add(
                    dist.supplySpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedSupply)
                );

                uint pendingQubit = userInfo.boostedSupply.mul(accPerShareSupply.sub(userInfo.accPerShareSupply)).div(
                    1e18
                );
                amount = amount.add(pendingQubit);
            }

            if (dist.totalBoostedBorrow > 0) {
                accPerShareBorrow = accPerShareBorrow.add(
                    dist.borrowSpeed.mul(timeElapsed).mul(1e18).div(dist.totalBoostedBorrow)
                );

                uint pendingQubit = userInfo.boostedBorrow.mul(accPerShareBorrow.sub(userInfo.accPerShareBorrow)).div(
                    1e18
                );
                amount = amount.add(pendingQubit);
            }
        }
        return amount;
    }

    function _claimQubit(address market, address user, uint userScore, uint totalScore) private returns (uint amount) {
        QConstant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) _updateSupplyOf(market, user, userScore, totalScore);
        if (userInfo.boostedBorrow > 0) _updateBorrowOf(market, user, userScore, totalScore);

        amount = amount.add(userInfo.accruedQubit);
        userInfo.accruedQubit = 0;

        return amount;
    }

    function _calculateMarketDistributionAPY(address market) private view returns (uint apySupplyQBT, uint apyBorrowQBT) {
        // base supply QBT APY == average supply QBT APY * (Total balance / total Boosted balance)
        // base supply QBT APY == (qubitRate * 365 days * price Of Qubit) / (Total balance * exchangeRate * price of asset) * (Total balance / Total Boosted balance)
        // base supply QBT APY == (qubitRate * 365 days * price Of Qubit) / (Total boosted balance * exchangeRate * price of asset)
        uint numerSupply = distributions[market].supplySpeed.mul(365 days).mul(priceCalculator.priceOf(QBT));
        uint denomSupply = distributions[market].totalBoostedSupply.mul(IQToken(market).exchangeRate()).mul(priceCalculator.getUnderlyingPrice(market)).div(1e36);
        apySupplyQBT = denomSupply > 0 ? numerSupply.div(denomSupply) : 0;

        // base borrow QBT APY == average borrow QBT APY * (Total balance / total Boosted balance)
        // base borrow QBT APY == (qubitRate * 365 days * price Of Qubit) / (Total balance * exchangeRate * price of asset) * (Total balance / Total Boosted balance)
        // base borrow QBT APY == (qubitRate * 365 days * price Of Qubit) / (Total boosted balance * exchangeRate * price of asset)
        uint numerBorrow = distributions[market].borrowSpeed.mul(365 days).mul(priceCalculator.priceOf(QBT));
        uint denomBorrow = distributions[market].totalBoostedBorrow.mul(IQToken(market).getAccInterestIndex()).mul(priceCalculator.getUnderlyingPrice(market)).div(1e36);
        apyBorrowQBT = denomBorrow > 0 ? numerBorrow.div(denomBorrow) : 0;
    }

    function _calculateAccountDistributionAPY(address market, address account) private view returns (uint apyAccountSupplyQBT, uint apyAccountBorrowQBT) {
        if (account == address(0)) return (0, 0);
        (uint apySupplyQBT, uint apyBorrowQBT) = _calculateMarketDistributionAPY(market);

        // user supply QBT APY == ((qubitRate * 365 days * price Of Qubit) / (Total boosted balance * exchangeRate * price of asset) ) * my boosted balance  / my balance
        uint accountSupply = IQToken(market).balanceOf(account);
        apyAccountSupplyQBT = accountSupply > 0 ? apySupplyQBT.mul(accountDistributions[market][account].boostedSupply).div(accountSupply) : 0;

        // user borrow QBT APY == (qubitRate * 365 days * price Of Qubit) / (Total boosted balance * interestIndex * price of asset) * my boosted balance  / my balance
        uint accountBorrow = IQToken(market).borrowBalanceOf(account).mul(1e18).div(IQToken(market).getAccInterestIndex());
        apyAccountBorrowQBT = accountBorrow > 0 ? apyBorrowQBT.mul(accountDistributions[market][account].boostedBorrow).div(accountBorrow) : 0;
    }

    function _calculateBoostedSupply(address market, address user) private view returns (uint) {
        uint defaultSupply = IQToken(market).balanceOf(user);
        uint boostedSupply = defaultSupply;

        uint userScore = qubitLocker.scoreOf(user);
        (uint totalScore, ) = qubitLocker.totalScore();
        if (userScore > 0 && totalScore > 0) {
            uint scoreBoosted = IQToken(market).totalSupply().mul(userScore).div(totalScore).mul(BOOST_PORTION).div(
                100
            );
            boostedSupply = boostedSupply.add(scoreBoosted);
        }
        return Math.min(boostedSupply, defaultSupply.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedBorrow(address market, address user) private view returns (uint) {
        uint accInterestIndex = IQToken(market).getAccInterestIndex();
        uint defaultBorrow = IQToken(market).borrowBalanceOf(user).mul(1e18).div(accInterestIndex);
        uint boostedBorrow = defaultBorrow;

        uint userScore = qubitLocker.scoreOf(user);
        (uint totalScore, ) = qubitLocker.totalScore();
        if (userScore > 0 && totalScore > 0) {
            uint totalBorrow = IQToken(market).totalBorrow().mul(1e18).div(accInterestIndex);
            uint scoreBoosted = totalBorrow.mul(userScore).div(totalScore).mul(BOOST_PORTION).div(100);
            boostedBorrow = boostedBorrow.add(scoreBoosted);
        }
        return Math.min(boostedBorrow, defaultBorrow.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedSupply(address market, address user, uint userScore, uint totalScore) private view returns (uint) {
        uint defaultSupply = IQToken(market).balanceOf(user);
        uint boostedSupply = defaultSupply;

        if (userScore > 0 && totalScore > 0) {
            uint scoreBoosted = IQToken(market).totalSupply().mul(userScore).div(totalScore).mul(BOOST_PORTION).div(
                100
            );
            boostedSupply = boostedSupply.add(scoreBoosted);
        }
        return Math.min(boostedSupply, defaultSupply.mul(BOOST_MAX).div(100));
    }

    function _calculateBoostedBorrow(address market, address user, uint userScore, uint totalScore) private view returns (uint) {
        uint accInterestIndex = IQToken(market).getAccInterestIndex();
        uint defaultBorrow = IQToken(market).borrowBalanceOf(user).mul(1e18).div(accInterestIndex);
        uint boostedBorrow = defaultBorrow;

        if (userScore > 0 && totalScore > 0) {
            uint totalBorrow = IQToken(market).totalBorrow().mul(1e18).div(accInterestIndex);
            uint scoreBoosted = totalBorrow.mul(userScore).div(totalScore).mul(BOOST_PORTION).div(100);
            boostedBorrow = boostedBorrow.add(scoreBoosted);
        }
        return Math.min(boostedBorrow, defaultBorrow.mul(BOOST_MAX).div(100));
    }

    function _updateSupplyOf(address market, address user, uint userScore, uint totalScore) private updateDistributionOf(market) {
        QConstant.DistributionInfo storage dist = distributions[market];
        QConstant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedSupply > 0) {
            uint accQubitPerShare = dist.accPerShareSupply.sub(userInfo.accPerShareSupply);
            userInfo.accruedQubit = userInfo.accruedQubit.add(accQubitPerShare.mul(userInfo.boostedSupply).div(1e18));
        }
        userInfo.accPerShareSupply = dist.accPerShareSupply;

        uint boostedSupply = _calculateBoostedSupply(market, user, userScore, totalScore);
        dist.totalBoostedSupply = dist.totalBoostedSupply.add(boostedSupply).sub(userInfo.boostedSupply);
        userInfo.boostedSupply = boostedSupply;
    }

    function _updateBorrowOf(address market, address user, uint userScore, uint totalScore) private updateDistributionOf(market) {
        QConstant.DistributionInfo storage dist = distributions[market];
        QConstant.DistributionAccountInfo storage userInfo = accountDistributions[market][user];

        if (userInfo.boostedBorrow > 0) {
            uint accQubitPerShare = dist.accPerShareBorrow.sub(userInfo.accPerShareBorrow);
            userInfo.accruedQubit = userInfo.accruedQubit.add(accQubitPerShare.mul(userInfo.boostedBorrow).div(1e18));
        }
        userInfo.accPerShareBorrow = dist.accPerShareBorrow;

        uint boostedBorrow = _calculateBoostedBorrow(market, user, userScore, totalScore);
        dist.totalBoostedBorrow = dist.totalBoostedBorrow.add(boostedBorrow).sub(userInfo.boostedBorrow);
        userInfo.boostedBorrow = boostedBorrow;
    }
}
