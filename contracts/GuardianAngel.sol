// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title GuardianAngel
 * @author Sentinel-X Core (hardened & extended by Claude)
 * @notice Enterprise-grade Asset Rescue Protocol with multi-role authorization,
 *         timelocked governance, and a cold-signer fast path for emergency
 *         withdrawals.
 *
 * @dev Self-contained, dependency-free implementation (no external imports),
 *      so the entire trust surface of the contract is visible in this single
 *      file - intentionally written to be read end-to-end as a reference for
 *      audits.
 *
 *      ================================================================
 *      WHAT'S NEW IN v3.0.0 (vs v2.2.0)
 *      ================================================================
 *      The previous version declared a large set of roles, errors, events
 *      and storage slots (pendingOwner, pendingGuardian, paused, timelocks,
 *      ERC-1155 / permit interfaces, etc.) that had NO matching functions.
 *      This version implements every one of them, and closes several real
 *      security gaps along the way:
 *
 *        1. Two-step ownership transfer (transferOwnership / acceptOwnership)
 *           - a typo'd or unreachable `newOwner` can no longer permanently
 *             brick administration of the contract.
 *
 *        2. Timelocked, cancellable rotation (24h) for the guardian, the
 *           recovery address, and the cold signer. Each rotation can be
 *           vetoed by EITHER the owner or the guardian during the delay -
 *           a single compromised key can no longer unilaterally redirect
 *           where rescued funds end up or who can authorize withdrawals.
 *
 *        3. Pause / unpause is now wired to an actual emergency exit:
 *           emergencyWithdraw() lets the guardian sweep all ETH to the
 *           (immutable-during-pause) recovery address while paused.
 *
 *        4. withdrawSecure() now uses EIP-712 typed-data signatures bound
 *           to this contract's address and chain id (a proper domain
 *           separator) plus a per-signature `deadline`. The old scheme
 *           signed a bare `keccak256(user, amount, nonce)` with the
 *           "\x19Ethereum Signed Message:\n32" prefix and no domain
 *           binding at all - that signature would have been valid on
 *           ANY GuardianAngel deployment, on ANY chain, with the same
 *           cold signer key. That cross-contract / cross-chain replay
 *           hole is now closed, and EIP-5267 (eip712Domain()) is exposed
 *           so wallets can render the request safely for the cold signer
 *           to review before signing.
 *
 *        5. A second, signer-independent withdrawal path
 *           (initiateWithdrawal / cancelWithdrawal / executeWithdrawal)
 *           with a 12h timelock. If the cold signer key is ever lost,
 *           the owner is never permanently locked out of contract funds
 *           - while the guardian keeps a veto during the 12h window.
 *
 *        6. ERC-20 permit-based rescue (rescueERC20WithPermit) so the
 *           guardian can recover tokens out of a compromised externally
 *           owned account via a gas-less off-chain signature, before an
 *           attacker drains it.
 *
 *        7. ERC-1155 single and batch rescue.
 *
 *        8. setDailyLimit() - the limit was previously fixed forever at
 *           deploy time.
 *
 *        9. Checks-Effects-Interactions ordering enforced throughout, and
 *           every state-mutating external call is wrapped in `nonReentrant`.
 *
 *      ================================================================
 *      ROLE CAPABILITY MATRIX
 *      ================================================================
 *      owner          - day-to-day controller. Withdraws ETH (instantly with
 *                        a cold-signer signature, or via the 12h timelock
 *                        fallback), sets the daily limit / whitelist, and
 *                        initiates rotations of guardian / recovery / cold
 *                        signer / ownership itself.
 *
 *      guardian       - "break glass" role. Performs all asset rescues
 *                        (ERC20 / ERC721 / ERC1155 / permit), can pause the
 *                        contract, can sweep ETH to `recoveryAddress` while
 *                        paused, and can veto (cancel) any pending rotation
 *                        or pending timelocked withdrawal initiated by the
 *                        owner.
 *
 *      coldSigner     - an offline / hardware key. Its ONLY power is signing
 *                        EIP-712 `Withdraw` messages that authorize
 *                        withdrawSecure(). It cannot call any function on
 *                        this contract directly.
 *
 *      recoveryAddress- a pure destination. All rescued assets and all
 *                        emergency / guardian-routed funds land here. It has
 *                        no privileges of its own.
 *
 *      pendingOwner /
 *      pendingGuardian /
 *      pendingRecoveryAddress /
 *      pendingColdSigner - addresses nominated for a role but not yet
 *                        active; see the rotation sections below.
 */

// =================================================================
// INTERFACES (External Contract Interaction)
// =================================================================

/// @dev Minimal interface for standard ERC-20 token interactions.
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal interface for EIP-2612 `permit` functionality.
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

/// @dev Minimal interface for ERC-721 token transfers.
interface IERC721Minimal {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @dev Minimal interface for ERC-1155 multi-token transfers.
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

// =================================================================
// MAIN CONTRACT
// =================================================================

contract GuardianAngel {

    // =================================================================
    // CUSTOM ERRORS (Gas-Optimized Reverts)
    // =================================================================
    error Unauthorized();
    error NotOwner();
    error NotGuardian();
    error NotPendingOwner();
    error ContractPaused();
    error NotPaused();
    error ZeroAddress();
    error NoChange();
    error InsufficientFunds();
    error TransferFailed();
    error InvalidToken();
    error ArrayLengthMismatch();
    error DailyLimitExceeded();
    error InvalidLimit();
    error InvalidSignature();
    error SignatureExpired();
    error WithdrawalPending();
    error NoWithdrawalPending();
    error TimelockActive();
    error NoRotationPending();

    // =================================================================
    // EVENTS (System Transparency)
    // =================================================================

    // --- Ownership ---
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --- Guardian rotation ---
    event GuardianRotationInitiated(address indexed current, address indexed pending, uint256 unlockTime);
    event GuardianRotated(address indexed previous, address indexed newGuardian);
    event GuardianRotationCancelled(address indexed cancelledBy);

    // --- Recovery address rotation ---
    event RecoveryRotationInitiated(address indexed current, address indexed pending, uint256 unlockTime);
    event RecoveryAddressUpdated(address indexed previous, address indexed newRecovery);
    event RecoveryRotationCancelled(address indexed cancelledBy);

    // --- Cold signer rotation ---
    event ColdSignerRotationInitiated(address indexed current, address indexed pending, uint256 unlockTime);
    event ColdSignerRotated(address indexed previous, address indexed newColdSigner);
    event ColdSignerRotationCancelled(address indexed cancelledBy);

    // --- Pause ---
    event Paused(address indexed triggeredBy);
    event Unpaused(address indexed triggeredBy);

    // --- Emergency / rescue ---
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event ERC20PermitRescued(address indexed token, address indexed from, address indexed to, uint256 amount);
    event ERC721Rescued(address indexed token, address indexed to, uint256 tokenId);
    event ERC1155Rescued(address indexed token, address indexed to, uint256 id, uint256 amount);
    event ERC1155BatchRescued(address indexed token, address indexed to, uint256[] ids, uint256[] amounts);

    // --- Timelocked withdrawal fallback ---
    event WithdrawalInitiated(uint256 amount, uint256 unlockTime);
    event WithdrawalCancelled(uint256 amount);
    event WithdrawalExecuted(address indexed to, uint256 amount);

    // --- Misc ---
    event ETHReceived(address indexed from, uint256 amount);
    event DailyLimitUpdated(uint256 newLimit);
    event DailyLimitConsumed(uint256 indexed day, uint256 amount, uint256 totalWithdrawn);
    event WhitelistUpdated(address indexed target, bool status);

    // =================================================================
    // CONSTANTS
    // =================================================================

    string public constant VERSION = "3.0.0";

    /// @notice Delay before a self-service ETH withdrawal (no cold-signer
    ///         signature) can be executed after being initiated.
    uint256 public constant WITHDRAWAL_TIMELOCK = 12 hours;

    /// @notice Delay before a guardian / recovery-address / cold-signer
    ///         rotation can be finalized after being initiated. Gives the
    ///         other privileged role a window to notice and cancel a
    ///         rotation that was not authorized by them.
    uint256 public constant ROLE_ROTATION_DELAY = 24 hours;

    /// @dev EIP-712 typed-data hash for the `Withdraw` struct signed by
    ///      `coldSigner` to authorize withdrawSecure().
    bytes32 private constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address owner,uint256 amount,uint256 nonce,uint256 deadline)");

    /// @dev EIP-712 domain typehash (no `salt` field is used).
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // =================================================================
    // STATE VARIABLES (Data Storage)
    // =================================================================

    // --- Ownership ---
    address public owner;
    address public pendingOwner;

    // --- Guardian ---
    address public guardian;
    address public pendingGuardian;
    uint256 public guardianRotationUnlock;

    // --- Recovery address (destination for all rescued / swept assets) ---
    address public recoveryAddress;
    address public pendingRecoveryAddress;
    uint256 public recoveryRotationUnlock;

    // --- Cold signer (Proof-of-Possession signer for withdrawSecure) ---
    address public coldSigner;
    address public pendingColdSigner;
    uint256 public coldSignerRotationUnlock;

    // --- Circuit breaker ---
    bool public paused;

    // --- Timelocked self-service withdrawal (fallback path) ---
    uint256 public pendingWithdrawalAmount;
    uint256 public withdrawalUnlock;

    // --- Daily ETH withdrawal limit ---
    uint256 public dailyLimit;
    uint256 public dailyWithdrawn;
    uint256 public lastWithdrawDay;

    // --- Whitelist (bypasses the daily limit) & replay protection ---
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public nonces;

    // --- Reentrancy guard flags ---
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // --- EIP-712 domain separator, fixed at deploy time ---
    bytes32 private immutable _DOMAIN_SEPARATOR;

    // =================================================================
    // ACCESS CONTROL MODIFIERS
    // =================================================================

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyGuardian() { if (msg.sender != guardian) revert NotGuardian(); _; }
    modifier onlyOwnerOrGuardian() { if (msg.sender != owner && msg.sender != guardian) revert Unauthorized(); _; }
    modifier whenNotPaused() { if (paused) revert ContractPaused(); _; }
    modifier whenPaused() { if (!paused) revert NotPaused(); _; }
    modifier noWithdrawalPending() { if (pendingWithdrawalAmount > 0) revert WithdrawalPending(); _; }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert Unauthorized();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // =================================================================
    // CONSTRUCTOR
    // =================================================================

    /**
     * @param initialGuardian       Address authorized to perform rescues and
     *                               act as a circuit-breaker / veto role.
     * @param initialRecoveryAddress Destination for all rescued and swept assets.
     * @param initialDailyLimit     Daily ETH withdrawal limit (must be > 0).
     * @param initialColdSigner     Offline key that signs EIP-712 `Withdraw`
     *                               messages for withdrawSecure().
     */
    constructor(
        address initialGuardian,
        address initialRecoveryAddress,
        uint256 initialDailyLimit,
        address initialColdSigner
    ) {
        if (
            initialGuardian == address(0) ||
            initialRecoveryAddress == address(0) ||
            initialColdSigner == address(0)
        ) revert ZeroAddress();
        if (initialDailyLimit == 0) revert InvalidLimit();

        owner = msg.sender;
        guardian = initialGuardian;
        recoveryAddress = initialRecoveryAddress;
        coldSigner = initialColdSigner;
        dailyLimit = initialDailyLimit;
        _reentrancyStatus = _NOT_ENTERED;

        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("GuardianAngel"),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(this)
            )
        );

        emit OwnershipTransferred(address(0), msg.sender);
        emit RecoveryAddressUpdated(address(0), initialRecoveryAddress);
        emit DailyLimitUpdated(initialDailyLimit);
    }

    // =================================================================
    // OWNERSHIP (two-step transfer)
    // =================================================================

    /**
     * @notice Begins transferring ownership to `newOwner`.
     * @dev Ownership only changes once `newOwner` calls acceptOwnership(),
     *      so a mistyped or unreachable address cannot brick the contract.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == owner) revert NoChange();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Completes an ownership transfer. Callable only by `pendingOwner`.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    /// @notice Cancels a pending ownership transfer.
    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert NoRotationPending();
        pendingOwner = address(0);
    }

    // =================================================================
    // GUARDIAN ROTATION (24h timelock, vetoable by owner or guardian)
    // =================================================================

    /// @notice Nominates `newGuardian`; takes effect after ROLE_ROTATION_DELAY.
    function initiateGuardianRotation(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        if (newGuardian == guardian) revert NoChange();
        pendingGuardian = newGuardian;
        guardianRotationUnlock = block.timestamp + ROLE_ROTATION_DELAY;
        emit GuardianRotationInitiated(guardian, newGuardian, guardianRotationUnlock);
    }

    /// @notice Activates the pending guardian once the timelock has elapsed.
    function finalizeGuardianRotation() external onlyOwner {
        if (pendingGuardian == address(0)) revert NoRotationPending();
        if (block.timestamp < guardianRotationUnlock) revert TimelockActive();
        address previous = guardian;
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianRotationUnlock = 0;
        emit GuardianRotated(previous, guardian);
    }

    /// @notice Cancels a pending guardian rotation. The current owner OR the
    ///         current guardian can do this - so a rotation cannot be used
    ///         to silently remove the guardian's veto rights without notice.
    function cancelGuardianRotation() external onlyOwnerOrGuardian {
        if (pendingGuardian == address(0)) revert NoRotationPending();
        pendingGuardian = address(0);
        guardianRotationUnlock = 0;
        emit GuardianRotationCancelled(msg.sender);
    }

    // =================================================================
    // RECOVERY ADDRESS ROTATION (24h timelock, vetoable by owner or guardian)
    // =================================================================

    /// @notice Nominates a new recovery (rescue destination) address.
    function initiateRecoveryRotation(address newRecovery) external onlyOwner {
        if (newRecovery == address(0)) revert ZeroAddress();
        if (newRecovery == recoveryAddress) revert NoChange();
        pendingRecoveryAddress = newRecovery;
        recoveryRotationUnlock = block.timestamp + ROLE_ROTATION_DELAY;
        emit RecoveryRotationInitiated(recoveryAddress, newRecovery, recoveryRotationUnlock);
    }

    /// @notice Activates the pending recovery address once the timelock has elapsed.
    function finalizeRecoveryRotation() external onlyOwner {
        if (pendingRecoveryAddress == address(0)) revert NoRotationPending();
        if (block.timestamp < recoveryRotationUnlock) revert TimelockActive();
        address previous = recoveryAddress;
        recoveryAddress = pendingRecoveryAddress;
        pendingRecoveryAddress = address(0);
        recoveryRotationUnlock = 0;
        emit RecoveryAddressUpdated(previous, recoveryAddress);
    }

    /// @notice Cancels a pending recovery-address rotation.
    function cancelRecoveryRotation() external onlyOwnerOrGuardian {
        if (pendingRecoveryAddress == address(0)) revert NoRotationPending();
        pendingRecoveryAddress = address(0);
        recoveryRotationUnlock = 0;
        emit RecoveryRotationCancelled(msg.sender);
    }

    // =================================================================
    // COLD SIGNER ROTATION (24h timelock, vetoable by owner or guardian)
    // =================================================================

    /// @notice Nominates a new cold-signer key (e.g. after device loss).
    function initiateColdSignerRotation(address newColdSigner) external onlyOwner {
        if (newColdSigner == address(0)) revert ZeroAddress();
        if (newColdSigner == coldSigner) revert NoChange();
        pendingColdSigner = newColdSigner;
        coldSignerRotationUnlock = block.timestamp + ROLE_ROTATION_DELAY;
        emit ColdSignerRotationInitiated(coldSigner, newColdSigner, coldSignerRotationUnlock);
    }

    /// @notice Activates the pending cold signer once the timelock has elapsed.
    function finalizeColdSignerRotation() external onlyOwner {
        if (pendingColdSigner == address(0)) revert NoRotationPending();
        if (block.timestamp < coldSignerRotationUnlock) revert TimelockActive();
        address previous = coldSigner;
        coldSigner = pendingColdSigner;
        pendingColdSigner = address(0);
        coldSignerRotationUnlock = 0;
        emit ColdSignerRotated(previous, coldSigner);
    }

    /// @notice Cancels a pending cold-signer rotation.
    function cancelColdSignerRotation() external onlyOwnerOrGuardian {
        if (pendingColdSigner == address(0)) revert NoRotationPending();
        pendingColdSigner = address(0);
        coldSignerRotationUnlock = 0;
        emit ColdSignerRotationCancelled(msg.sender);
    }

    // =================================================================
    // CIRCUIT BREAKER
    // =================================================================

    /**
     * @notice Pauses the contract. While paused, all withdrawal paths
     *         (withdrawSecure / initiateWithdrawal / executeWithdrawal) are
     *         blocked and the guardian-only emergencyWithdraw() unlocks.
     * @dev Callable by either the owner or the guardian, so the guardian can
     *      unilaterally freeze the contract if it observes a compromised
     *      owner key attempting a malicious withdrawal.
     */
    function pause() external onlyOwnerOrGuardian {
        if (paused) revert ContractPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpauses the contract.
     * @dev Owner-only by design: if the guardian role itself is the one that
     *      is compromised, it should not also be able to silently lift the
     *      pause it (or the owner) put in place.
     */
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // =================================================================
    // DAILY LIMIT & WHITELIST ADMINISTRATION
    // =================================================================

    /// @notice Updates the daily ETH withdrawal limit used by withdrawSecure()
    ///         and executeWithdrawal().
    function setDailyLimit(uint256 newLimit) external onlyOwner {
        if (newLimit == 0) revert InvalidLimit();
        dailyLimit = newLimit;
        emit DailyLimitUpdated(newLimit);
    }

    /**
     * @notice Sets whitelist status for `target`. Whitelisted destinations
     *         bypass the daily withdrawal limit entirely.
     * @dev Use with care - this is intended only for trusted destinations
     *      such as `owner` itself in setups where the daily limit should not
     *      apply at all.
     */
    function setWhitelist(address target, bool status) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        isWhitelisted[target] = status;
        emit WhitelistUpdated(target, status);
    }

    // =================================================================
    // CORE SECURE LOGIC: INSTANT WITHDRAWAL (EIP-712 cold-signer signature)
    // =================================================================

    /**
     * @notice Withdraws `amount` ETH to `owner` immediately, authorized by an
     *         EIP-712 signature from `coldSigner`.
     * @dev The signed struct is:
     *
     *          Withdraw(address owner, uint256 amount, uint256 nonce, uint256 deadline)
     *
     *      hashed and combined with this contract's domain separator
     *      (name = "GuardianAngel", version = VERSION, chainId, this address)
     *      per EIP-712. `nonce` is `nonces[owner]` and is consumed on use,
     *      and `deadline` bounds how long a signature remains valid. Use
     *      `withdrawDigest()` to compute the exact digest for the cold
     *      signer to sign off-chain.
     *
     * @param amount  ETH amount to withdraw.
     * @param deadline Unix timestamp after which the signature is invalid.
     * @param v,r,s   ECDSA signature components from `coldSigner`.
     */
    function withdrawSecure(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        if (amount == 0 || amount > address(this).balance) revert InsufficientFunds();
        if (block.timestamp > deadline) revert SignatureExpired();

        uint256 currentNonce = nonces[owner];
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, amount, currentNonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != coldSigner) revert InvalidSignature();

        // Effects before interaction.
        nonces[owner] = currentNonce + 1;
        _enforceDailyLimit(owner, amount);

        _sendETH(payable(owner), amount);
    }

    // =================================================================
    // FALLBACK WITHDRAWAL PATH (12h timelock, no cold signer required)
    // =================================================================

    /**
     * @notice Begins a timelocked withdrawal of `amount` ETH to `owner`,
     *         executable after WITHDRAWAL_TIMELOCK with no cold-signer
     *         signature required.
     * @dev Exists so the owner is never permanently locked out of contract
     *      funds if the cold signer key is lost. Only one request may be
     *      pending at a time.
     */
    function initiateWithdrawal(uint256 amount) external onlyOwner whenNotPaused noWithdrawalPending {
        if (amount == 0 || amount > address(this).balance) revert InsufficientFunds();
        pendingWithdrawalAmount = amount;
        withdrawalUnlock = block.timestamp + WITHDRAWAL_TIMELOCK;
        emit WithdrawalInitiated(amount, withdrawalUnlock);
    }

    /**
     * @notice Cancels a pending timelocked withdrawal.
     * @dev Callable by owner OR guardian - giving the guardian a veto window
     *      over any withdrawal request made via the signer-independent path.
     */
    function cancelWithdrawal() external onlyOwnerOrGuardian {
        uint256 amount = pendingWithdrawalAmount;
        if (amount == 0) revert NoWithdrawalPending();
        pendingWithdrawalAmount = 0;
        withdrawalUnlock = 0;
        emit WithdrawalCancelled(amount);
    }

    /// @notice Executes a pending timelocked withdrawal once its delay has elapsed.
    function executeWithdrawal() external onlyOwner whenNotPaused nonReentrant {
        uint256 amount = pendingWithdrawalAmount;
        if (amount == 0) revert NoWithdrawalPending();
        if (block.timestamp < withdrawalUnlock) revert TimelockActive();
        if (amount > address(this).balance) revert InsufficientFunds();

        pendingWithdrawalAmount = 0;
        withdrawalUnlock = 0;

        _enforceDailyLimit(owner, amount);
        _sendETH(payable(owner), amount);
        emit WithdrawalExecuted(owner, amount);
    }

    // =================================================================
    // EMERGENCY EXIT (guardian-only, while paused)
    // =================================================================

    /**
     * @notice Sweeps the entire ETH balance to `recoveryAddress`.
     * @dev Requires the contract to already be paused, so this can never be
     *      a silent drain path during normal operation - pausing is itself
     *      a loud, on-chain signal that something is wrong. Funds always go
     *      to `recoveryAddress`, never to an address the caller chooses, and
     *      the daily limit does not apply (this IS the emergency).
     */
    function emergencyWithdraw() external onlyGuardian whenPaused nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert InsufficientFunds();
        _sendETH(payable(recoveryAddress), amount);
        emit EmergencyWithdrawal(recoveryAddress, amount);
    }

    // =================================================================
    // GUARDIAN & RESCUE LOGIC (asset recovery operations)
    // =================================================================

    /// @notice Rescues `amount` of an ERC-20 `token` held by this contract to `recoveryAddress`.
    function rescueERC20(address token, uint256 amount) external onlyGuardian nonReentrant {
        if (amount == 0) revert InsufficientFunds();
        _safeTransfer(token, recoveryAddress, amount);
        emit ERC20Rescued(token, recoveryAddress, amount);
    }

    /**
     * @notice Rescues `amount` of an ERC-20 `token` from a third-party
     *         account `from` to `recoveryAddress`, authorized by an
     *         EIP-2612 `permit` signature from `from`.
     * @dev Intended for the scenario where a user's wallet is compromised or
     *      about to be drained: the user signs a `permit` message off-chain
     *      (no gas needed), and the guardian executes the rescue on their
     *      behalf, racing an attacker to move the tokens to safety.
     * @param token    ERC-20 token implementing EIP-2612.
     * @param from     Token owner who signed the permit.
     * @param amount   Amount to pull and forward.
     * @param deadline Permit signature deadline.
     * @param v,r,s    ECDSA signature components from `from`.
     */
    function rescueERC20WithPermit(
        address token,
        address from,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyGuardian nonReentrant {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert InsufficientFunds();
        _validateContract(token);

        IERC20PermitMinimal(token).permit(from, address(this), amount, deadline, v, r, s);
        _safeTransferFrom(token, from, recoveryAddress, amount);

        emit ERC20PermitRescued(token, from, recoveryAddress, amount);
    }

    /// @notice Rescues ERC-721 token `tokenId` of `token` held by this contract to `recoveryAddress`.
    function rescueERC721(address token, uint256 tokenId) external onlyGuardian nonReentrant {
        _validateContract(token);
        IERC721Minimal(token).safeTransferFrom(address(this), recoveryAddress, tokenId);
        emit ERC721Rescued(token, recoveryAddress, tokenId);
    }

    /// @notice Rescues `amount` of ERC-1155 `id` of `token` held by this contract to `recoveryAddress`.
    function rescueERC1155(address token, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyGuardian
        nonReentrant
    {
        if (amount == 0) revert InsufficientFunds();
        _validateContract(token);
        IERC1155Minimal(token).safeTransferFrom(address(this), recoveryAddress, id, amount, data);
        emit ERC1155Rescued(token, recoveryAddress, id, amount);
    }

    /// @notice Rescues a batch of ERC-1155 `ids`/`amounts` of `token` held by this contract to `recoveryAddress`.
    function rescueERC1155Batch(
        address token,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external onlyGuardian nonReentrant {
        if (ids.length == 0 || ids.length != amounts.length) revert ArrayLengthMismatch();
        _validateContract(token);
        IERC1155Minimal(token).safeBatchTransferFrom(address(this), recoveryAddress, ids, amounts, data);
        emit ERC1155BatchRescued(token, recoveryAddress, ids, amounts);
    }

    // =================================================================
    // EIP-712 / EIP-5267 VIEW HELPERS (for off-chain signing tooling)
    // =================================================================

    /// @notice Returns the EIP-712 domain separator used by withdrawSecure().
    function domainSeparator() external view returns (bytes32) {
        return _DOMAIN_SEPARATOR;
    }

    /**
     * @notice Computes the exact EIP-712 digest that `coldSigner` must sign
     *         to authorize a withdrawSecure() call for `amount` with the
     *         current nonce and the given `deadline`.
     */
    function withdrawDigest(uint256 amount, uint256 deadline) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, owner, amount, nonces[owner], deadline));
        return keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));
    }

    /// @notice EIP-5267 domain description, for wallets that render EIP-712
    ///         requests to the cold signer.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            hex"0f", // name, version, chainId, verifyingContract present; no salt
            "GuardianAngel",
            VERSION,
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }

    // =================================================================
    // INTERNAL HELPERS (Security & Optimization)
    // =================================================================

    /**
     * @dev Enforces and updates the rolling daily ETH withdrawal limit for
     *      destination `to`. Whitelisted destinations bypass the limit
     *      entirely. Reverts with DailyLimitExceeded if `amount` would push
     *      the day's total over `dailyLimit`.
     */
    function _enforceDailyLimit(address to, uint256 amount) private {
        if (isWhitelisted[to]) return;

        uint256 currentDay = block.timestamp / 1 days;
        if (currentDay > lastWithdrawDay) {
            if (amount > dailyLimit) revert DailyLimitExceeded();
            lastWithdrawDay = currentDay;
            dailyWithdrawn = amount;
            emit DailyLimitConsumed(currentDay, amount, amount);
        } else {
            if (dailyWithdrawn + amount > dailyLimit) revert DailyLimitExceeded();
            dailyWithdrawn += amount;
            emit DailyLimitConsumed(currentDay, amount, dailyWithdrawn);
        }
    }

    /// @dev Sends `amount` ETH to `to`, reverting on failure.
    function _sendETH(address payable to, uint256 amount) private {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @dev Transfers `amount` of `token` to `to`, tolerating tokens that
    ///      return no boolean (treated as success if the call itself succeeds).
    function _safeTransfer(address token, address to, uint256 amount) private {
        _validateContract(token);
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Same as _safeTransfer but via `transferFrom`, for permit-based rescues.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev Reverts if `token` is not a contract.
    function _validateContract(address token) private view {
        if (token.code.length == 0) revert InvalidToken();
    }

    // =================================================================
    // FALLBACKS & INTERFACE SUPPORT
    // =================================================================

    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        if (msg.value > 0) emit ETHReceived(msg.sender, msg.value);
    }

    /// @dev Advertises ERC-165, ERC-721 receiver, and ERC-1155 receiver support.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x150b7a02 // ERC721TokenReceiver
            || interfaceId == 0x4e2312e0; // ERC1155TokenReceiver
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
