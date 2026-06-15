// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC20PermitMinimal {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IERC721Minimal {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Minimal {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external;
}

/**
 * @title GuardianAngel v2.1.1
 * @notice Sentinel-X Enhanced with Chainlink Automation support.
 * @dev Includes ownership management, guardian rotation, timelocked emergency withdrawals,
 *      multi-asset rescue, rate-limited ETH withdrawal, and autonomous safety pause.
 */
contract GuardianAngel {
    string public constant VERSION = "2.1.1";

    error Unauthorized();
    error NotGuardian();
    error NotOwner();
    error ContractPaused();
    error ZeroAddress();
    error InsufficientFunds();
    error TransferFailed();
    error PermitFailed();
    error NotPendingOwner();
    error TimeLockActive();
    error NothingToClaim();
    error InvalidToken();
    error ArrayLengthMismatch();
    error DailyLimitExceeded();
    error WithdrawalPending();
    error NoRotationPending();
    error InvalidLimit();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianRotationInitiated(address indexed current, address indexed pending, uint256 unlockTime);
    event GuardianRotated(address indexed previous, address indexed newGuardian);
    event GuardianRotationCancelled(address indexed cancelledBy);
    event RecoveryAddressUpdated(address indexed newRecovery);
    event Paused(address indexed triggeredBy);
    event Unpaused(address indexed triggeredBy);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ERC20PermitRescued(address indexed token, address indexed from, address indexed to, uint256 amount);
    event ERC721Rescued(address indexed token, address indexed to, uint256 tokenId);
    event ERC1155Rescued(address indexed token, address indexed to, uint256 id, uint256 amount);
    event ERC1155BatchRescued(address indexed token, address indexed to, uint256[] ids, uint256[] amounts);
    event WithdrawalInitiated(uint256 amount, uint256 unlockTime);
    event WithdrawalCancelled(uint256 amount);
    event ETHReceived(address indexed from, uint256 amount);
    event DailyLimitUpdated(uint256 newLimit);
    event DailyLimitConsumed(uint256 indexed day, uint256 amount, uint256 totalWithdrawn);

    address public owner;
    address public pendingOwner;
    address public guardian;
    address public recoveryAddress;
    bool public paused;

    uint256 public constant TIMELOCK_DELAY = 12 hours;
    uint256 public pendingWithdrawalAmount;
    uint256 public unlockTime;

    uint256 public constant GUARDIAN_ROTATION_DELAY = 24 hours;
    address public pendingGuardian;
    uint256 public guardianUnlockTime;

    uint256 public dailyLimit;
    uint256 public dailyWithdrawn;
    uint256 public lastWithdrawDay;

    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier noWithdrawalPending() {
        if (pendingWithdrawalAmount > 0) revert WithdrawalPending();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert Unauthorized();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    constructor(address initialGuardian, address initialRecoveryAddress, uint256 initialDailyLimit) {
        if (initialGuardian == address(0) || initialRecoveryAddress == address(0)) revert ZeroAddress();
        if (initialDailyLimit == 0) revert InvalidLimit();

        owner = msg.sender;
        guardian = initialGuardian;
        recoveryAddress = initialRecoveryAddress;
        dailyLimit = initialDailyLimit;
        _reentrancyStatus = _NOT_ENTERED;

        emit OwnershipTransferred(address(0), msg.sender);
        emit RecoveryAddressUpdated(initialRecoveryAddress);
        emit DailyLimitUpdated(initialDailyLimit);
    }

    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = !paused && _exceedsSafetyThreshold();
        performData = "";
    }

    function performUpkeep(bytes calldata) external {
        if (paused || !_exceedsSafetyThreshold()) return;
        paused = true;
        emit Paused(address(this));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address oldOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function setRecoveryAddress(address newRecovery) external onlyOwner noWithdrawalPending {
        if (newRecovery == address(0)) revert ZeroAddress();
        recoveryAddress = newRecovery;
        emit RecoveryAddressUpdated(newRecovery);
    }

    function initiateGuardianRotation(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        pendingGuardian = newGuardian;
        guardianUnlockTime = block.timestamp + GUARDIAN_ROTATION_DELAY;
        emit GuardianRotationInitiated(guardian, newGuardian, guardianUnlockTime);
    }

    function executeGuardianRotation() external onlyOwner {
        if (pendingGuardian == address(0)) revert NoRotationPending();
        if (block.timestamp < guardianUnlockTime) revert TimeLockActive();

        address oldGuardian = guardian;
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianUnlockTime = 0;
        emit GuardianRotated(oldGuardian, guardian);
    }

    function cancelGuardianRotation() external onlyOwnerOrGuardian {
        if (pendingGuardian == address(0)) revert NoRotationPending();
        pendingGuardian = address(0);
        guardianUnlockTime = 0;
        emit GuardianRotationCancelled(msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwnerOrGuardian {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function initiateEmergencyWithdrawal(uint256 amount) external onlyGuardian {
        if (amount == 0) revert NothingToClaim();
        if (address(this).balance < amount) revert InsufficientFunds();
        pendingWithdrawalAmount = amount;
        unlockTime = block.timestamp + TIMELOCK_DELAY;
        emit WithdrawalInitiated(amount, unlockTime);
    }

    function executeEmergencyWithdrawal() external onlyGuardian nonReentrant {
        uint256 amount = pendingWithdrawalAmount;
        if (amount == 0) revert NothingToClaim();
        if (block.timestamp < unlockTime) revert TimeLockActive();

        uint256 balance = address(this).balance;
        if (balance < amount) amount = balance;
        if (amount == 0) revert InsufficientFunds();

        pendingWithdrawalAmount = 0;
        unlockTime = 0;
        _sendETH(payable(recoveryAddress), amount);
        emit EmergencyWithdrawal(recoveryAddress, amount);
    }

    function cancelWithdrawal() external onlyGuardian {
        emit WithdrawalCancelled(pendingWithdrawalAmount);
        pendingWithdrawalAmount = 0;
        unlockTime = 0;
    }

    function withdraw(uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        if (amount == 0) revert NothingToClaim();
        if (address(this).balance < amount) revert InsufficientFunds();

        _enforceDailyLimit(amount);
        _sendETH(payable(owner), amount);
    }

    function setDailyLimit(uint256 newLimit) external onlyOwner {
        if (newLimit == 0) revert InvalidLimit();
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }

    function emergencyRescueERC20(address token, uint256 amount) external onlyGuardian nonReentrant {
        _safeTransfer(token, recoveryAddress, amount);
        emit ERC20Rescued(token, recoveryAddress, amount);
    }

    function emergencyRescueERC20WithPermit(
        address token,
        address tokenOwner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyGuardian nonReentrant {
        _permit(token, tokenOwner, amount, deadline, v, r, s);
        _safeTransferFrom(token, tokenOwner, recoveryAddress, amount);
        emit ERC20PermitRescued(token, tokenOwner, recoveryAddress, amount);
    }

    function batchRescueERC20(address[] calldata tokens, uint256[] calldata amounts) external onlyGuardian nonReentrant {
        uint256 length = tokens.length;
        if (length != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i; i < length; ) {
            _safeTransfer(tokens[i], recoveryAddress, amounts[i]);
            emit ERC20Rescued(tokens[i], recoveryAddress, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function sweepERC20(address token, address to, uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _safeTransfer(token, to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueERC721(address token, uint256 tokenId) external onlyGuardian nonReentrant {
        _validateContract(token);
        IERC721Minimal(token).safeTransferFrom(address(this), recoveryAddress, tokenId);
        emit ERC721Rescued(token, recoveryAddress, tokenId);
    }

    function rescueERC1155(address token, uint256 id, uint256 amount) external onlyGuardian nonReentrant {
        _validateContract(token);
        IERC1155Minimal(token).safeTransferFrom(address(this), recoveryAddress, id, amount, "");
        emit ERC1155Rescued(token, recoveryAddress, id, amount);
    }

    function batchRescueERC1155(
        address token,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external onlyGuardian nonReentrant {
        _validateContract(token);
        if (ids.length != amounts.length) revert ArrayLengthMismatch();
        IERC1155Minimal(token).safeBatchTransferFrom(address(this), recoveryAddress, ids, amounts, "");
        emit ERC1155BatchRescued(token, recoveryAddress, ids, amounts);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x150b7a02 || interfaceId == 0x4e2312e0;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function _exceedsSafetyThreshold() private view returns (bool) {
        if (dailyLimit > type(uint256).max / 10) return false;
        return address(this).balance > dailyLimit * 10;
    }

    function _sendETH(address payable to, uint256 amount) private {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        _validateContract(token);
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        _validateContract(token);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _permit(
        address token,
        address tokenOwner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        if (tokenOwner == address(0)) revert ZeroAddress();
        _validateContract(token);
        (bool success, ) = token.call(
            abi.encodeCall(IERC20PermitMinimal.permit, (tokenOwner, address(this), amount, deadline, v, r, s))
        );
        if (!success) revert PermitFailed();
    }

    function _validateContract(address token) private view {
        if (token.code.length == 0) revert InvalidToken();
    }

    function _enforceDailyLimit(uint256 amount) private {
        uint256 currentDay = block.timestamp / 1 days;

        if (currentDay > lastWithdrawDay) {
            if (amount > dailyLimit) revert DailyLimitExceeded();
            lastWithdrawDay = currentDay;
            dailyWithdrawn = amount;
            emit DailyLimitConsumed(currentDay, amount, amount);
            return;
        }

        uint256 totalWithdrawn = dailyWithdrawn + amount;
        if (totalWithdrawn > dailyLimit) revert DailyLimitExceeded();

        dailyWithdrawn = totalWithdrawn;
        emit DailyLimitConsumed(currentDay, amount, totalWithdrawn);
    }

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) emit ETHReceived(msg.sender, msg.value);
    }
}
