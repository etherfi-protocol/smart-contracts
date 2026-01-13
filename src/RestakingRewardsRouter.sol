// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./RoleRegistry.sol";

interface IERC20Receiver {
    function onERC20Received(
        address token,
        address from,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}

contract RestakingRewardsRouter is OwnableUpgradeable, UUPSUpgradeable, IERC20Receiver {
    using SafeERC20 for IERC20;

    address public immutable rewardTokenAddress;
    address public immutable liquidityPool;
    address public recipientAddress;
    RoleRegistry public immutable roleRegistry;

    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");

    bytes4 private constant _ERC20_RECEIVED = IERC20Receiver.onERC20Received.selector;

    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event RecipientAddressSet(address indexed recipient);
    event Erc20Transferred(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    error InvalidAddress();
    error NoRecipientSet();
    error InvalidToken(address token);
    error TransferFailed();
    error IncorrectRole();

    constructor(address _roleRegistry, address _rewardTokenAddress, address _liquidityPool) {
        _disableInitializers();
        if (_rewardTokenAddress == address(0) || _liquidityPool == address(0) || _roleRegistry == address(0)) revert InvalidAddress();
        roleRegistry = RoleRegistry(_roleRegistry);
        rewardTokenAddress = _rewardTokenAddress;
        liquidityPool = _liquidityPool;
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
        (bool success, ) = liquidityPool.call{value: msg.value}("");
        if (!success) revert TransferFailed();
        emit EthSent(address(this), liquidityPool, msg.value);
    }

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function setRecipientAddress(address _recipient) external {
        if (
            !roleRegistry.hasRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, msg.sender)
        ) revert IncorrectRole();
        if (_recipient == address(0)) revert InvalidAddress();
        recipientAddress = _recipient;
        emit RecipientAddressSet(_recipient);
    }

    /// @dev ERC20 receive hook - automatically forwards tokens when received
    function onERC20Received(
        address token,
        address /* from */,
        uint256 amount,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        // Only accept the configured reward token
        if (token != rewardTokenAddress) revert InvalidToken(token);
        
        if (recipientAddress == address(0)) revert NoRecipientSet();
        
        // Forward the tokens immediately
        IERC20(token).safeTransfer(recipientAddress, amount);
        emit Erc20Transferred(token, recipientAddress, amount);
        
        return _ERC20_RECEIVED;
    }

    /// @dev Manual transfer function to recover ERC20 tokens that may have accumulated in the contract
    /// @param token The address of the ERC20 token to transfer
    function transferERC20(address token) external {
        if (token == address(0)) revert InvalidAddress();
        if (recipientAddress == address(0)) revert NoRecipientSet();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipientAddress, balance);
            emit Erc20Transferred(token, recipientAddress, balance);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
