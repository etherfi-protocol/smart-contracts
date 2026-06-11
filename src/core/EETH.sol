// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/CountersUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";

import "@etherfi/core/interfaces/IeETH.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";
import "@etherfi/utils/AssetRecovery.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/interfaces/IBlacklister.sol";
import "@etherfi/governance/rate-limiting/RateLimitedToken.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";

contract EETH is IERC20Upgradeable, UUPSUpgradeable, DeprecatedOZOwnable, PausableUntil, IERC20PermitUpgradeable, IeETH, AssetRecovery, RateLimitedToken {
    using CountersUpgradeable for CountersUpgradeable.Counter;

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    // deprecated storage slot
    uint160 private __gap_0;

    uint256 public totalShares;
    mapping (address => uint256) public shares;
    mapping (address => mapping (address => uint256)) public allowances;
    mapping (address => CountersUpgradeable.Counter) private _nonces;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _TYPE_HASH;

    ILiquidityPool public immutable liquidityPool;
    IBlacklister public immutable blacklister;
    // `roleRegistry` is inherited from RolesLibrary; `rateLimiter` from RateLimitedToken.

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTANTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    /// @dev Protocol-wide circuit breakers on supply changes. Mints and burns
    ///      each draw from their own global bucket via `consumeToken`. The global
    ///      cap bounds how much supply can be created or destroyed in a window, so
    ///      a compromised mint/burn path still has to fit inside it. Transfers are
    ///      intentionally NOT rate-limited — they don't change supply.
    bytes32 public constant EETH_MINT_LIMIT_ID = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 public constant EETH_BURN_LIMIT_ID = keccak256("EETH_BURN_LIMIT_ID");

    bytes32 private constant _PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event TransferShares( address indexed from, address indexed to, uint256 sharesValue);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error AddressZero();
    error IncorrectCaller();
    error BurnAmountExceedsBalance();
    error AllowanceBelowZero();
    error TransferAmountExceedsAllowance();
    error ExpiredDeadline();
    error InvalidSignature();
    error TransferAmountExceedsBalance();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor for EETH contract
     * @param _liquidityPool The address of the liquidity pool contract
     * @param _roleRegistry The address of the role registry contract
     * @param _blacklister The address of the blacklister contract
     * @param _rateLimiter The address of the rate limiter contract
     */
    constructor(address _liquidityPool, address _roleRegistry, address _blacklister, address _rateLimiter)
        RolesLibrary(_roleRegistry)
        RateLimitedToken(_rateLimiter)
    {
        bytes32 hashedName = keccak256("EETH");
        bytes32 hashedVersion = keccak256("1");
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(typeHash, hashedName, hashedVersion);
        _CACHED_THIS = address(this);
        _TYPE_HASH = typeHash;

        if (_liquidityPool == address(0) || _blacklister == address(0)) revert AddressZero();
        liquidityPool = ILiquidityPool(_liquidityPool);
        blacklister = IBlacklister(_blacklister);

        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  INITIALIZERS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EETH contract
     */
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  MINT/BURN FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Mint shares to a user
     * @param _user The address of the user to mint shares to
     * @param _share The amount of shares to mint
     * @dev Rate Limited for the global mint bucket
     * Only callable by the liquidity pool contract
     * Only callable when the contract is not paused
     * Only callable when the user is not blacklisted
     */
    function mintShares(address _user, uint256 _share) external onlyPoolContract whenNotPaused {
        blacklister.nonBlacklisted(_user);
        shares[_user] += _share;
        totalShares += _share;

        uint256 amount = liquidityPool.amountForShare(_share);
        rateLimiter.consumeToken(EETH_MINT_LIMIT_ID, toBucketUnit(amount));

        emit Transfer(address(0), _user, amount);
        emit TransferShares(address(0), _user, _share);
    }

    /**
     * @notice Burn shares from a user
     * @param _user The address of the user to burn shares from
     * @param _share The amount of shares to burn
     * @dev Rate Limited for the global burn bucket
     * Only callable by the liquidity pool contract
     * Only callable when the contract is not paused
     * Only callable when the user is not blacklisted
     */
    function burnShares(address _user, uint256 _share) external whenNotPaused {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_user);
        if (shares[_user] < _share) revert BurnAmountExceedsBalance();
        shares[_user] -= _share;
        totalShares -= _share;

        uint256 amount = liquidityPool.amountForShare(_share);
        rateLimiter.consumeToken(EETH_BURN_LIMIT_ID, toBucketUnit(amount));

        emit Transfer(_user, address(0), amount);
        emit TransferShares(_user, address(0), _share);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  ERC20 FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Transfer eETH to a recipient
     * @param _recipient The address of the recipient
     * @param _amount The amount of eETH to transfer
     * @return bool True if the transfer is successful
     */
    function transfer(address _recipient, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    /**
     * @notice Get the allowance for a spender
     * @param _owner The address of the owner
     * @param _spender The address of the spender
     * @return uint256 The allowance
     */
    function allowance(address _owner, address _spender) public view returns (uint256) {
        return allowances[_owner][_spender];
    }

    /**
     * @notice Approve a spender to spend eETH
     * @param _spender The address of the spender
     * @param _amount The amount of eETH to approve
     * @return bool True if the approval is successful
     */
    function approve(address _spender, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    /**
     * @notice Increase the allowance for a spender
     * @param _spender The address of the spender
     * @param _increaseAmount The amount of eETH to increase the allowance by
     * @return bool True if the allowance is increased successfully
     */
    function increaseAllowance(address _spender, uint256 _increaseAmount) external returns (bool) {
        address owner = msg.sender;
        uint256 currentAllowance = allowance(owner, _spender);
        _approve(owner, _spender,currentAllowance + _increaseAmount);
        return true;
    }

    /**
     * @notice Decrease the allowance for a spender
     * @param _spender The address of the spender
     * @param _decreaseAmount The amount of eETH to decrease the allowance by
     * @return bool True if the allowance is decreased successfully
     */
    function decreaseAllowance(address _spender, uint256 _decreaseAmount) external returns (bool) {
        address owner = msg.sender;
        uint256 currentAllowance = allowance(owner, _spender);
        if (currentAllowance < _decreaseAmount) revert AllowanceBelowZero();
        unchecked {
            _approve(owner, _spender, currentAllowance - _decreaseAmount);
        }
        return true;
    }

    /**
     * @notice Transfer eETH from a sender to a recipient
     * @param _sender The address of the sender
     * @param _recipient The address of the recipient
     * @param _amount The amount of eETH to transfer
     * @return bool True if the transfer is successful
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        uint256 currentAllowance = allowances[_sender][msg.sender];
        if (currentAllowance < _amount) revert TransferAmountExceedsAllowance();
        unchecked {
            _approve(_sender, msg.sender, currentAllowance - _amount);
        }
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    /**
     * @notice Permit a spender to spend eETH
     * @param owner The address of the owner
     * @param spender The address of the spender
     * @param value The amount of eETH to permit
     * @param deadline The deadline for the permit
     * @param v The v signature
     * @param r The r signature
     * @param s The s signature
    */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override(IeETH, IERC20PermitUpgradeable) {
        if (block.timestamp > deadline) revert ExpiredDeadline();

        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline));

        bytes32 hash = _hashTypedDataV4(structHash);

        address signer = ECDSAUpgradeable.recover(hash, v, r, s);
        if (signer != owner) revert InvalidSignature();

        _approve(owner, spender, value);
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  PAUSING FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Pauses the contract until the pauseUntilDuration
     * @dev Overrides {PausableUntil-pauseUntil} to require the stricter super guardian role
     *      for eETH token-transfer pausing
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
    function recoverETH(address payable to, uint256 amount) external onlyAdmin {
        _recoverETH(to, amount);
    }

    /**
     * @notice Recover ERC20 tokens from the contract
     * @param token The address of the ERC20 token
     * @param to The address to recover the tokens to
     * @param amount The amount of tokens to recover
     * @dev Only callable by the admin
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin{
        _recoverERC20(token, to, amount);
    }

    /**
     * @notice Recover ERC721 tokens from the contract
     * @param token The address of the ERC721 token
     * @param to The address to recover the tokens to
     * @param tokenId The ID of the token to recover
     * @dev Only callable by the admin
     */
    function recoverERC721(address token, address to, uint256 tokenId) external onlyAdmin {
        _recoverERC721(token, to, tokenId);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ---------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Transfer eETH from a sender to a recipient
     * @param _sender The address of the sender
     * @param _recipient The address of the recipient
     * @param _amount The amount of eETH to transfer
     * @dev Order mirrors `WeETH._beforeTokenTransfer`: pause + blacklist checks
     * run first. Transfers are NOT rate-limited — they don't change supply.
     * Only callable when the contract is not paused
     * Only callable when the sender is not blacklisted
     * Only callable when the recipient is not blacklisted
     */
    function _transfer(address _sender, address _recipient, uint256 _amount) internal whenNotPaused {
        blacklister.nonBlacklisted(_sender);
        blacklister.nonBlacklisted(_recipient);
        blacklister.nonBlacklisted(msg.sender);
        if (_sender == address(0) || _recipient == address(0)) revert AddressZero();

        uint256 _sharesToTransfer = liquidityPool.sharesForAmount(_amount);
        _transferShares(_sender, _recipient, _sharesToTransfer);
        emit Transfer(_sender, _recipient, _amount);
    }

    /**
     * @notice Approve a spender to spend eETH
     * @param _owner The address of the owner
     * @param _spender The address of the spender
     * @param _amount The amount of eETH to approve
     */
    function _approve(address _owner, address _spender, uint256 _amount) internal {
        if (_owner == address(0) || _spender == address(0)) revert AddressZero();

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    /**
     * @notice Transfer shares from a sender to a recipient
     * @param _sender The address of the sender
     * @param _recipient The address of the recipient
     * @param _sharesAmount The amount of shares to transfer
     */
    function _transferShares(address _sender, address _recipient, uint256 _sharesAmount) internal {
        if (_sharesAmount > shares[_sender]) revert TransferAmountExceedsBalance();

        shares[_sender] -= _sharesAmount;
        shares[_recipient] += _sharesAmount;

        emit TransferShares(_sender, _recipient, _sharesAmount);
    }

    /**
     * @notice Use the nonce for the owner
     * @param owner The address of the owner
     * @return current The current nonce
     */
    function _useNonce(address owner) internal virtual returns (uint256 current) {
        CountersUpgradeable.Counter storage nonce = _nonces[owner];
        current = nonce.current();
        nonce.increment();
    }

    /**
     * @notice Build the domain separator
     * @param typeHash The type hash
     * @param nameHash The name hash
     * @param versionHash The version hash
     * @return bytes32 The domain separator
     */
    function _buildDomainSeparator(
        bytes32 typeHash,
        bytes32 nameHash,
        bytes32 versionHash
    ) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }

    /**
     * @notice Hash the typed data
     * @param structHash The struct hash
     * @return bytes32 The hashed typed data
     */
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return ECDSAUpgradeable.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    /**
     * @notice Get the domain separator
     * @return bytes32 The domain separator
     */
    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    /**
     * @notice Authorize the upgrade
     * @param newImplementation The address of the new implementation
     * @dev Only callable by the upgrade timelock
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //-------------------------------  GETTERS  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the name of the token
     * @return string The name of the token
     */
    function name() public pure returns (string memory) { 
        return "ether.fi ETH"; 
    }

    /**
     * @notice Get the symbol of the token
     * @return string The symbol of the token
     */
    function symbol() public pure returns (string memory) { 
        return "eETH"; 
    }

    /**
     * @notice Get the decimals of the token
     * @return uint8 The decimals of the token
     */
    function decimals() public pure returns (uint8) { 
        return 18; 
    }

    /**
     * @notice Get the total supply of the token
     * @return uint256 The total supply of the token
     */
    function totalSupply() public view returns (uint256) {
        return liquidityPool.getTotalPooledEther();
    }

    /**
     * @notice Get the balance of a user
     * @param _user The address of the user
     * @return uint256 The balance of the user
     */
    function balanceOf(address _user) public view override(IeETH, IERC20Upgradeable) returns (uint256) {
        return liquidityPool.getTotalEtherClaimOf(_user);
    }

    /**
     * @notice Get the implementation address
     * @return address The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    /**
     * @notice Get the nonce for an owner
     * @param owner The address of the owner
     * @return uint256 The nonce for the owner
     */
    function nonces(address owner) public view virtual override returns (uint256) {
        return _nonces[owner].current();
    }

    /**
     * @notice Get the domain separator
     * @return bytes32 The domain separator
     */
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  MODIFIERS  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Modifier to check if the caller is the liquidity pool contract
     * @dev Only callable by the liquidity pool contract
     */
    modifier onlyPoolContract() {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        _;
    }
}
