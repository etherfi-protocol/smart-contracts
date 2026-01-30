// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IRoleRegistry.sol";

contract RestakingRewardsRouter is UUPSUpgradeable {
    using SafeERC20 for IERC20;

    address public immutable liquidityPool;
    address public immutable rewardTokenAddress;
    IRoleRegistry public immutable roleRegistry;

    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");

    bytes32 public constant ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE =
        keccak256("ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE");

    address public recipientAddress;

    event EthSent(address indexed from, address indexed to, address indexed sender, uint256 value);
    event RecipientAddressSet(address indexed recipient);
    event Erc20Recovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    error InvalidAddress();
    error NoRecipientSet();
    error TransferFailed();
    error IncorrectRole();

    constructor(
        address _roleRegistry,
        address _rewardTokenAddress,
        address _liquidityPool
    ) {
        _disableInitializers();
        if (
            _rewardTokenAddress == address(0) ||
            _liquidityPool == address(0) ||
            _roleRegistry == address(0)
        ) revert InvalidAddress();
        roleRegistry = IRoleRegistry(_roleRegistry);
        rewardTokenAddress = _rewardTokenAddress;
        liquidityPool = _liquidityPool;
    }

    receive() external payable {
        (bool success, ) = liquidityPool.call{value: msg.value}("");
        if (!success) revert TransferFailed();
        emit EthSent(address(this), liquidityPool, msg.sender, msg.value);
    }

    function initialize() public initializer {
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

    /// @dev Manual transfer function to recover reward tokens that may have accumulated in the contract
    function recoverERC20() external {
        if (
            !roleRegistry.hasRole(
                ETHERFI_REWARDS_ROUTER_ERC20_TRANSFER_ROLE,
                msg.sender
            )
        ) revert IncorrectRole();
        if (recipientAddress == address(0)) revert NoRecipientSet();

        uint256 balance = IERC20(rewardTokenAddress).balanceOf(address(this));
        if (balance > 0) {
            IERC20(rewardTokenAddress).safeTransfer(recipientAddress, balance);
            emit Erc20Recovered(
                rewardTokenAddress,
                recipientAddress,
                balance
            );
        }
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
