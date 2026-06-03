// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IWeETHWithdrawAdapter} from "@etherfi/withdrawals/interfaces/IWeETHWithdrawAdapter.sol";
import {IWeETH} from "@etherfi/core/interfaces/IWeETH.sol";
import {IeETH} from "@etherfi/core/interfaces/IeETH.sol";
import {ILiquidityPool} from "@etherfi/core/interfaces/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "@etherfi/withdrawals/interfaces/IWithdrawRequestNFT.sol";
import {IBlacklister} from "@etherfi/governance/interfaces/IBlacklister.sol";
import {PausableUntil} from "@etherfi/governance/utils/PausableUntil.sol";
import {RolesLibrary} from "@etherfi/governance/utils/RolesLibrary.sol";

/**
 * @title WeETHWithdrawAdapter
 * @notice Adapter contract that allows users to request withdrawals using weETH directly
 * @dev This contract converts weETH to eETH and creates withdrawal requests in the existing system
 */
contract WeETHWithdrawAdapter is 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    PausableUntil,
    IWeETHWithdrawAdapter
{
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slot
    uint8 private __gap_0;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------
    IWeETH public immutable weETH;
    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IWithdrawRequestNFT public immutable withdrawRequestNFT;
    IBlacklister public immutable blacklister;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  --------------------------------------
    //--------------------------------------------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error InvalidAmount();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _weETH The address of the weETH token.
     * @param _eETH The address of the eETH token.
     * @param _liquidityPool The address of the liquidity pool.
     * @param _withdrawRequestNFT The address of the withdraw request NFT.
     * @param _roleRegistry The address of the role registry.
     * @param _blacklister The address of the blacklister.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address _weETH,
        address _eETH,
        address _liquidityPool,
        address _withdrawRequestNFT,
        address _roleRegistry,
        address _blacklister
    ) RolesLibrary(_roleRegistry) {
        if (_weETH == address(0) ||
            _eETH == address(0) ||
            _liquidityPool == address(0) ||
            _withdrawRequestNFT == address(0) ||
            _blacklister == address(0)) {
            revert ZeroAddress();
        }

        weETH = IWeETH(_weETH);
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        withdrawRequestNFT = IWithdrawRequestNFT(_withdrawRequestNFT);
        blacklister = IBlacklister(_blacklister);

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INITIALIZERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the adapter contract with initial owner
     * @param _initialOwner Address that will be set as the contract owner
     */
    function initialize(address _initialOwner) external initializer {
        if (_initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_initialOwner);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  WITHDRAW FUNCTIONS  -----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Request withdrawal using weETH tokens
     * @param weETHAmount Amount of weETH to withdraw
     * @param recipient Address that will receive the WithdrawRequestNFT
     * @return requestId The ID of the created withdrawal request
     */
    function requestWithdraw(uint256 weETHAmount, address recipient) 
        public 
        whenNotPaused 
        nonBlacklisted
        returns (uint256 requestId) 
    {
        if (weETHAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Transfer weETH from user to this contract
        IERC20(address(weETH)).safeTransferFrom(msg.sender, address(this), weETHAmount);
        
        // Unwrap weETH to get eETH
        uint256 eETHAmount = weETH.unwrap(weETHAmount);
        
        // Approve eETH to be spent by LiquidityPool
        IERC20(address(eETH)).safeIncreaseAllowance(address(liquidityPool), eETHAmount);
        
        // Create withdrawal request through LiquidityPool
        requestId = liquidityPool.requestWithdraw(recipient, eETHAmount);
                
        return requestId;
    }

    /**
     * @notice Request withdrawal using weETH tokens with permit (gasless approval)
     * @param weETHAmount Amount of weETH to withdraw
     * @param recipient Address that will receive the WithdrawRequestNFT
     * @param permit Permit data for weETH approval
     * @return requestId The ID of the created withdrawal request
     */
    function requestWithdrawWithPermit(
        uint256 weETHAmount,
        address recipient,
        PermitInput calldata permit
    ) external whenNotPaused returns (uint256 requestId) {
        // Use permit to approve weETH transfer
        try weETH.permit(
            msg.sender, 
            address(this), 
            permit.value, 
            permit.deadline, 
            permit.v, 
            permit.r, 
            permit.s
        ) {} catch {}

        // Call the regular requestWithdraw function
        return requestWithdraw(weETHAmount, recipient);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Authorize contract upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the current implementation address
     * @return The implementation contract address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    /**
     * @notice Get the equivalent eETH amount for a given weETH amount
     * @param weETHAmount Amount of weETH
     * @return eETHAmount Equivalent amount of eETH
     */
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256 eETHAmount) {
        return weETH.getEETHByWeETH(weETHAmount);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the caller is not blacklisted
     */
    modifier nonBlacklisted() {
        blacklister.nonBlacklisted(msg.sender);
        _;
    }
}
