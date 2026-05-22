// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/CountersUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/utils/cryptography/ECDSAUpgradeable.sol";

import "./interfaces/IeETH.sol";
import "./interfaces/ILiquidityPool.sol";
import "./AssetRecovery.sol";
import "./utils/RolesLibrary.sol";
import "./interfaces/IBlacklister.sol";
import "./interfaces/IEtherFiRateLimiter.sol";
import "./libraries/RateLimitMath.sol";
import "./utils/PausableUntil.sol";

contract EETH is IERC20Upgradeable, UUPSUpgradeable, OwnableUpgradeable, PausableUntil, IERC20PermitUpgradeable, IeETH, AssetRecovery, RolesLibrary {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    ILiquidityPool private DEPRECATED_liquidityPool;

    uint256 public totalShares;
    mapping (address => uint256) public shares;
    mapping (address => mapping (address => uint256)) public allowances;
    mapping (address => CountersUpgradeable.Counter) private _nonces;
    bool public paused;

    bytes32 private constant _PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

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
    IEtherFiRateLimiter public immutable rateLimiter;

    bytes32 public constant EETH_MINT_LIMIT_ID = keccak256("EETH_MINT_LIMIT_ID");
    bytes32 public constant EETH_BURN_LIMIT_ID = keccak256("EETH_BURN_LIMIT_ID");
    bytes32 public constant EETH_TRANSFER_LIMIT_ID = keccak256("EETH_TRANSFER_LIMIT_ID");

    event Paused();
    event Unpaused();
    event TransferShares( address indexed from, address indexed to, uint256 sharesValue);

    error AddressZero();
    error IncorrectCaller();
    error BurnAmountExceedsBalance();
    error AllowanceBelowZero();
    error TransferAmountExceedsAllowance();
    error ExpiredDeadline();
    error InvalidSignature();
    error TransferAmountExceedsBalance();
    error ContractPaused();

    constructor(address _liquidityPool, address _roleRegistry, address _blacklister, address _rateLimiter) RolesLibrary(_roleRegistry) {
        bytes32 hashedName = keccak256("EETH");
        bytes32 hashedVersion = keccak256("1");
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(typeHash, hashedName, hashedVersion);
        _CACHED_THIS = address(this);
        _TYPE_HASH = typeHash;

        if (_liquidityPool == address(0) || _roleRegistry == address(0) || _blacklister == address(0)) revert AddressZero();
        liquidityPool = ILiquidityPool(_liquidityPool);
        blacklister = IBlacklister(_blacklister);
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);

        _disableInitializers(); 
    }

    function initialize(address _liquidityPool) external initializer {
        if (_liquidityPool == address(0)) revert AddressZero();

        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    function mintShares(address _user, uint256 _share) external onlyPoolContract whenNotPaused {
        blacklister.nonBlacklisted(_user);
        shares[_user] += _share;
        totalShares += _share;

        uint256 amount = liquidityPool.amountForShare(_share);
        rateLimiter.consumeIfConfigured(EETH_MINT_LIMIT_ID, RateLimitMath.toBucketUnit(amount));

        emit Transfer(address(0), _user, amount);
        emit TransferShares(address(0), _user, _share);
    }

    function burnShares(address _user, uint256 _share) external whenNotPaused {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        blacklister.nonBlacklisted(_user);
        if (shares[_user] < _share) revert BurnAmountExceedsBalance();
        shares[_user] -= _share;
        totalShares -= _share;

        uint256 amount = liquidityPool.amountForShare(_share);
        rateLimiter.consumeIfConfigured(EETH_BURN_LIMIT_ID, RateLimitMath.toBucketUnit(amount));

        emit Transfer(_user, address(0), amount);
        emit TransferShares(_user, address(0), _share);
    }

    function transfer(address _recipient, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) public view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function increaseAllowance(address _spender, uint256 _increaseAmount) external returns (bool) {
        address owner = msg.sender;
        uint256 currentAllowance = allowance(owner, _spender);
        _approve(owner, _spender,currentAllowance + _increaseAmount);
        return true;
    }

    function decreaseAllowance(address _spender, uint256 _decreaseAmount) external returns (bool) {
        address owner = msg.sender;
        uint256 currentAllowance = allowance(owner, _spender);
        if (currentAllowance < _decreaseAmount) revert AllowanceBelowZero();
        unchecked {
            _approve(owner, _spender, currentAllowance - _decreaseAmount);
        }
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override(IeETH, IERC20Upgradeable) returns (bool) {
        uint256 currentAllowance = allowances[_sender][msg.sender];
        if (currentAllowance < _amount) revert TransferAmountExceedsAllowance();
        unchecked {
            _approve(_sender, msg.sender, currentAllowance - _amount);
        }
        _transfer(_sender, _recipient, _amount);
        return true;
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

    function recoverETH(address payable to, uint256 amount) external onlyAdmin {
        _recoverETH(to, amount);
    }

    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin{
        _recoverERC20(token, to, amount);
    }

    function recoverERC721(address token, address to, uint256 tokenId) external onlyAdmin {
        _recoverERC721(token, to, tokenId);
    }

    // [INTERNAL FUNCTIONS]
    function _transfer(address _sender, address _recipient, uint256 _amount) internal {
        rateLimiter.consumeIfConfigured(EETH_TRANSFER_LIMIT_ID, RateLimitMath.toBucketUnit(_amount));
        uint256 _sharesToTransfer = liquidityPool.sharesForAmount(_amount);
        _transferShares(_sender, _recipient, _sharesToTransfer);
        emit Transfer(_sender, _recipient, _amount);
    }

    function _approve(address _owner, address _spender, uint256 _amount) internal {
        if (_owner == address(0) || _spender == address(0)) revert AddressZero();

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    function _transferShares(address _sender, address _recipient, uint256 _sharesAmount) internal whenNotPaused{
        blacklister.nonBlacklisted(_sender);
        blacklister.nonBlacklisted(_recipient);
        blacklister.nonBlacklisted(msg.sender);
        if (_sender == address(0) || _recipient == address(0)) revert AddressZero();
        if (_sharesAmount > shares[_sender]) revert TransferAmountExceedsBalance();

        shares[_sender] -= _sharesAmount;
        shares[_recipient] += _sharesAmount;

        emit TransferShares(_sender, _recipient, _sharesAmount);
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal view override {
        _onlyProtocolUpgrader();
    }

    function _useNonce(address owner) internal virtual returns (uint256 current) {
        CountersUpgradeable.Counter storage nonce = _nonces[owner];
        current = nonce.current();
        nonce.increment();
    }

    // [GETTERS]
    function name() public pure returns (string memory) { return "ether.fi ETH"; }
    function symbol() public pure returns (string memory) { return "eETH"; }
    function decimals() public pure returns (uint8) { return 18; }

    function totalSupply() public view returns (uint256) {
        return liquidityPool.getTotalPooledEther();
    }

    function balanceOf(address _user) public view override(IeETH, IERC20Upgradeable) returns (uint256) {
        return liquidityPool.getTotalEtherClaimOf(_user);
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function nonces(address owner) public view virtual override returns (uint256) {
        return _nonces[owner].current();
    }

    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function _buildDomainSeparator(
        bytes32 typeHash,
        bytes32 nameHash,
        bytes32 versionHash
    ) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
    }

    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return ECDSAUpgradeable.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    // [MODIFIERS]
    modifier onlyPoolContract() {
        if (msg.sender != address(liquidityPool)) revert IncorrectCaller();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _requireNotPausedUntil();
        _;
    }
}
