// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../interfaces/IEtherFiNode.sol";
import "../eigenlayer-interfaces/IDelegationManager.sol";
import {BeaconChainProofs} from "../eigenlayer-libraries/BeaconChainProofs.sol";

interface IEtherFiNodesManager {

    function addressToWithdrawalCredentials(address addr) external pure returns (bytes memory);
    function addressToCompoundingWithdrawalCredentials(address addr) external pure returns (bytes memory);
    function etherfiNodeAddress(uint256 id) external view returns(address);
    function etherFiNodeFromPubkeyHash(bytes32 pubkeyHash) external view returns (IEtherFiNode);
    function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external;
    function calculateValidatorPubkeyHash(bytes memory pubkey) external pure returns (bytes32);

    function stakingManager() external view returns (address);

    // eigenlayer interactions
    function getEigenPod(uint256 id) external view returns (address);
    function startCheckpoint(uint256 id) external;
    function verifyCheckpointProofs(uint256 id, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external;
    function setProofSubmitter(uint256 id, address newProofSubmitter) external;
    function queueETHWithdrawal(uint256 id, uint256 amount) external returns (bytes32 withdrawalRoot);
    function completeQueuedETHWithdrawals(uint256 id, bool receiveAsTokens) external;
    function queueWithdrawals(uint256 id, IDelegationManager.QueuedWithdrawalParams[] calldata params) external;
    function completeQueuedWithdrawals(uint256 id, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external;
    function sweepFunds(uint256 id) external;

    // unrestaking rate limiting
    function canConsumeUnrestakingCapacity(uint256 amount) external view returns (bool);
    function consumeUnrestakingCapacity(uint256 amount) external;

    // call forwarding
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external;
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external;
    function forwardExternalCall(uint256[] calldata ids, bytes[] calldata data, address target) external returns (bytes[] memory returnData);
    function forwardEigenPodCall(uint256[] calldata ids, bytes[] calldata data) external returns (bytes[] memory returnData);
    function allowedForwardedEigenpodCalls(bytes4 selector) external returns (bool);
    function allowedForwardedExternalCalls(bytes4 selector, address to) external returns (bool);

    // protocol
    function pauseContract() external;
    function unPauseContract() external;

    struct LegacyNodesManagerState {
        uint256[4] legacyPadding1;
        // we are continuing to use this field in the short term before we fully transition to using pubkeyhash
        mapping(uint256 => address) DEPRECATED_etherfiNodeAddress;
        uint256[15] legacyPadding2;
        /*
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | numberOfValidators                        | uint64                                                        | 301  | 0      | 8     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | nonExitPenaltyPrincipal                   | uint64                                                        | 301  | 8      | 8     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | nonExitPenaltyDailyRate                   | uint64                                                        | 301  | 16     | 8     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | SCALE                                     | uint64                                                        | 301  | 24     | 8     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | treasuryContract                          | address                                                       | 302  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | stakingManagerContract                    | address                                                       | 303  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | DEPRECATED_protocolRevenueManagerContract | address                                                       | 304  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | etherfiNodeAddress                        | mapping(uint256 => address)                                   | 305  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | tnft                                      | contract TNFT                                                 | 306  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | bnft                                      | contract BNFT                                                 | 307  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | auctionManager                            | contract IAuctionManager                                      | 308  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | DEPRECATED_protocolRevenueManager         | contract IProtocolRevenueManager                              | 309  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | stakingRewardsSplit                       | struct IEtherFiNodesManager.RewardsSplit                      | 310  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | DEPRECATED_protocolRewardsSplit           | struct IEtherFiNodesManager.RewardsSplit                      | 311  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | DEPRECATED_admin                          | address                                                       | 312  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | admins                                    | mapping(address => bool)                                      | 313  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | eigenPodManager                           | contract IEigenPodManager                                     | 314  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | delayedWithdrawalRouter                   | contract IDelayedWithdrawalRouter                             | 315  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | maxEigenlayerWithdrawals                  | uint8                                                         | 315  | 20     | 1     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | unusedWithdrawalSafes                     | address[]                                                     | 316  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | DEPRECATED_enableNodeRecycling            | bool                                                          | 317  | 0      | 1     | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | validatorInfos                            | mapping(uint256 => struct IEtherFiNodesManager.ValidatorInfo) | 318  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | delegationManager                         | contract IDelegationManager                                   | 319  | 0      | 20    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
            | operatingAdmin                            | mapping(address => bool)                                      | 320  | 0      | 32    | src/EtherFiNodesManager.sol:EtherFiNodesManager |
            |-------------------------------------------+---------------------------------------------------------------+------+--------+-------+-------------------------------------------------|
        */
    }

    //---------------------------------------------------------------------------
    //-----------------------------  Events  -----------------------------------
    //---------------------------------------------------------------------------

    event PubkeyLinked(bytes32 indexed pubkeyHash, address indexed nodeAddress, uint256 indexed legacyId, bytes pubkey);
    event AllowedForwardedExternalCallsUpdated(bytes4 indexed selector, address indexed _target, bool _allowed);
    event AllowedForwardedEigenpodCallsUpdated(bytes4 indexed selector, bool _allowed);
    event FundsTransferred(address indexed nodeAddress, uint256 amount);
    event ValidatorWithdrawalRequestSent(address indexed initiator, address indexed pod, bytes32 indexed validatorPubkeyHash, uint64 amountGwei, uint256 feePerRequest);
    event ValidatorSwitchToCompoundingRequested(address indexed initiator, address indexed pod, bytes32 indexed validatorPubkeyHash, uint256 feePerRequest);
    event ValidatorConsolidationRequested(address indexed initiator, address indexed pod, bytes32 indexed sourcePubkeyHash, bytes32 targetPubkeyHash, uint256 feePerRequest);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error AlreadyLinked();
    error UnknownNode();
    error InvalidPubKeyLength();
    error LengthMismatch();
    error InvalidCaller();
    error IncorrectRole();
    error ForwardedCallNotAllowed();
    error InvalidForwardedCall();
    error EmptyWithdrawalsRequest();
    error EmptyConsolidationRequest();
    error InsufficientWithdrawalFees();
    error InsufficientConsolidationFees();
    error ExitRateLimitExceeded();
    error ExitRateLimitExceededForPod();
    error UnknownValidatorPubkey();
    error UnknownEigenPod();
    error PubkeysMapToDifferentPods();
    error RateLimiterAlreadyInitialized();
}
