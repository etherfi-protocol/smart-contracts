// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/ITreasury.sol";

contract Treasury is ITreasury, Ownable {
    
    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Function allows only the owner to withdraw all the funds in the contract
    function withdraw(uint256 _amount, address _to) external onlyOwner {
        require(
            _amount <= address(this).balance,
            "the balance is lower than the requested amount"
        );
        require(_to != address(0), "null address is not allowed");
        (bool sent, ) = payable(_to).call{value: _amount}("");
        require(sent, "Failed to send Ether");
    }

    //Allows ether to be sent to this contract
    receive() external payable {}
}
