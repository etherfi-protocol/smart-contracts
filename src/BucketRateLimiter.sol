pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "src/interfaces/IRateLimiter.sol";
import "src/interfaces/IRoleRegistry.sol";
import "lib/BucketLimiter.sol";

contract BucketRateLimiter is IRateLimiter, Initializable, PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {

    BucketLimiter.Limit public limit;
    address public consumer;

    mapping(address => bool) public DEPRECATED_admins;
    mapping(address => bool) public DEPRECATED_pausers;

    mapping(address => BucketLimiter.Limit) public limitsPerToken;

    // Immutables are not part of proxy storage; stored in implementation bytecode only.
    IRoleRegistry public immutable roleRegistry;

    bytes32 public constant BUCKET_RATE_LIMITER_ADMIN_ROLE = keccak256("BUCKET_RATE_LIMITER_ADMIN_ROLE");

    error IncorrectRole();

    modifier onlyAdmin() {
        if (!roleRegistry.hasRole(BUCKET_RATE_LIMITER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _roleRegistry) {
        roleRegistry = IRoleRegistry(_roleRegistry);
        _disableInitializers();
    }

    function initialize() external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        limit = BucketLimiter.create(0, 0);
    }

    function updateRateLimit(address sender, address tokenIn, uint256 amountIn, uint256 amountOut) external whenNotPaused {
        require(msg.sender == consumer, "NOT_CONSUMER");
        // Count both 'amountIn' and 'amountOut' as rate limit consumption
        uint64 consumedAmount = SafeCast.toUint64((amountIn + amountOut + 1e12 - 1) / 1e12);
        require(BucketLimiter.consume(limit, consumedAmount), "BucketRateLimiter: rate limit exceeded");
        require(limitsPerToken[tokenIn].lastRefill == 0 || BucketLimiter.consume(limitsPerToken[tokenIn], consumedAmount), "BucketRateLimiter: token rate limit exceeded");
    }

    function canConsume(address tokenIn, uint256 amountIn, uint256 amountOut) external view returns (bool) {
        // Count both 'amountIn' and 'amountOut' as rate limit consumption
        uint64 consumedAmount = SafeCast.toUint64((amountIn + amountOut + 1e12 - 1) / 1e12);
        bool globalConsumable = BucketLimiter.canConsume(limit, consumedAmount);
        bool perTokenConsumable = limitsPerToken[tokenIn].lastRefill == 0 || BucketLimiter.canConsume(limitsPerToken[tokenIn], consumedAmount);
        return globalConsumable && perTokenConsumable;
    }

    function setCapacity(uint256 capacity) external onlyAdmin {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        BucketLimiter.setCapacity(limit, capacity64);
    }

    function setRefillRatePerSecond(uint256 refillRate) external onlyAdmin {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 refillRate64 = SafeCast.toUint64(refillRate / 1e12);
        BucketLimiter.setRefillRate(limit, refillRate64);
    }

    function registerToken(address token, uint256 capacity, uint256 refillRate) external onlyOwner {
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        uint64 refillRate64 = SafeCast.toUint64(refillRate / 1e12);
        limitsPerToken[token] = BucketLimiter.create(capacity64, refillRate64);
    }

    function setCapacityPerToken(address token, uint256 capacity) external onlyOwner {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        BucketLimiter.setCapacity(limitsPerToken[token], capacity64);
    }

    function setRefillRatePerSecondPerToken(address token, uint256 refillRate) external onlyOwner {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 refillRate64 = SafeCast.toUint64(refillRate / 1e12);
        BucketLimiter.setRefillRate(limitsPerToken[token], refillRate64);
    }

    function updateConsumer(address _consumer) external onlyAdmin {
        consumer = _consumer;
    }

    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}