// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IWeETHWithdrawAdapter} from "../interfaces/IWeETHWithdrawAdapter.sol";
import {IWeETH} from "../interfaces/IWeETH.sol";
import {IeETH} from "../interfaces/IeETH.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "../interfaces/IWithdrawRequestNFT.sol";
import {IRoleRegistry} from "../interfaces/IRoleRegistry.sol";

/**
 * @title WeETHWithdrawAdapter
 * @notice Adapter contract that allows users to request withdrawals using weETH directly
 * @dev This contract converts weETH to eETH and creates withdrawal requests in the existing system
 */
contract WeETHWithdrawAdapter is 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    IWeETHWithdrawAdapter 
{
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IWeETH public immutable weETH;
    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IWithdrawRequestNFT public immutable withdrawRequestNFT;
    IRoleRegistry public immutable roleRegistry;

    bool public paused;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant WEETH_WITHDRAW_ADAPTER_ADMIN_ROLE = keccak256("WEETH_WITHDRAW_ADAPTER_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  --------------------------------------
    //--------------------------------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error ContractPaused();
    error IncorrectRole();
    error InvalidAmount();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  --------------------------------------
    //--------------------------------------------------------------------------------------

    event Paused(address account);
    event Unpaused(address account);

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _weETH,
        address _eETH,
        address _liquidityPool,
        address _withdrawRequestNFT,
        address _roleRegistry
    ) {
        if (_weETH == address(0) || 
            _eETH == address(0) || 
            _liquidityPool == address(0) || 
            _withdrawRequestNFT == address(0) ||
            _roleRegistry == address(0)) {
            revert ZeroAddress();
        }

        weETH = IWeETH(_weETH);
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        withdrawRequestNFT = IWithdrawRequestNFT(_withdrawRequestNFT);
        roleRegistry = IRoleRegistry(_roleRegistry);
        
        _disableInitializers();
    }

    /**
     * @notice Initialize the adapter contract (only sets owner and paused state)
     */
    function initialize() external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        paused = false;
    }

    /**
     * @notice Request withdrawal using weETH tokens
     * @param weETHAmount Amount of weETH to withdraw
     * @param recipient Address that will receive the WithdrawRequestNFT
     * @return requestId The ID of the created withdrawal request
     */
    function requestWithdraw(uint256 weETHAmount, address recipient) 
        public 
        whenNotPaused 
        returns (uint256 requestId) 
    {
        if (weETHAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Transfer weETH from user to this contract
        IERC20(address(weETH)).safeTransferFrom(msg.sender, address(this), weETHAmount);
        
        // Unwrap weETH to get eETH
        uint256 eETHAmount = weETH.unwrap(weETHAmount);
        
        // Approve eETH to be spent by LiquidityPool
        IERC20(address(eETH)).safeApprove(address(liquidityPool), eETHAmount);
        
        // Create withdrawal request through LiquidityPool
        requestId = liquidityPool.requestWithdraw(recipient, eETHAmount);
        
        emit WithdrawRequested(msg.sender, recipient, weETHAmount, eETHAmount, requestId);
        
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
    //----------------------------------  ADMIN FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Pause the contract
     */
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        if (paused) revert("Pausable: already paused");

        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract
     */
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        if (!paused) revert("Pausable: not paused");

        paused = false;
        emit Unpaused(msg.sender);
    }

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
    //------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Authorize contract upgrades
     */
    function _authorizeUpgrade(address /* newImplementation */) internal view override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    /**
     * @notice Check if contract is not paused
     */
    function _requireNotPaused() internal view {
        if (paused) revert ContractPaused();
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }
}
