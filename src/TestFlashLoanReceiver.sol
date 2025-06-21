// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../src/IFlashLoanReceiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestFlashLoanReceiver is IFlashLoanReceiver {
    address public vault;

    constructor(address _vault) {
        vault = _vault;
    }

    function onFlashLoan(
        address /* initiator */,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bytes32) {
        // Repay loan with fee
        IERC20(token).transfer(vault, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
