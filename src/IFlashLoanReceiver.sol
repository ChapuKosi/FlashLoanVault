// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFlashLoanReceiver {
    /**
     * @dev Called after the contract has received the flash loaned amount.
     * Must return the keccak256 hash of "ERC3156FlashBorrower.onFlashLoan".
     */
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}
