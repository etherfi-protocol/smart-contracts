// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../lib/solady/src/utils/ReentrancyGuardTransient.sol";


/**
 * @title AssetRecovery
 * @dev A library for recovering ETH, ERC20 tokens, and ERC721 tokens that were
 * mistakenly sent to this contract.
 */
abstract contract AssetRecovery is ReentrancyGuardTransient {

    using SafeERC20 for IERC20;
    
    /**
     * @dev Emitted when ETH is recovered
     */
    event ETHRecovered(address indexed to, uint256 amount);
    
    /**
     * @dev Emitted when ERC20 tokens are recovered
     */
    event ERC20Recovered(address indexed token, address indexed to, uint256 amount);
    
    /**
     * @dev Emitted when an ERC721 token is recovered
     */
    event ERC721Recovered(address indexed token, address indexed to, uint256 tokenId);

    /**
     * @dev Error thrown when address or amount inputs are invalid
     * Reverted when:
     * - Target address is the zero address
     * - Token address is the zero address
     * - Amount is zero
     */
    error InvalidInput();

    /**
     * @dev Error thrown when trying to recover more assets than available
     * Reverted when:
     * - Trying to recover more ETH than the contract's balance
     * - Trying to recover more ERC20 tokens than the contract's balance
     */
    error InsufficientBalance();

    /**
     * @dev Error thrown when ETH transfer fails
     * Reverted when the ETH transfer fails for any reason, which could indicate:
     * - Gas issues
     * - Recipient contract rejecting the transfer
     * - Revert in recipient's fallback/receive function
     */
    error EthTransferFailed();

    /**
     * @dev Error thrown when trying to recover an ERC721 token that this contract doesn't own
     * Reverted when:
     * - The contract is not the actual owner of the specified tokenId
     * - The tokenId doesn't exist
     */
    error ContractIsNotOwnerOfERC721Token();

    /**
     * @dev Recover ETH from the contract
     * @param to Address to send the recovered ETH to
     * @param amount Amount of ETH to recover
     */
    function _recoverETH(address payable to, uint256 amount) internal nonReentrant {
        if (to == address(0) || amount == 0) revert InvalidInput();
        if (amount > address(this).balance) revert InsufficientBalance();

        (bool success, ) = to.call{value: amount}("");
        if (!success) revert EthTransferFailed();
        
        emit ETHRecovered(to, amount);
    }

    /**
     * @dev Recover ERC20 tokens from the contract
     * @param token Address of the ERC20 token
     * @param to Address to send the recovered tokens to
     * @param amount Amount of tokens to recover
     */
    function _recoverERC20(address token, address to, uint256 amount) internal nonReentrant {
        if (token == address(0) || to == address(0) || amount == 0) revert InvalidInput();
        if (amount > IERC20(token).balanceOf(address(this))) revert InsufficientBalance();
        
        IERC20(token).safeTransfer(to, amount);
        
        emit ERC20Recovered(token, to, amount);
    }

    /**
     * @dev Recover an ERC721 token from the contract
     * @param token Address of the ERC721 token
     * @param to Address to send the recovered token to
     * @param tokenId ID of the token to recover
     */
    function _recoverERC721(address token, address to, uint256 tokenId) internal nonReentrant {
        if (token == address(0) || to == address(0)) revert InvalidInput();
        if (IERC721(token).ownerOf(tokenId) != address(this)) revert ContractIsNotOwnerOfERC721Token();
        
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
        
        emit ERC721Recovered(token, to, tokenId);
    }
}
