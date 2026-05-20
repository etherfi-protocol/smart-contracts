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

    error IncorrectCaller();
    error RateLimitExceeded();
    error TokenRateLimitExceeded();

    BucketLimiter.Limit public limit;
    address public consumer;

    mapping(address => bool) private DEPRECATED_admins;
    mapping(address => bool) private DEPRECATED_pausers;

    mapping(address => BucketLimiter.Limit) public limitsPerToken;

    // Immutables are not part of proxy storage; stored in implementation bytecode only.
    IRoleRegistry public immutable roleRegistry;

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
        if (msg.sender != consumer) revert IncorrectCaller();
        // Count both 'amountIn' and 'amountOut' as rate limit consumption
        uint64 consumedAmount = SafeCast.toUint64((amountIn + amountOut + 1e12 - 1) / 1e12);
        if (!BucketLimiter.consume(limit, consumedAmount)) revert RateLimitExceeded();
        if (limitsPerToken[tokenIn].lastRefill != 0 && !BucketLimiter.consume(limitsPerToken[tokenIn], consumedAmount)) revert TokenRateLimitExceeded();
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

    function registerToken(address token, uint256 capacity, uint256 refillRate) external onlyAdmin {
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        uint64 refillRate64 = SafeCast.toUint64(refillRate / 1e12);
        limitsPerToken[token] = BucketLimiter.create(capacity64, refillRate64);
    }

    function setCapacityPerToken(address token, uint256 capacity) external onlyAdmin {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        BucketLimiter.setCapacity(limitsPerToken[token], capacity64);
    }

    function setRefillRatePerSecondPerToken(address token, uint256 refillRate) external onlyAdmin {
        // max refillRate = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether per second, which is practically enough
        uint64 refillRate64 = SafeCast.toUint64(refillRate / 1e12);
        BucketLimiter.setRefillRate(limitsPerToken[token], refillRate64);
    }

    function updateConsumer(address _consumer) external onlyAdmin {
        consumer = _consumer;
    }

    function pauseContract() external onlyOperations {
        _pause();
    }

    function unPauseContract() external onlyOperations {
        _unpause();
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

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
}