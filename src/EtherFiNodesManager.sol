// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./interfaces/IAuctionManager.sol";
import "./eigenlayer-interfaces/IEigenPod.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IProtocolRevenueManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/IRoleRegistry.sol";
import "lib/BucketLimiter.sol";

contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{

    address public immutable stakingManager;
    IRoleRegistry public immutable roleRegistry;

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------

    LegacyNodesManagerState private legacyState;
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls; // Call Forwarding: functionSelector -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls; // Call Forwarding: functionSelector -> targetAddress -> allowed
    mapping(bytes32 => IEtherFiNode) public etherFiNodeFromPubkeyHash;
    BucketLimiter.Limit public exitRequestsLimit; // Exit requests are measured in "units" == number of validator requests
    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE = keccak256("ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE");

    //-------------------------------------------------------------------------
    //-----------------------------  Admin  -----------------------------------
    //-------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _stakingManager, address _roleRegistry) {
        stakingManager = _stakingManager;
        roleRegistry = IRoleRegistry(_roleRegistry);

        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }

    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    function __initRateLimiter() internal {
        exitRequestsLimit = BucketLimiter.create(uint64(100), uint64(1));
    }

    /// @dev under normal conditions ETH should not accumulate in the EtherFiNode. This will forward
    ///   the eth to the liquidity pool in the event of ETH being accidentally sent there
    function sweepFunds(uint256 id) external onlyAdmin whenNotPaused {
        uint256 balance = IEtherFiNode(etherfiNodeAddress(id)).sweepFunds();
        if(balance > 0) {
            emit FundsTransferred(etherfiNodeAddress(id), balance);
        }
    }

    //--------------------------------------------------------------------------------------
    //---------------------------- Eigenlayer Interactions  --------------------------------
    //--------------------------------------------------------------------------------------

    // Note that most of these calls are pod-level actions and it is a little awkward to always
    // provide a specific validator ID. This is to maintain compatibility with much of our existing
    // tooling which used to operate on a per-validator level instead of per-pod/per-node.
    // Over time we will migrate to directly calling the associated method on the EtherFiNode contract where applicable.

    function getEigenPod(uint256 id) public view returns (address) {
        return address(IEtherFiNode(etherfiNodeAddress(id)).getEigenPod());
    }

    function startCheckpoint(uint256 id) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).startCheckpoint();
    }

    /**
     * @notice Forwards EIP-7002 withdrawal requests to the EigenPod, supporting single or batch requests.
     * @dev Access: only addresses with ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE.
     * @dev Pausable + nonReentrant for safety.
     * @param pod The EigenPod address that owns the validators.
     * @param requests An array of WithdrawalRequest, where:
     *        - requests[i].pubkey is the 48-byte BLS pubkey
     *        - requests[i].amountGwei == 0 means "full exit"; >0 means partial to pod
     * @custom:fee You MUST send sufficient ETH in msg.value to cover the EIP-7002 predeploy fee
     *             for ALL requests in this batch (fee updates per block). Overpay is okay.
     */
    function batchWithdrawalRequests(
        address pod,
        IEigenPod.WithdrawalRequest[] calldata requests
    ) external payable whenNotPaused nonReentrant
    {
        // ---------- checks ----------
        if (pod == address(0)) revert UnknownNode();
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, msg.sender)) revert IncorrectRole();
        uint256 n = requests.length;
        if (n == 0) revert EmptyWithdrawalsRequest();

        // Rate-limit by number of validator requests
        uint64 units = SafeCast.toUint64(n);
        bool ok = BucketLimiter.consume(exitRequestsLimit, units);
        if (!ok) revert ExitRateLimitExceeded();

        // Strict pubkey length check to avoid wasting fee on malformed requests.
        for (uint256 i = 0; i < n; ) {
            bytes memory pubkey = requests[i].pubkey;
            // Compute the pubkey hash
            bytes32 pubkeyHash = keccak256(pubkey);

            // Ensure the node exists for this pubkey hash
            if (address(etherFiNodeFromPubkeyHash[pubkeyHash]) == address(0)) {
                revert UnknownNode();
            }

            unchecked { ++i; }
        }   

        // Ensure enough fee is sent *at the time of execution*.
        // NOTE: The predeploy updates per block; callers should slightly overpay.
        uint256 feePer = IEigenPod(pod).getWithdrawalRequestFee();
        // unchecked mul; we already ensure n>0 and feePer is bounded by protocol economics.
        uint256 required = feePer * n;
        if (msg.value < required) revert InsufficientWithdrawalFees();

        // ---------- interactions ----------
        // Forward full msg.value to tolerate fee update between the view and the call.
        // If predeploy accepts >= required and internally refunds/credits excess, that's fine.
        IEigenPod(pod).requestWithdrawal{value: msg.value}(requests);

        emit BatchWithdrawalRequestsForwarded(msg.sender, pod, n, msg.value);
    }

    function setExitRequestCapacity(uint256 capacity) external onlyAdmin() {
        uint64 cap = SafeCast.toUint64(capacity);
        BucketLimiter.setCapacity(exitRequestsLimit, cap);
    }

    function setExitRequestRefillPerSecond(uint256 refillPerSecond) external onlyAdmin() {
        uint64 refill = SafeCast.toUint64(refillPerSecond);
        BucketLimiter.setRefillRate(exitRequestsLimit, refill);
    }

    function canConsumeExitRequests(uint256 numRequests) external view returns (bool) {
        return BucketLimiter.canConsume(exitRequestsLimit, SafeCast.toUint64(numRequests));
    }

    function verifyCheckpointProofs(uint256 id, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).verifyCheckpointProofs(balanceContainerProof, proofs);
    }

    function setProofSubmitter(uint256 id, address proofSubmitter) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).setProofSubmitter(proofSubmitter);
    }

    function queueETHWithdrawal(uint256 id, uint256 amount) external onlyEigenlayerAdmin whenNotPaused returns (bytes32 withdrawalRoot) {
        return IEtherFiNode(etherfiNodeAddress(id)).queueETHWithdrawal(amount);
    }

    function completeQueuedETHWithdrawals(uint256 id, bool receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        uint256 balance = IEtherFiNode(etherfiNodeAddress(id)).completeQueuedETHWithdrawals(receiveAsTokens);
        if(balance > 0) {
            emit FundsTransferred(etherfiNodeAddress(id), balance);
        }
    }

    function queueWithdrawals(uint256 id, IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).queueWithdrawals(params);
    }

    function completeQueuedWithdrawals(uint256 id, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
    }

    //-------------------------------------------------------------------
    //---------------------  Key Management  ----------------------------
    //-------------------------------------------------------------------

    ///@notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != 48) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }

    /// @notice converts a target address to 0x01 withdrawal credential format for a traditional 32eth validator
    function addressToWithdrawalCredentials(address addr) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), bytes11(0x0), addr);
    }

    /// @notice converts a target address to 0x02 withdrawal credential format for a post Pectra compounding validator
    function addressToCompoundingWithdrawalCredentials(address addr) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x02), bytes11(0x0), addr);
    }

    /// @dev associate the provided pubkey with particular EtherFiNode instance.
    function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external whenNotPaused {
        if (msg.sender != address(stakingManager)) revert InvalidCaller();
        bytes32 pubkeyHash = calculateValidatorPubkeyHash(pubkey);
        if (address(etherFiNodeFromPubkeyHash[pubkeyHash]) != address(0)) revert AlreadyLinked();
        if (legacyState.DEPRECATED_etherfiNodeAddress[legacyId] != address(0)) revert AlreadyLinked();

        // link legacyId for now. We can remove this in a future upgrade
        legacyState.DEPRECATED_etherfiNodeAddress[legacyId] = nodeAddress;

        etherFiNodeFromPubkeyHash[pubkeyHash] = IEtherFiNode(nodeAddress);
        emit PubkeyLinked(pubkeyHash, nodeAddress, legacyId, pubkey);
    }

    /// @notice get the etherFiNode instance associated with the provided ID. (Legacy validatorId or pubkeyHash)
    /// @dev Note that this ID can either be a a traditional etherfi validatorID or
    //       a validatorPubkeyHash cast as a uint256. This was done maintaint compatibility
    //       with minimal changes as we migrate from our id system to using pubkey hash instead
    function etherfiNodeAddress(uint256 id) public view returns (address) {
        // if the ID is a legacy validatorID use the old storage array
        // otherwise assume it is a pubkey hash.
        // In a future upgrade we can fully remove the legacy path

        // heuristic that if a pubkey hash, at least 1 bit of higher order bits must be 1
        // all of the legacy id's were incrementing integers that will not have those bits set
        uint256 mask = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000;
        if (mask & id > 0) {
            return address(etherFiNodeFromPubkeyHash[bytes32(id)]);
        } else {
            return legacyState.DEPRECATED_etherfiNodeAddress[id];
        }
    }


    /// @dev this method is for linking our old legacy validator ids that were created before
    ///    we started tracking the pubkeys onchain. We can delete this method once we have linked all of our legacy validators
    function linkLegacyValidatorIds(uint256[] calldata validatorIds, bytes[] calldata pubkeys) external onlyAdmin {
        if (validatorIds.length != pubkeys.length) revert LengthMismatch();
        for (uint256 i = 0; i < validatorIds.length; i++) {

            // lookup which node we are linking against
            address nodeAddress = legacyState.DEPRECATED_etherfiNodeAddress[validatorIds[i]];
            if (nodeAddress == address(0)) revert UnknownNode();

            // ensure we haven't already linked this pubkey
            bytes32 pubkeyHash = calculateValidatorPubkeyHash(pubkeys[i]);
            if (address(etherFiNodeFromPubkeyHash[pubkeyHash]) != address(0)) revert AlreadyLinked();

            etherFiNodeFromPubkeyHash[pubkeyHash] = IEtherFiNode(nodeAddress);
            emit PubkeyLinked(pubkeyHash, nodeAddress, validatorIds[i], pubkeys[i]);
        }
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Update the whitelist for external calls that can be executed by an EtherfiNode
    /// @param selector method selector
    /// @param target call target for forwarded call
    /// @param allowed enable or disable the call
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external onlyAdmin {
        allowedForwardedExternalCalls[selector][target] = allowed;
        emit AllowedForwardedExternalCallsUpdated(selector, target, allowed);
    }

    /// @notice Update the whitelist for external calls that can be executed against the corresponding eigenpod
    /// @param selector method selector
    /// @param allowed enable or disable the call
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external onlyAdmin {
        allowedForwardedEigenpodCalls[selector] = allowed;
        emit AllowedForwardedEigenpodCallsUpdated(selector, allowed);
    }

    /// @notice forward a whitelisted call to a whitelisted external contract with the EtherFiNode as the caller
    function forwardExternalCall(uint256[] calldata ids, bytes[] calldata data, address target) external onlyCallForwarder whenNotPaused returns (bytes[] memory returnData) {
        if (ids.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {

            // call validation + whitelist checks performed in node implementation
            IEtherFiNode node = IEtherFiNode(etherfiNodeAddress(ids[i]));
            returnData[i] = node.forwardExternalCall(target, data[i]);
        }
    }

    /// @notice forward a whitelisted call to the associated eigenPod of the EtherFiNode with the EtherFiNode as the caller.
    ///   This serves to allow us to support minor eigenlayer upgrades without needing to immediately upgrade our contracts.
    function forwardEigenPodCall(uint256[] calldata ids, bytes[] calldata data) external onlyCallForwarder whenNotPaused returns (bytes[] memory returnData) {
        if (ids.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {

            // call validation + whitelist checks performed in node implementation
            IEtherFiNode node = IEtherFiNode(etherfiNodeAddress(ids[i]));
            returnData[i] = node.forwardEigenPodCall(data[i]);
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyAdmin() {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    modifier onlyEigenlayerAdmin() {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

    modifier onlyCallForwarder() {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }
}
