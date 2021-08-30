// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "../library/QConstant.sol";

interface IDashboard {
    struct QubitData {
        MarketData[] marketList;
        MembershipData[] membershipList;
        AccountAccData accountAcc;
        LockerData locker;
        uint marketAverageBoostedRatio;
    }

    struct MarketData {
        address qToken;

        uint apySupply;
        uint apyBorrow;
        uint apySupplyQBT;
        uint apyBorrowQBT;

        uint totalSupply;
        uint totalBorrows;
        uint totalBoostedSupply;
        uint totalBoostedBorrow;

        uint cash;
        uint reserve;
        uint reserveFactor;
        uint collateralFactor;
        uint exchangeRate;
        uint borrowCap;
        uint accInterestIndex;
    }

    struct MembershipData {
        address qToken;
        bool membership;
        uint supply;
        uint borrow;
        uint boostedSupply;
        uint boostedBorrow;
        uint apyAccountSupplyQBT;
        uint apyAccountBorrowQBT;
    }

    struct AccountAccData {
        uint accruedQubit;
        uint collateralInUSD;
        uint supplyInUSD;
        uint borrowInUSD;
        uint accApySupply;
        uint accApyBorrow;
        uint accApySupplyQBT;
        uint accApyBorrowQBT;
        uint averageBoostedRatio;
    }

    struct LockerData {
        uint totalLocked;
        uint locked;
        uint totalScore;
        uint score;
        uint available;
        uint expiry;
    }

    function qubitDataOf(address[] memory markets, address account) external view returns (QubitData memory);

    function marketDataOf(address market) external view returns (MarketData memory);
    function membershipDataOf(address market, address account) external view returns (MembershipData memory);
    function accountAccDataOf(address account) external view returns (AccountAccData memory);
    function lockerDataOf(address account) external view returns (LockerData memory);
}
