// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FlashLoanVault.sol";
import "../src/TestToken.sol";
import "../src/TestFlashLoanReceiver.sol";

contract FlashLoanVaultTest is Test {
    FlashLoanVault vault;
    TestToken token;
    TestFlashLoanReceiver receiver;

    address user = address(0x1);
    uint256 initialDeposit = 1_000_000e6;

    function setUp() public {
        token = new TestToken();
        vault = new FlashLoanVault(address(token));
        receiver = new TestFlashLoanReceiver(address(vault));

        token.mint(user, initialDeposit);
        vm.prank(user);
        token.approve(address(vault), initialDeposit);

        // User deposits tokens into vault
        vm.prank(user);
        vault.deposit(initialDeposit);
    }

    function testDepositWorks() public view{
        assertEq(token.balanceOf(address(vault)), initialDeposit);
        assertEq(vault.totalAssets(), initialDeposit);
        assertGt(vault.totalShares(), 0);
        assertEq(vault.shares(user), vault.totalShares() - vault.shares(address(0))); // No dust lost
    }

    function testFlashLoanRepayment() public {
        uint256 loanAmount = 100_000e6;
        uint256 fee = (loanAmount * 5) / 10000;
        bytes memory data;

        // Fund the receiver with enough to repay amount + fee
        token.mint(address(receiver), fee);

        // Run the flash loan
        vault.flashLoan(receiver, address(token), loanAmount, data);

        // Vault should have gained the fee
        assertEq(vault.totalAssets(), initialDeposit + fee);
    }

    function testFlashLoanFailsIfNotRepaid() public {
        // Custom receiver that doesn’t repay
        address evil = address(new BrokenReceiver());
        bytes memory data;
        vm.expectRevert();
        vault.flashLoan(IFlashLoanReceiver(evil), address(token), 100_000e6, data);
    }
}

contract BrokenReceiver is IFlashLoanReceiver {
    function onFlashLoan(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes32) {
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
