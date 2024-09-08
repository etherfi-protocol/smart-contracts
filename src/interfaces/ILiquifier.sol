// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../eigenlayer-interfaces/IStrategyManager.sol";
import "../eigenlayer-interfaces/IStrategy.sol";
import "../eigenlayer-interfaces/IPauserRegistry.sol";

// cbETH-ETH mainnet: 0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A
// wBETH-ETH mainnet: 0xBfAb6FA95E0091ed66058ad493189D2cB29385E6
// stETH-ETH mainnet: 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022
interface ICurvePool {
    function exchange_underlying(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

interface ICurvePoolQuoter1 {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256); // wBETH-ETH, stETH-ETH
}

interface ICurvePoolQuoter2 {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256); // cbETH-ETH
}

// mint forwarder: 0xfae23c30d383DF59D3E031C325a73d454e8721a6
// mainnet: 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704
interface IcbETH is IERC20 {
    function mint(address _to, uint256 _amount) external;
    function exchangeRate() external view returns (uint256 _exchangeRate);
}

// mainnet: 0xa2E3356610840701BDf5611a53974510Ae27E2e1
interface IwBETH is IERC20 {
    function deposit(address referral) payable external;
    function mint(address _to, uint256 _amount) external;
    function exchangeRate() external view returns (uint256 _exchangeRate);
}

// mainnet: 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84
interface ILido is IERC20 {
    function getTotalPooledEther() external view returns (uint256);
    function getTotalShares() external view returns (uint256);

    function submit(address _referral) external payable returns (uint256);
    function nonces(address _user) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// mainnet: 0x858646372CC42E1A627fcE94aa7A7033e7CF075A
interface IEigenLayerStrategyManager is IStrategyManager {
    function withdrawalRootPending(bytes32 _withdrawalRoot) external view returns (bool);
    function numWithdrawalsQueued(address _user) external view returns (uint96);
    function pauserRegistry() external returns (IPauserRegistry);
    function paused(uint8 index) external view returns (bool);
    function unpause(uint256 newPausedStatus) external;

    // For testing
    function queueWithdrawal( uint256[] calldata strategyIndexes, IStrategy[] calldata strategies, uint256[] calldata shares, address withdrawer, bool undelegateIfPossible ) external returns(bytes32);
}

interface IEigenLayerStrategyTVLLimits is IStrategy {
    function getTVLLimits() external view returns (uint256, uint256);
    function setTVLLimits(uint256 newMaxPerDeposit, uint256 newMaxTotalDeposits) external;
    function pauserRegistry() external returns (IPauserRegistry);
    function paused(uint8 index) external view returns (bool);
    function unpause(uint256 newPausedStatus) external;
}

// mainnet: 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
interface ILidoWithdrawalQueue {
    function FINALIZE_ROLE() external view returns (bytes32);
    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
    function requestWithdrawals(uint256[] calldata _amount, address _depositor) external returns (uint256[] memory);
    function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external;

    function finalize(uint256 _lastRequestIdToBeFinalized, uint256 _maxShareRate) external payable;
    function prefinalize(uint256[] calldata _batches, uint256 _maxShareRate) external view returns (uint256 ethToLock, uint256 sharesToBurn);

    function findCheckpointHints(uint256[] calldata _requestIds, uint256 _firstIndex, uint256 _lastIndex) external view returns (uint256[] memory hintIds);
    function getRoleMember(bytes32 _role, uint256 _index) external view returns (address);
    function getLastRequestId() external view returns (uint256);
    function getLastCheckpointIndex() external view returns (uint256);
}

interface ILiquifier {
    
    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    } 

    struct TokenInfo {
        uint128 strategyShare;
        uint128 ethAmountPendingForWithdrawals;
        IStrategy strategy;
        bool isWhitelisted;
        uint16 discountInBasisPoints;
        uint32 timeBoundCapClockStartTime;
        uint32 timeBoundCapInEther;
        uint32 totalCapInEther;
        uint96 totalDepositedThisPeriod;
        uint96 totalDeposited;
        bool isL2Eth;
    }

    function depositWithAdapter(address _recipient, address _token, uint256 _amount, address _referral) external returns (uint256);        
}
