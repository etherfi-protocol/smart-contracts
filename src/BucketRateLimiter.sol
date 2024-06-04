pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "src/interfaces/IRateLimiter.sol";
import "lib/BucketLimiter.sol";

contract BucketRateLimiter is IRateLimiter, Initializable, PausableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {

    BucketLimiter.Limit public limit;
    address public consumer;

    mapping(address => bool) public admins;
    mapping(address => bool) public pausers;

    event UpdatedAdmin(address indexed admin, bool status);
    event UpdatedPauser(address indexed pauser, bool status);

    constructor() {
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

    function updateConsumer(address _consumer) external onlyOwner {
        consumer = _consumer;
    }

    function updateAdmin(address admin, bool status) external onlyOwner {
        admins[admin] = status;
        emit UpdatedAdmin(admin, status);
    }

    function updatePauser(address pauser, bool status) external onlyOwner {
        pausers[pauser] = status;
        emit UpdatedPauser(pauser, status);
    }

    function pauseContract() external {
        require(pausers[msg.sender] || admins[msg.sender] || msg.sender == owner(), "NOT_PAUSER");
        _pause();
    }

    function unPauseContract() external {
        require(admins[msg.sender] || msg.sender == owner(), "NOT_ADMIN");
        _unpause();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

}