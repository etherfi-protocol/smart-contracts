// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IEtherFiRateLimiter {

    // admin
    function updateConsumers(bytes32 id, address consumer, bool allowed) external;
    function createNewLimiter(bytes32 id, uint64 capacity, uint64 refillRate) external;
    function setCapacity(bytes32 id, uint64 capacity) external;
    function setRefillRate(bytes32 id, uint64 refillRate) external;
    function setRemaining(bytes32 id, uint64 remaining) external;

    // core
    function consume(bytes32 id, uint64 amount) external;
    function canConsume(bytes32 id, uint64 amount) external view returns (bool);
    function consumable(bytes32 id) external view returns (uint64);

    // protocol
    function pauseContract() external;
    function unPauseContract() external;

    // view functions
    function getLimit(bytes32 id) external view returns (uint64 capacity, uint64 remaining, uint64 refillRate, uint256 lastRefill);
    function isConsumerAllowed(bytes32 id, address consumer) external view returns (bool);
    function limitExists(bytes32 id) external view returns (bool);


    //---------------------------------------------------------------------------
    //-----------------------------  Events  -----------------------------------
    //---------------------------------------------------------------------------
    event LimiterCreated(bytes32 indexed id, uint256 capacity, uint256 refillRate);
    event CapacityUpdated(bytes32 indexed id, uint256 capacity);
    event RefillRateUpdated(bytes32 indexed id, uint256 refillRate);
    event RemainingUpdated(bytes32 indexed id, uint256 remaining);
    event ConsumerUpdated(bytes32 indexed id, address indexed consumer, bool allowed);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------
    error IncorrectRole();
    error InvalidConsumer();
    error LimitAlreadyExists();
    error LimitExceeded();
    error UnknownLimit();
}