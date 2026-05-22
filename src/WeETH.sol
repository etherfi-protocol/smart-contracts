// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IRateProvider.sol";

import "./AssetRecovery.sol";
import "./interfaces/IBlacklister.sol";
import "./utils/PausableUntil.sol";
import "./utils/RolesLibrary.sol";
import "./utils/RateLimitedToken.sol";

contract WeETH is ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, PausableUntil, ERC20PermitUpgradeable, IRateProvider, AssetRecovery, RolesLibrary, RateLimitedToken {
    using SafeERC20 for IERC20;

    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IBlacklister public immutable blacklister;
    // `roleRegistry` is inherited from RolesLibrary; `rateLimiter` from RateLimitedToken.

    event Paused();
    event Unpaused();

    error CannotRecoverEETH();
    error AddressZero();
    error ZeroAmount();
    error ContractPaused();

    //--------------------------------------------------------------------------------------
    //---------------------------------  STORAGE  ----------------------------------
    //--------------------------------------------------------------------------------------

    IeETH private DEPRECATED_eETH;
    ILiquidityPool private DEPRECATED_liquidityPool;
    bool public paused;

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _eETH, address _liquidityPool, address _roleRegistry, address _blacklister, address _rateLimiter)
        RolesLibrary(_roleRegistry)
        RateLimitedToken(_rateLimiter)
    {
        if(_eETH == address(0) || _liquidityPool == address(0) || _blacklister == address(0) || _rateLimiter == address(0)) revert AddressZero();
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        blacklister = IBlacklister(_blacklister);
        _disableInitializers();
    }

    function initialize(address _liquidityPool, address _eETH) external initializer {
        if (_liquidityPool == address(0) || _eETH == address(0)) revert AddressZero();

        __ERC20_init("Wrapped eETH", "weETH");
        __ERC20Permit_init("Wrapped eETH");
        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    /// @dev name changed from the version initially deployed
    function name() public view virtual override returns (string memory) {
        return "Wrapped eETH";
    }

    /// @notice Wraps eEth
    /// @param _eETHAmount the amount of eEth to wrap
    /// @return returns the amount of weEth the user receives
    function wrap(uint256 _eETHAmount) public returns (uint256) {
        if (_eETHAmount == 0) revert ZeroAmount();
        uint256 weEthAmount = liquidityPool.sharesForAmount(_eETHAmount);
        _mint(msg.sender, weEthAmount);
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), _eETHAmount);
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
        if (_weETHAmount == 0) revert ZeroAmount();
        uint256 eETHAmount = liquidityPool.amountForShare(_weETHAmount);
        _burn(msg.sender, _weETHAmount);
        IERC20(address(eETH)).safeTransfer(msg.sender, eETHAmount);
        return eETHAmount;
    }

    //--------------------------------------------------------------------------------------
    //----------------------  PER-ADDRESS RATE LIMIT MANAGEMENT  ---------------------------
    //--------------------------------------------------------------------------------------
    // Thin role-gated wrappers around the internal helpers in RateLimitedToken.
    // For a single user, pass a length-1 array.

    function tightenAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) external onlyGuardian {
        _tightenAddressRateLimits(users, capacities, refillRates);
    }

    function setAddressRateLimits(
        address[] calldata users,
        uint64[] calldata capacities,
        uint64[] calldata refillRates
    ) external onlyOperatingMultisig {
        _setAddressRateLimits(users, capacities, refillRates);
    }

    function deleteAddressRateLimits(address[] calldata users) external onlyOperatingMultisig {
        _deleteAddressRateLimits(users);
    }

    function pause() external onlyOperatingMultisig {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOperatingMultisig {
        paused = false;
        emit Unpaused();
    }

    function pauseContractUntil() external onlySuperGuardian {
        _pauseUntil();
    }

    function unpauseContractUntil() external onlyOperatingMultisig {
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    function recoverETH(address payable to, uint256 amount) external onlyAdmin {
        _recoverETH(to, amount);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        if (token == address(eETH)) revert CannotRecoverEETH();
        _recoverERC20(token, to, amount);
    }

    function recoverERC721(address token, address to, uint256 tokenId) external onlyAdmin {
        _recoverERC721(token, to, tokenId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        if (paused) revert ContractPaused();
        _requireNotPausedUntil();
        blacklister.nonBlacklisted(from);
        blacklister.nonBlacklisted(to);
        blacklister.nonBlacklisted(msg.sender);
        uint64 amt = toBucketUnit(amount);
        if (from != address(0)) rateLimiter.consumeForAddressIfConfigured(from, amt);
        if (to   != address(0)) rateLimiter.consumeForAddressIfConfigured(to,   amt);
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
    // Role modifiers (`onlyAdmin`, `onlyOperatingMultisig`, `onlyGuardian`, `onlySuperGuardian`,
    // `onlyUpgradeTimelock`, ...) are inherited from RolesLibrary.
}
