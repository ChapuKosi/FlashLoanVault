// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IFlashLoanReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FlashLoanVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // The ERC20 token that users can deposit/withdraw/borrow
    IERC20 public immutable token;

    // Total shares minted to all users (excluding dust)
    uint256 public totalShares;

    // Total underlying assets held by the vault
    uint256 public totalAssets;

    // Each user's share balance
    mapping(address => uint256) public shares;

    // Tracks who made the very first deposit
    address public firstDepositor;

    // Ensures first depositor gets refunded for dust only once
    bool public dustRefunded;

    // Fixed dust amount used to initialize the vault safely
    uint256 public constant MINIMUM_SHARES = 1e6;

    // Used to verify valid flash loan callback return value
    bytes32 public constant FLASHLOAN_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Tracks outstanding flash loan amount (used in fee calculation)
    uint256 public totalFlashLoansOutstanding;

    // Flash loan base fee (0.05%)
    uint256 public immutable baseFee = 5;

    // Flash loan fee slope (up to +0.45% at 100% utilization)
    uint256 public immutable feeSlope = 45;

    // Events emitted for frontend or off-chain tracking
    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 amount, uint256 sharesBurned);
    event FlashLoanExecuted(address indexed receiver, uint256 amount, uint256 fee);

    // Constructor sets the vault token
    constructor(address _token) {
        token = IERC20(_token);
    }

    /// @notice Deposit tokens and mint vault shares
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 newShares;

        if (totalShares == 0) {
            // First ever deposit must be large enough to support MINIMUM_SHARES
            require(amount > MINIMUM_SHARES * 100, "Minimum meaningful deposit required");

            // Mint actual shares minus dust
            newShares = amount - MINIMUM_SHARES;

            // Seed dust shares to address(0) (non-redeemable)
            shares[address(0)] = MINIMUM_SHARES;

            // Set first depositor
            firstDepositor = msg.sender;

            totalShares = MINIMUM_SHARES + newShares;
        } else {
            // Calculate proportional shares for later depositors
            require(totalAssets > 0, "Vault state invalid: totalAssets == 0");
            newShares = (amount * totalShares) / totalAssets;
            totalShares += newShares;
        }

        shares[msg.sender] += newShares;
        totalAssets += amount;

        emit Deposited(msg.sender, amount, newShares);
    }

    /// @notice Withdraw tokens by redeeming vault shares
    function withdraw(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Invalid amount");

        uint256 userShareBalance = shares[msg.sender];
        if (shareAmount > userShareBalance) {
            revert("Not enough shares");
        }

        // Refund dust to first depositor (only once)
        if (!dustRefunded && msg.sender == firstDepositor) {
            dustRefunded = true;
            shares[address(0)] -= MINIMUM_SHARES;
            totalShares        -= MINIMUM_SHARES;
            totalAssets        -= MINIMUM_SHARES;
            token.safeTransfer(msg.sender, MINIMUM_SHARES);
        }

        // Check if this is the last withdrawal (besides dust)
        uint256 circulatingShares = totalShares - shares[address(0)];
        bool isLast = (circulatingShares - shareAmount <= 1);

        // Calculate amount of tokens to withdraw
        uint256 tokenAmount = isLast
            ? totalAssets  // return everything
            : (shareAmount * totalAssets) / totalShares;

        require(tokenAmount > 0, "Invalid amount");

        // Burn shares and update state
        shares[msg.sender] = userShareBalance - shareAmount;
        totalShares -= shareAmount;
        totalAssets -= tokenAmount;

        // Final cleanup: burn dust if vault is emptied
        if (isLast && shares[address(0)] > 0) {
            totalShares -= shares[address(0)];
            shares[address(0)] = 0;
        }

        token.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(msg.sender, tokenAmount, shareAmount);
    }

    /// @notice Max flash loan amount (ERC-3156)
    function maxFlashLoan(address _token) external view returns (uint256) {
        return _token == address(token) ? totalAssets : 0;
    }

    /// @notice Calculate flash loan fee (ERC-3156)
    function flashFee(address _token, uint256 amount) public view returns (uint256) {
        require(_token == address(token), "Unsupported token");
        return _calculateFee(amount);
    }

    /// @notice Execute a flash loan with dynamic fee logic
    function flashLoan(
        IFlashLoanReceiver receiver,
        address _token,
        uint256 amount,
        bytes calldata data
    ) external nonReentrant {
        require(_token == address(token), "Unsupported token");
        require(amount > 0 && amount <= totalAssets, "Invalid amount");

        uint256 fee = _calculateFee(amount);
        totalFlashLoansOutstanding += amount;

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransfer(address(receiver), amount);

        // Require successful callback from receiver
        require(
            _verifyFlashLoanCallback(receiver, msg.sender, amount, fee, data),
            "Flash loan callback failed"
        );

        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter >= balanceBefore + fee, "Flash loan not repaid with fee");

        totalAssets += fee;
        totalFlashLoansOutstanding -= amount;

        emit FlashLoanExecuted(address(receiver), amount, fee);
    }

    /// @dev Internal fee calculator with utilization scaling
    function _calculateFee(uint256 amount) internal view returns (uint256) {
        if (totalAssets == 0) return 0;

        uint256 utilization = (totalFlashLoansOutstanding * 1e18) / totalAssets;
        uint256 dynamicRate = baseFee + ((feeSlope * utilization) / 1e18); // in basis points

        return (amount * dynamicRate) / 10_000;
    }

    /// @notice Returns the current price per share (for UI)
    function getPricePerShare() external view returns (uint256) {
        return (totalShares == 0) ? 1e18 : (totalAssets * 1e18) / totalShares;
    }

    /// @dev Helper to verify flash loan receiver callback
    function _verifyFlashLoanCallback(
        IFlashLoanReceiver receiver,
        address initiator,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) internal returns (bool) {
        return receiver.onFlashLoan(initiator, address(token), amount, fee, data) == FLASHLOAN_CALLBACK_SUCCESS;
    }
}
