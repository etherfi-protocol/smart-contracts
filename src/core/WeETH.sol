// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/governance/rate-limiting/interfaces/IRateProvider.sol";

import "@etherfi/utils/AssetRecovery.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";

contract WeETH is ERC20Upgradeable, UUPSUpgradeable, DeprecatedOZOwnable, PausableUntil, ERC20PermitUpgradeable, IRateProvider, AssetRecovery {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STORAGE  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slots
    uint160 private __gap_0;
    uint160 private __gap_1;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  ---------------------------------------
    //--------------------------------------------------------------------------------------
    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IBlacklister public immutable blacklister;

    //--------------------------------------------------------------------------------------
    //---------------------------------  ERRORS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    error ZeroAmount();
    error ZeroAddress();
    error CannotRecoverEETH();
    error WeETHUnderbacked(uint256 weETHSupply, uint256 proxyShares);

    //--------------------------------------------------------------------------------------
    //----------------------------------  CONSTRUCTOR  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor for WeETH contract
     * @param _eETH The address of the eETH contract
     * @param _liquidityPool The address of the liquidity pool contract
     * @param _roleRegistry The address of the role registry contract
     * @param _blacklister The address of the blacklister contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _eETH, address _liquidityPool, address _roleRegistry, address _blacklister)
        RolesLibrary(_roleRegistry)
    {
        if(_eETH == address(0) || _liquidityPool == address(0) || _blacklister == address(0)) revert ZeroAddress();
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        blacklister = IBlacklister(_blacklister);
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  INITIALIZERS  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the WeETH contract
     */
    function initialize() external initializer {
        __ERC20_init("Wrapped eETH", "weETH");
        __ERC20Permit_init("Wrapped eETH");
        __UUPSUpgradeable_init();
    }

    /// @dev name changed from the version initially deployed
    function name() public view virtual override returns (string memory) {
        return "Wrapped eETH";
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------  WRAP/UNWRAP FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Wraps eEth
     * @param _eETHAmount the amount of eEth to wrap
     * @return returns the amount of weEth the user receives
     * @dev Order is deposit-then-mint:
     *      1. Pull eETH from user → proxy. eETH.shares(proxy) increases by
     *         sharesForAmount(_eETHAmount).
     *      2. _mint(weETH) increases weETH.totalSupply by the same number.
     *         The `_afterTokenTransfer` hook runs at the end of _mint and
     *         asserts the backing invariant
     *         (weETH.totalSupply <= eETH.shares(proxy)); the deposit-first
     *         ordering means the proxy's share balance is already raised
     *         when the check fires, so the invariant holds with equality.
     */
    function wrap(uint256 _eETHAmount) public returns (uint256) {
        if (_eETHAmount == 0) revert ZeroAmount();
        uint256 weEthAmount = liquidityPool.sharesForAmount(_eETHAmount);
        IERC20(address(eETH)).safeTransferFrom(msg.sender, address(this), _eETHAmount);
        _mint(msg.sender, weEthAmount);
        return weEthAmount;
    }

    /**
     * @notice Wraps eEth with PermitInput struct so user does not have to call approve on eeth contract
     * @param _eETHAmount the amount of eEth to wrap
     * @param _permit the PermitInput struct
     * @return returns the amount of weEth the user receives
     */
    function wrapWithPermit(uint256 _eETHAmount, ILiquidityPool.PermitInput calldata _permit)
        external
        returns (uint256)
    {
        try eETH.permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s) {} catch {}
        return wrap(_eETHAmount);
    }

    /**
     * @notice Unwraps weETH
     * @param _weETHAmount the amount of weETH to unwrap
     * @return returns the amount of eEth the user receives
     */
    function unwrap(uint256 _weETHAmount) external returns (uint256) {
        if (_weETHAmount == 0) revert ZeroAmount();
        uint256 eETHAmount = liquidityPool.amountForShare(_weETHAmount);
        _burn(msg.sender, _weETHAmount);
        IERC20(address(eETH)).safeTransfer(msg.sender, eETHAmount);
        return eETHAmount;
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  PAUSING FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Pauses the contract until the pauseUntilDuration
     * @dev Overrides {PausableUntil-pauseUntil} to require the stricter super guardian role
     *      for weETH token-transfer pausing
     */
    function pauseUntil() external override onlySuperGuardian {
        _pauseUntil();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  RECOVERY FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Recover ETH from the contract
     * @param to The address to recover the ETH to
     * @param amount The amount of ETH to recover
     * @dev Only callable by the admin
     */
    function recoverETH(address payable to, uint256 amount) external onlyOperatingTimelock {
        _recoverETH(to, amount);
    }

    /**
     * @notice Recover ERC20 tokens from the contract
     * @param token The address of the ERC20 token
     * @param to The address to recover the tokens to
     * @param amount The amount of tokens to recover
     * @dev Only callable by the admin
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyOperatingTimelock {
        if (token == address(eETH)) revert CannotRecoverEETH();
        _recoverERC20(token, to, amount);
    }

    /**
     * @notice Recover ERC721 tokens from the contract
     * @param token The address of the ERC721 token
     * @param to The address to recover the tokens to
     * @param tokenId The ID of the token to recover
     * @dev Only callable by the admin
     */
    function recoverERC721(address token, address to, uint256 tokenId) external onlyOperatingTimelock {
        _recoverERC721(token, to, tokenId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Before token transfer
     * @param from The address of the from
     * @param to The address of the to
     * @param amount The amount of the transfer
     * @dev Only callable when the contract is not paused
     * Only callable when the from is not blacklisted
     * Only callable when the to is not blacklisted
     * Only callable when the sender is not blacklisted
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override whenNotPaused {
        blacklister.nonBlacklisted(from);
        blacklister.nonBlacklisted(to);
        blacklister.nonBlacklisted(msg.sender);
    }

    /**
     * @notice Invariant — weETH supply is at-least-fully-backed by eETH shares
     * @param from The address of the from
     * @param to The address of the to
     * @dev Invariant — weETH supply is at-least-fully-backed by eETH shares
     * `weETH.totalSupply <= eETH.shares(address(this))`. Runs after
     * every mint/burn (skipped on transfers — they don't change
     * totalSupply). The `<=` form permits benign over-collateralization
     * from accidental eETH transfers to the proxy.
     *
     * Why this holds today:
     *           wrap(X eETH) → safeTransferFrom moves sharesForAmount(X)
     *           eETH shares to the proxy AND _mint adds sharesForAmount(X)
     *           weETH supply. Both sides increment by the same number.
     *           unwrap is the symmetric decrement (_burn first, then
     *           transfer eETH out — the invariant trivially holds at the
     *           hook because supply just dropped and proxy balance is
     *           still high).
     *
     * What it catches:
     *           Any future code path that mints weETH without pulling in
     *           proportional eETH shares (bridge integration, new mint
     *           authority, exploited path) trips the revert.
     *
     */
    function _afterTokenTransfer(address from, address to, uint256 /*amount*/) internal virtual override {
        if (from != address(0) && to != address(0)) return;     // transfers don't change supply
        uint256 supply = totalSupply();
        uint256 proxyShares = eETH.shares(address(this));
        if (supply > proxyShares) revert WeETHUnderbacked(supply, proxyShares);
    }

    /**
     * @notice Authorizes the upgrade of the contract
     * @param newImplementation The new implementation address
     * @dev Only callable by the upgrade timelock
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTERS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    /**
     * @notice Fetches the amount of weEth respective to the amount of eEth sent in
     * @param _eETHAmount amount sent in
     * @return The total number of shares for the specified amount
     */
    function getWeETHByeETH(uint256 _eETHAmount) external view returns (uint256) {
        return liquidityPool.sharesForAmount(_eETHAmount);
    }

    /**
     * @notice Fetches the amount of eEth respective to the amount of weEth sent in
     * @param _weETHAmount amount sent in
     * @return The total amount for the number of shares sent in
     */
    function getEETHByWeETH(uint256 _weETHAmount) public view returns (uint256) {
        return liquidityPool.amountForShare(_weETHAmount);
    }

    /**
     * @notice Fetches the amount of eETH for 1 weETH
     * @return The amount of eETH for 1 weETH
     */
    function getRate() external view returns (uint256) {
        return getEETHByWeETH(1 ether);
    }

    /**
     * @notice Fetches the implementation address
     * @return The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
