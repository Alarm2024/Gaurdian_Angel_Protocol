// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DailyLimitGuard} from "../contracts/limits/DailyLimitGuard.sol";

interface Vm {
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 selector) external;
    function warp(uint256 newTimestamp) external;
}

contract DailyLimitGuardHarness is DailyLimitGuard {
    function setDailyLimit(address asset, uint256 limit) external {
        _setDailyLimit(asset, limit);
    }

    function enforceDailyLimit(address asset, uint256 amount) external {
        _enforceDailyLimit(asset, amount);
    }
}

contract DailyLimitGuardTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    DailyLimitGuardHarness internal guard;
    address internal constant ETH_ASSET = address(0);
    address internal constant TOKEN_ASSET = address(0xBEEF);

    function setUp() public {
        guard = new DailyLimitGuardHarness();
    }

    function testAccumulatesWithinSameDayAndRevertsOverLimit() public {
        guard.setDailyLimit(TOKEN_ASSET, 100 ether);

        guard.enforceDailyLimit(TOKEN_ASSET, 40 ether);
        guard.enforceDailyLimit(TOKEN_ASSET, 60 ether);

        (uint64 day, uint192 spent) = guard.dailySpend(TOKEN_ASSET);
        assertEq(day, 0);
        assertEq(spent, 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DailyLimitGuard.DailyLimitGuard__DailyLimitExceeded.selector,
                TOKEN_ASSET,
                100 ether,
                101 ether
            )
        );
        guard.enforceDailyLimit(TOKEN_ASSET, 1 ether);
    }

    function testDoesNotResetOneSecondBeforeBoundary() public {
        guard.setDailyLimit(TOKEN_ASSET, 100 ether);

        vm.warp(1 days - 1);
        guard.enforceDailyLimit(TOKEN_ASSET, 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DailyLimitGuard.DailyLimitGuard__DailyLimitExceeded.selector,
                TOKEN_ASSET,
                100 ether,
                101 ether
            )
        );
        guard.enforceDailyLimit(TOKEN_ASSET, 1 ether);
    }

    function testResetsAtExactNextDayBoundary() public {
        guard.setDailyLimit(TOKEN_ASSET, 100 ether);

        vm.warp(1 days - 1);
        guard.enforceDailyLimit(TOKEN_ASSET, 100 ether);

        vm.warp(1 days);
        guard.enforceDailyLimit(TOKEN_ASSET, 25 ether);

        (uint64 day, uint192 spent) = guard.dailySpend(TOKEN_ASSET);
        assertEq(day, 1);
        assertEq(spent, 25 ether);
    }

    function testIndependentAssetBuckets() public {
        guard.setDailyLimit(ETH_ASSET, 10 ether);
        guard.setDailyLimit(TOKEN_ASSET, 20 ether);

        guard.enforceDailyLimit(ETH_ASSET, 10 ether);
        guard.enforceDailyLimit(TOKEN_ASSET, 20 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DailyLimitGuard.DailyLimitGuard__DailyLimitExceeded.selector,
                ETH_ASSET,
                10 ether,
                11 ether
            )
        );
        guard.enforceDailyLimit(ETH_ASSET, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                DailyLimitGuard.DailyLimitGuard__DailyLimitExceeded.selector,
                TOKEN_ASSET,
                20 ether,
                21 ether
            )
        );
        guard.enforceDailyLimit(TOKEN_ASSET, 1 ether);
    }

    function testZeroLimitIsUncappedAndDoesNotWriteSpend() public {
        guard.enforceDailyLimit(TOKEN_ASSET, type(uint256).max);

        (uint64 day, uint192 spent) = guard.dailySpend(TOKEN_ASSET);
        assertEq(day, 0);
        assertEq(spent, 0);
    }

    function testRejectsAmountThatCannotBePacked() public {
        guard.setDailyLimit(TOKEN_ASSET, type(uint256).max);

        vm.expectRevert(DailyLimitGuard.DailyLimitGuard__AmountTooLarge.selector);
        guard.enforceDailyLimit(TOKEN_ASSET, uint256(type(uint192).max) + 1);
    }

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "assertEq(uint256) failed");
    }
}
