// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DailyLimitGuard
/// @notice Gas-efficient per-asset daily spend guard keyed by UTC day buckets.
/// @dev Uses `block.timestamp / 1 days` instead of storing reset timestamps. Small validator
///      timestamp drift can only affect transactions close to midnight UTC; it cannot underflow
///      or skip accounting because a new bucket overwrites, rather than subtracts from, spent state.
abstract contract DailyLimitGuard {
    error DailyLimitGuard__DailyLimitExceeded(address asset, uint256 limit, uint256 attempted);
    error DailyLimitGuard__AmountTooLarge();

    event DailyLimitUpdated(address indexed asset, uint256 limit);
    event DailyLimitConsumed(address indexed asset, uint256 indexed day, uint256 amount, uint256 totalSpent);

    struct DailySpend {
        uint64 day;
        uint192 spent;
    }

    mapping(address asset => uint256 limit) public dailyLimit;
    mapping(address asset => DailySpend spend) public dailySpend;

    function _setDailyLimit(address asset, uint256 limit) internal {
        dailyLimit[asset] = limit;
        emit DailyLimitUpdated(asset, limit);
    }

    /// @notice Enforces and accounts for the current UTC day bucket.
    /// @dev A zero limit means the asset is uncapped. This keeps legacy rescue behavior unchanged
    ///      until the owner explicitly configures a non-zero limit.
    function _enforceDailyLimit(address asset, uint256 amount) internal virtual {
        uint256 limit = dailyLimit[asset];
        if (limit == 0) return;
        if (amount > type(uint192).max) revert DailyLimitGuard__AmountTooLarge();

        uint64 currentDay = uint64(block.timestamp / 1 days);
        DailySpend memory spend = dailySpend[asset];

        uint256 totalSpent = amount;
        if (spend.day == currentDay) {
            totalSpent += spend.spent;
        }

        if (totalSpent > limit) revert DailyLimitGuard__DailyLimitExceeded(asset, limit, totalSpent);

        dailySpend[asset] = DailySpend({day: currentDay, spent: uint192(totalSpent)});
        emit DailyLimitConsumed(asset, currentDay, amount, totalSpent);
    }
}
