// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FlashLoanVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DummyToken is ERC20 {
    constructor() ERC20("Dummy", "DUMMY") 
    { _mint(msg.sender, 1e24); }
}

contract FlashLoanVault_1Test is Test {
    FlashLoanVault vault;
    DummyToken token;

    address alice = address(0x1);
    address bob = address(0x2);
    uint256 initialDeposit = 1e21; // 1 million tokens with 18 decimals

    function setUp() public {
        token = new DummyToken();
        vault = new FlashLoanVault(address(token));

        token.transfer(alice, initialDeposit);
        token.transfer(bob, initialDeposit);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice Test direct-transfer manipulation: sending tokens directly should not affect shares
    function testDirectTransferDoesNotAffectShares() public {
        // Initial deposit by Alice
        vm.prank(alice);
        vault.deposit(1e20);

        uint256 sharesSnapshot = vault.totalShares();
        uint256 assetsSnapshot = vault.totalAssets();

        // Directly transfer tokens to vault (not using deposit)
        token.transfer(address(vault), 5e19);

        // Confirm vault balance increased, but totalAssets didn't
        assertEq(token.balanceOf(address(vault)), 1.5e20);
        assertEq(vault.totalAssets(), assetsSnapshot);

        // Bob deposits 5e19
        vm.prank(bob);
        vault.deposit(5e19);

        // Bob should get shares fairly (based on unmodified totalAssets)
        uint256 expectedShares = (5e19 * sharesSnapshot) / assetsSnapshot;
        assertEq(vault.shares(bob), expectedShares);
    }
    /// @notice Verifies vault doesn't accumulate rounding drift after many small deposit/withdraw cycles.
    /// @dev Assumes dust shares are cleaned on final withdrawal.
    function testRoundingDriftAfterRepeatedCycles() public {
        vm.startPrank(alice);
        vault.deposit(1e20);
        vault.withdraw(vault.shares(alice));
        vm.stopPrank();

        // Vault should now be empty (since it cleaned the dust)
        assertEq(vault.totalShares(), 0, "vault should be empty after first withdraw");
        assertEq(vault.totalAssets(), 0, "vault should be empty after first withdraw");

        uint256 cycles = 100;
        uint256 smallAmount = 1e18;

        for (uint256 i = 0; i < cycles; i++) {
            vm.startPrank(alice);
            vault.deposit(smallAmount);
            vault.withdraw(vault.shares(alice));
            vm.stopPrank();
        }

        // After many small cycles, vault should still be empty (i.e., no rounding drift)
        assertLe(vault.totalShares(), 1, "shares drifted");
        assertLe(vault.totalAssets(), 1, "assets drifted");
    }


    /// @notice Ensures that dust shares are created on first deposit and properly cleaned when vault empties.
    function testInitialDustLifecycle() public {
        uint256 firstDeposit = 2e8; // Just above MINIMUM_SHARES * 100

        // Step 1: Alice deposits for the first time
        vm.prank(alice);
        vault.deposit(firstDeposit);

        uint256 dust = vault.MINIMUM_SHARES();
        assertEq(vault.shares(address(0)), dust, "dust shares should be seeded");

        // Step 2: Alice deposits more
        vm.prank(alice);
        vault.deposit(1e18);

        // Capture total shares before withdrawal
        uint256 aliceSharesBefore = vault.shares(alice);

        // Withdraw everything in one go
        vm.prank(alice);
        vault.withdraw(aliceSharesBefore);

        // Step 3: Dust should now be cleaned
        assertEq(vault.shares(address(0)), 0, "dust shares should be burned after last withdraw");
        assertEq(vault.totalShares(), 0, "total shares should be 0 after cleanup");
    }

    /// @notice The first depositor should receive MINIMUM_SHARES back, once, on their first withdraw
    function testFirstDepositorDustRefund() public {
        uint256 dust = vault.MINIMUM_SHARES();
        uint256 firstAmount = dust * 150;

        vm.prank(alice);
        vault.deposit(firstAmount);

        uint256 aliceShares = vault.shares(alice);
        assertEq(vault.shares(address(0)), dust, "dust seeded");
        assertEq(vault.totalShares(), firstAmount, "totalShares seeded");
        assertEq(aliceShares, firstAmount - dust, "alice got correct shares");

        uint256 balanceBefore = token.balanceOf(alice);

        // First withdraw from Alice (should include dust refund)
        vm.startPrank(alice);
        vault.withdraw(aliceShares);
        vm.stopPrank();

        uint256 balanceAfter = token.balanceOf(alice);
        uint256 expectedReturn = firstAmount;

        assertEq(balanceAfter - balanceBefore, expectedReturn, "alice should reclaim her tokens plus dust");
        assertEq(vault.shares(address(0)), 0, "dust should already be burned");

        // Bob deposits
        vm.prank(bob);
        vault.deposit(1e20);
        uint256 bobShares = vault.shares(bob);

        console.log("Bob token amount", (bobShares * vault.totalAssets()) / vault.totalShares());

        // Bob withdraws all
        uint256 bobBalanceBefore = token.balanceOf(bob);

        vm.prank(bob);
        vault.withdraw(bobShares);

        uint256 bobBalanceAfter = token.balanceOf(bob);
        assertEq(bobBalanceAfter - bobBalanceBefore, 1e20, "Bob should get full refund");

        assertEq(vault.totalShares(), 0, "vault should be empty");
        assertEq(vault.totalAssets(), 0, "all tokens withdrawn");
        assertTrue(vault.dustRefunded(), "dustRefunded should be true");
    }
}
