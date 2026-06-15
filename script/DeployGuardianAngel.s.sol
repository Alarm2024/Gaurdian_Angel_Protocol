// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {GuardianAngel} from "../contracts/GuardianAngel.sol";

interface Vm {
    function envAddress(string calldata name) external returns (address value);
    function envUint(string calldata name) external returns (uint256 value);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract DeployGuardianAngel {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (GuardianAngel guardianAngel) {
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        address recoveryAddress = vm.envAddress("RECOVERY_ADDRESS");
        uint256 dailyLimit = vm.envUint("DAILY_LIMIT_WEI");

        vm.startBroadcast();
        guardianAngel = new GuardianAngel(guardian, recoveryAddress, dailyLimit);
        vm.stopBroadcast();
    }
}
