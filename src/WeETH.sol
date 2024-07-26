// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IRateProvider.sol";

contract WeETH is ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, ERC20PermitUpgradeable, IRateProvider {
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    IeETH public eETH;
    ILiquidityPool public liquidityPool;

    mapping (address => bool) public whitelistedSpender;
    mapping (address => bool) public blacklistedRecipient;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with the specified liquidity pool and eETH addresses
    /// @param _liquidityPool The address of the liquidity pool
    /// @param _eETH The address of the eETH contract
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
    function wrapWithPermit(uint256 _eETHAmount, ILiquidityPool.PermitInput calldata _permit)
        external
        returns (uint256)
    {
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

    /// @notice Requires the spender to be whitelisted before calling {ERC20PermitUpgradeable-permit}
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(whitelistedSpender[spender], "weETH: spender not whitelisted"); 
    
        super.permit(owner, spender, value, deadline, v, r, s);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Authorizes the upgrade of the contract to a new implementation by the owner
    /// @param newImplementation The address of the new contract implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}


    /// @notice Require the recipient to not be blacklisted before calling {ERC20Upgradeable-_transfer}
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(!blacklistedRecipient[from] && !blacklistedRecipient[to], "weETH: blacklisted address");
        super._transfer(from, to, amount);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  SETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sets the whitelisted status for a list of addresses
    /// @param _spenders An array of spender addresses
    /// @param _isWhitelisted Boolean value to set the whitelisted status
    function setWhitelistedSpender(address[] calldata _spenders, bool _isWhitelisted) external onlyOwner {
        for (uint i = 0; i < _spenders.length; i++) {
            whitelistedSpender[_spenders[i]] = _isWhitelisted;
        }
    }

    /// @notice Sets the blacklisted status for a list of addresses
    /// @param _recipients An array of recipient addresses
    /// @param _isBlacklisted Boolean value to set the blacklisted status
    function setBlacklistedRecipient(address[] calldata _recipients, bool _isBlacklisted) external onlyOwner {
        for (uint i = 0; i < _recipients.length; i++) {
            blacklistedRecipient[_recipients[i]] = _isBlacklisted;
        }
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

    /// @notice Fetches the exchange rate of eETH for 1 weETH
    /// @return The amount of eETH for 1 weETH
    function getRate() external view returns (uint256) {
        return getEETHByWeETH(1 ether);
    }

    /// @notice Fetches the address of the current contract implementation
    /// @return The address of the current implementation   
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
