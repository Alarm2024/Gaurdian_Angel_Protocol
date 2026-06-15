// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {GuardianAngel} from "../contracts/GuardianAngel.sol";

interface GuardianAngelVm {
    function deal(address account, uint256 newBalance) external;
    function expectRevert(bytes4 selector) external;
    function warp(uint256 newTimestamp) external;
}

contract GuardianAngelDailyLimitTest {
    GuardianAngelVm internal constant vm = GuardianAngelVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    GuardianAngel internal guardianAngel;
    address internal constant GUARDIAN = address(0xA11CE);
    address internal constant RECOVERY = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        guardianAngel = new GuardianAngel(GUARDIAN, RECOVERY, 10 ether);
        vm.deal(address(guardianAngel), 100 ether);
    }

    function testWithdrawAccumulatesWithinSameDayAndRevertsOverLimit() public {
        vm.warp(10 days);

        guardianAngel.withdraw(4 ether);
        guardianAngel.withdraw(6 ether);

        assertEq(guardianAngel.lastWithdrawDay(), 10);
        assertEq(guardianAngel.dailyWithdrawn(), 10 ether);

        vm.expectRevert(GuardianAngel.DailyLimitExceeded.selector);
        guardianAngel.withdraw(1 wei);
    }

    function testWithdrawDoesNotResetOneSecondBeforeNextDay() public {
        vm.warp(10 days);
        guardianAngel.withdraw(10 ether);

        vm.warp(11 days - 1);
        vm.expectRevert(GuardianAngel.DailyLimitExceeded.selector);
        guardianAngel.withdraw(1 wei);
    }

    function testWithdrawResetsAtExactNextDayBoundary() public {
        vm.warp(10 days);
        guardianAngel.withdraw(10 ether);

        vm.warp(11 days);
        guardianAngel.withdraw(3 ether);

        assertEq(guardianAngel.lastWithdrawDay(), 11);
        assertEq(guardianAngel.dailyWithdrawn(), 3 ether);
    }

    function testNewDayWithdrawalCannotExceedDailyLimit() public {
        vm.warp(10 days);

        vm.expectRevert(GuardianAngel.DailyLimitExceeded.selector);
        guardianAngel.withdraw(10 ether + 1 wei);

        assertEq(guardianAngel.lastWithdrawDay(), 0);
        assertEq(guardianAngel.dailyWithdrawn(), 0);
    }

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "assertEq(uint256) failed");
    }
}
