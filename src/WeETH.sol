// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IRateProvider.sol";

import "./AssetRecovery.sol";
import "./utils/PausableUntil.sol";
import "./interfaces/IRoleRegistry.sol";
import "./interfaces/IBlacklister.sol";
import "./interfaces/IEtherFiRateLimiter.sol";

contract WeETH is ERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, PausableUntil, ERC20PermitUpgradeable, IRateProvider, AssetRecovery {

    IeETH public immutable eETH;
    ILiquidityPool public immutable liquidityPool;
    IRoleRegistry public immutable roleRegistry;
    IBlacklister public immutable blacklister;
    IEtherFiRateLimiter public immutable rateLimiter;

    bytes32 public constant WEETH_MINT_LIMIT_ID = keccak256("WEETH_MINT_LIMIT_ID");
    bytes32 public constant WEETH_BURN_LIMIT_ID = keccak256("WEETH_BURN_LIMIT_ID");
    bytes32 public constant WEETH_TRANSFER_LIMIT_ID = keccak256("WEETH_TRANSFER_LIMIT_ID");

    event Paused();
    event Unpaused();

    error CannotRecoverEETH();

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
    constructor(address _eETH, address _liquidityPool, address _roleRegistry, address _blacklister, address _rateLimiter) {
        require(_eETH != address(0), "must set eETH");
        require(_liquidityPool != address(0), "must set liquidity pool");
        require(_roleRegistry != address(0), "must set role registry");
        require(_blacklister != address(0), "must set blacklister");
        require(_rateLimiter != address(0), "must set rate limiter");
        eETH = IeETH(_eETH);
        liquidityPool = ILiquidityPool(_liquidityPool);
        roleRegistry = IRoleRegistry(_roleRegistry);
        blacklister = IBlacklister(_blacklister);
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);
        _disableInitializers();
    }

    function initialize(address _liquidityPool, address _eETH) external initializer {
        require(_liquidityPool != address(0), "No zero addresses");
        require(_eETH != address(0), "No zero addresses");

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
        require(_eETHAmount > 0, "weETH: can't wrap zero eETH");
        uint256 weEthAmount = liquidityPool.sharesForAmount(_eETHAmount);
        _consumeIfConfigured(WEETH_MINT_LIMIT_ID, weEthAmount);
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
        _consumeIfConfigured(WEETH_BURN_LIMIT_ID, _weETHAmount);
        _burn(msg.sender, _weETHAmount);
        eETH.transfer(msg.sender, eETHAmount);
        return eETHAmount;
    }

    function pause() external onlyOperations {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyOperations {
        paused = false;
        emit Unpaused();
    }

    function pauseContractUntil() external onlyGuardian {
        _pauseUntil();
    }

    function unpauseContractUntil() external onlyOperations {
        _unpauseUntil();
    }

    function setPauseUntilDuration(uint256 _pauseUntilDuration) external onlyAdmin {
        _setPauseUntilDuration(_pauseUntilDuration);
    }

    function recoverETH(address payable to, uint256 amount) external onlyOperations {
        _recoverETH(to, amount);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyOperations {
        if (token == address(eETH)) revert CannotRecoverEETH();
        _recoverERC20(token, to, amount);
    }

    function recoverERC721(address token, address to, uint256 tokenId) external onlyOperations {
        _recoverERC721(token, to, tokenId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal view override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(!paused, "PAUSED");
        _requireNotPausedUntil();
        blacklister.nonBlacklisted(from);
        blacklister.nonBlacklisted(to);
        blacklister.nonBlacklisted(msg.sender);
        if (from != address(0) && to != address(0)) {
            _consumeIfConfigured(WEETH_TRANSFER_LIMIT_ID, amount);
        }
    }

    /// @dev Consumes from the rate-limiter bucket unless the admin has disabled it
    /// by setting capacity to zero. getLimit() reverts on UnknownLimit, so the bucket
    /// must still be explicitly created — there is no silent-bypass path from forgetting
    /// to deploy the configuration. Note: the rate limiter's global pause is bypassed
    /// when capacity == 0; use the token's own pause mechanism for a hard stop.
    function _consumeIfConfigured(bytes32 id, uint256 amount) internal {
        (uint64 capacity,,,) = rateLimiter.getLimit(id);
        if (capacity == 0) return;
        rateLimiter.consume(id, _toBucketUnit(amount));
    }

    /// @dev Converts a wei amount to the gwei unit consumed by EtherFiRateLimiter (rounding up).
    /// Saturates at type(uint64).max — practical token amounts sit well below this; saturation
    /// makes the limiter consume its max-conservative cap rather than reverting at SafeCast.
    function _toBucketUnit(uint256 amount) internal pure returns (uint64) {
        uint256 gweiAmount = Math.ceilDiv(amount, 1 gwei);
        return gweiAmount > type(uint64).max ? type(uint64).max : uint64(gweiAmount);
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

    modifier onlyAdmin() {
        roleRegistry.onlyOperatingTimelock(msg.sender);
        _;
    }

    modifier onlyOperations() {
        roleRegistry.onlyOperatingMultisig(msg.sender);
        _;
    }

    modifier onlyGuardian() {
        roleRegistry.onlyGuardian(msg.sender);
        _;
    }
}
