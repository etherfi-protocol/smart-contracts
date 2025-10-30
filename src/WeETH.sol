// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IRateProvider.sol";
import "./interfaces/IeETH.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";

import "./AssetRecovery.sol";
import "./interfaces/IRoleRegistry.sol";

contract WeETH is ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ERC20PermitUpgradeable, IRateProvider, AssetRecovery {
    IRoleRegistry public immutable roleRegistry;

    error IncorrectRole();
    error CannotRecoverEETH();

    //--------------------------------------------------------------------------------------
    //---------------------------------  STORAGE  ----------------------------------
    //--------------------------------------------------------------------------------------

    IeETH public eETH;
    ILiquidityPool public liquidityPool;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant WEETH_OPERATING_ADMIN_ROLE = keccak256("WEETH_OPERATING_ADMIN_ROLE");

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry) {
        require(_roleRegistry != address(0), "must set role registry");
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize(address _liquidityPool, address _eETH) external initializer {
        require(_liquidityPool != address(0), "No zero addresses");
        require(_eETH != address(0), "No zero addresses");

        __ERC20_init("Wrapped eETH", "weETH");
        __ERC20Permit_init("Wrapped eETH");
        __UUPSUpgradeable_init();
        __Ownable_init();
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
    }

    /// @dev name changed from the version initially deployed
    function name() public view virtual override returns (string memory) {
        return "Wrapped eETH";
    }

    /// @notice Wraps eEth
    /// @param _eETHAmount the amount of eEth to wrap
    /// @return returns the amount of weEth the user receives
    function wrap(uint256 _eETHAmount) public returns (uint256) {
        require(_eETHAmount > 0, "weETH: can't wrap zero eETH");
        uint256 weEthAmount = liquidityPool.sharesForAmount(_eETHAmount);
        _mint(msg.sender, weEthAmount);
        eETH.transferFrom(msg.sender, address(this), _eETHAmount);
        return weEthAmount;
    }

    /// @notice Wraps eEth with PermitInput struct so user does not have to call approve on eeth contract
    /// @param _eETHAmount the amount of eEth to wrap
    /// @return returns the amount of weEth the user receives
    function wrapWithPermit(uint256 _eETHAmount, ILiquidityPool.PermitInput calldata _permit) external returns (uint256) {
        try eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return wrap(_eETHAmount);
    }

    /// @notice Unwraps weETH
    /// @param _weETHAmount the amount of weETH to unwrap
    /// @return returns the amount of eEth the user receives
    function unwrap(uint256 _weETHAmount) external returns (uint256) {
        require(_weETHAmount > 0, "Cannot unwrap a zero amount");
        uint256 eETHAmount = liquidityPool.amountForShare(_weETHAmount);
        _burn(msg.sender, _weETHAmount);
        eETH.transfer(msg.sender, eETHAmount);
        return eETHAmount;
    }

    function recoverETH(address payable to, uint256 amount) external {
        if (!roleRegistry.hasRole(WEETH_OPERATING_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _recoverETH(to, amount);
    }

    function recoverERC20(address token, address to, uint256 amount) external {
        if (!roleRegistry.hasRole(WEETH_OPERATING_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        if (token == address(eETH)) revert CannotRecoverEETH();
        _recoverERC20(token, to, amount);
    }

    function recoverERC721(address token, address to, uint256 tokenId) external {
        if (!roleRegistry.hasRole(WEETH_OPERATING_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _recoverERC721(token, to, tokenId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(
        address /* newImplementation */
    )
        internal
        view
        override
    {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Fetches the amount of weEth respective to the amount of eEth sent in
    /// @param _eETHAmount amount sent in
    /// @return The total number of shares for the specified amount
    function getWeETHByeETH(uint256 _eETHAmount) external view returns (uint256) {
        return liquidityPool.sharesForAmount(_eETHAmount);
    }

    /// @notice Fetches the amount of eEth respective to the amount of weEth sent in
    /// @param _weETHAmount amount sent in
    /// @return The total amount for the number of shares sent in
    function getEETHByWeETH(uint256 _weETHAmount) public view returns (uint256) {
        return liquidityPool.amountForShare(_weETHAmount);
    }

    // Amount of eETH for 1 weETH
    function getRate() external view returns (uint256) {
        return getEETHByWeETH(1 ether);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
