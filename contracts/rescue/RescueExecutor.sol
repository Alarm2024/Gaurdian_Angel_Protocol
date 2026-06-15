// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RescueExecutor
/// @notice Shared rescue helpers for recovering native ETH, ERC20, ERC721, and ERC1155 assets.
/// @dev Keeping this logic in an abstract contract lets GuardianAngel inherit the external rescue
///      entry points while moving the implementation out of the core contract file.
abstract contract RescueExecutor {
    error RescueExecutor__ZeroAddress();
    error RescueExecutor__EthTransferFailed();
    error RescueExecutor__PermitFailed();
    error RescueExecutor__ERC20TransferFailed();
    error RescueExecutor__ERC721TransferFailed();
    error RescueExecutor__ERC1155TransferFailed();

    event NativeTokenRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed from, address indexed to, uint256 amount);
    event ERC20PermitRescueApproved(address indexed token, address indexed owner, uint256 amount, uint256 deadline);
    event ERC721Rescued(address indexed token, address indexed to, uint256 indexed tokenId);
    event ERC1155Rescued(address indexed token, address indexed to, uint256 indexed tokenId, uint256 amount);

    /// @dev Hook implemented by the parent contract, usually with Ownable/AccessControl checks.
    function _authorizeRescue(address to) internal virtual;

    function rescueNative(address payable to, uint256 amount) external {
        _authorizeRescue(to);
        if (to == address(0)) revert RescueExecutor__ZeroAddress();

        _enforceDailyLimit(address(0), amount);

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert RescueExecutor__EthTransferFailed();

        emit NativeTokenRescued(to, amount);
    }

    /// @notice Rescues ERC20 tokens already held by this contract.
    function emergencyRescueERC20(address token, address to, uint256 amount) public {
        _authorizeRescue(to);
        if (token == address(0) || to == address(0)) revert RescueExecutor__ZeroAddress();

        _enforceDailyLimit(token, amount);
        _safeERC20Transfer(token, to, amount);
        emit ERC20Rescued(token, address(this), to, amount);
    }

    /// @notice Backward-compatible alias for integrations that call the shorter rescue name.
    function rescueERC20(address token, address to, uint256 amount) external {
        emergencyRescueERC20(token, to, amount);
    }

    /// @notice Uses an EIP-2612 permit signature before rescuing ERC20 tokens from `owner`.
    /// @dev This supports gasless approvals: `owner` signs the permit off-chain, then an authorized
    ///      rescuer submits the signature and moves the approved amount in one transaction.
    function emergencyRescueERC20WithPermit(
        address token,
        address owner,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _authorizeRescue(to);
        if (token == address(0) || owner == address(0) || to == address(0)) {
            revert RescueExecutor__ZeroAddress();
        }

        _enforceDailyLimit(token, amount);
        _permitERC20(token, owner, amount, deadline, v, r, s);
        emit ERC20PermitRescueApproved(token, owner, amount, deadline);

        _safeERC20TransferFrom(token, owner, to, amount);
        emit ERC20Rescued(token, owner, to, amount);
    }

    function rescueERC721(address token, address to, uint256 tokenId) external {
        _authorizeRescue(to);
        if (token == address(0) || to == address(0)) revert RescueExecutor__ZeroAddress();

        (bool success, ) = token.call(
            abi.encodeWithSelector(IERC721Minimal.safeTransferFrom.selector, address(this), to, tokenId)
        );
        if (!success) revert RescueExecutor__ERC721TransferFailed();

        emit ERC721Rescued(token, to, tokenId);
    }

    function rescueERC1155(address token, address to, uint256 tokenId, uint256 amount, bytes calldata data) external {
        _authorizeRescue(to);
        if (token == address(0) || to == address(0)) revert RescueExecutor__ZeroAddress();

        (bool success, ) = token.call(
            abi.encodeWithSelector(IERC1155Minimal.safeTransferFrom.selector, address(this), to, tokenId, amount, data)
        );
        if (!success) revert RescueExecutor__ERC1155TransferFailed();

        emit ERC1155Rescued(token, to, tokenId, amount);
    }

    /// @dev Optional hook for contracts that enforce per-asset rescue limits.
    function _enforceDailyLimit(address asset, uint256 amount) internal virtual {}

    function _permitERC20(
        address token,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) private {
        (bool success, ) = token.call(
            abi.encodeWithSelector(IERC20PermitMinimal.permit.selector, owner, address(this), amount, deadline, v, r, s)
        );
        if (!success) revert RescueExecutor__PermitFailed();
    }

    function _safeERC20Transfer(address token, address to, uint256 amount) private {
        (bool success, bytes memory returnData) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert RescueExecutor__ERC20TransferFailed();
        }
    }

    function _safeERC20TransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory returnData) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount)
        );
        if (!success || (returnData.length != 0 && !abi.decode(returnData, (bool)))) {
            revert RescueExecutor__ERC20TransferFailed();
        }
    }
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
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
}
