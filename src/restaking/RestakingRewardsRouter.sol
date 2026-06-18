// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";

contract RestakingRewardsRouter is UUPSUpgradeable, RolesLibrary {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    address public recipientAddress;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    address public immutable liquidityPool;
    address public immutable rewardTokenAddress;

    //--------------------------------------------------------------------------------------
    //---------------------------------  EVENTS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    event EthSent(address indexed from, address indexed to, address indexed sender, uint256 value);
    event RecipientAddressSet(address indexed recipient);
    event Erc20Recovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    //--------------------------------------------------------------------------------------
    //---------------------------------  ERRORS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    error InvalidAddress();
    error NoRecipientSet();
    error TransferFailed();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _roleRegistry The address of the role registry
     * @param _rewardTokenAddress The address of the reward token
     * @param _liquidityPool The address of the liquidity pool
     */
    constructor(
        address _roleRegistry,
        address _rewardTokenAddress,
        address _liquidityPool
    ) RolesLibrary(_roleRegistry) {
        _disableInitializers();
        if (
            _rewardTokenAddress == address(0) ||
            _liquidityPool == address(0)
        ) revert InvalidAddress();
        rewardTokenAddress = _rewardTokenAddress;
        liquidityPool = _liquidityPool;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the RestakingRewardsRouter
     */
    function initialize() public initializer {
        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {
        (bool success, ) = liquidityPool.call{value: msg.value}("");
        if (!success) revert TransferFailed();
        emit EthSent(address(this), liquidityPool, msg.sender, msg.value);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  ADMIN FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Set the recipient address
     * @param _recipient The address of the recipient
     */
    function setRecipientAddress(address _recipient) external onlyOperatingTimelock {
        if (_recipient == address(0)) revert InvalidAddress();
        recipientAddress = _recipient;
        emit RecipientAddressSet(_recipient);
    }

    /**
     * @notice Recover ERC20 tokens
     * @dev Manual transfer function to recover reward tokens
     */
    function recoverERC20() external onlyHousekeepingOperations {
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

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Authorize upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //---------------------------------  GETTERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the implementation
     * @return The implementation
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
