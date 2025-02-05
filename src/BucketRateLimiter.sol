pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "src/interfaces/IPausable.sol";
import "src/interfaces/IRateLimiter.sol";
import "lib/BucketLimiter.sol";
import "./RoleRegistry.sol";

contract BucketRateLimiter is IRateLimiter, IPausable, Initializable, PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {

    BucketLimiter.Limit public limit;
    address public consumer;

    mapping(address => BucketLimiter.Limit) public limitsPerToken;

    RoleRegistry public roleRegistry; 

    event UpdatedAdmin(address indexed admin, bool status);
    event UpdatedPauser(address indexed pauser, bool status);

    error IncorrectRole();

    constructor() {
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        limit = BucketLimiter.create(0, 0);
        roleRegistry = RoleRegistry(_roleRegistry);
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

    function setCapacity(uint256 capacity) external onlyOwner {
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 ether, which is practically enough
        uint64 capacity64 = SafeCast.toUint64(capacity / 1e12);
        BucketLimiter.setCapacity(limit, capacity64);
    }

    function setRefillRatePerSecond(uint256 refillRate) external onlyOwner {
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

    function updateConsumer(address _consumer) external onlyOwner {
        consumer = _consumer;
    }

    // Pauses the contract
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    // Unpauses the contract
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}
