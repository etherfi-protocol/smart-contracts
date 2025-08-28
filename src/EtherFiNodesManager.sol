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
import "./interfaces/IEtherFiRateLimiter.sol";

contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{

    IStakingManager public immutable stakingManager;
    IRoleRegistry public immutable roleRegistry;
    IEtherFiRateLimiter public immutable rateLimiter;
    address public constant BEACON_ETH_STRATEGY_ADDRESS = address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------
    LegacyNodesManagerState private legacyState;
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls; // Call Forwarding: functionSelector -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls; // Call Forwarding: functionSelector -> targetAddress -> allowed
    mapping(bytes32 => IEtherFiNode) public etherFiNodeFromPubkeyHash;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ----------------------------------------
    //--------------------------------------------------------------------------------------
    bytes32 public constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_EIGENLAYER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_POD_PROVER_ROLE = keccak256("ETHERFI_NODES_MANAGER_POD_PROVER_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE = keccak256("ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE");

    //-------------------------------------------------------------------------
    //-----------------------------  Rate Limiter Buckets ---------------------
    //-------------------------------------------------------------------------
    bytes32 public constant UNRESTAKING_LIMIT_ID = keccak256("UNRESTAKING_LIMIT_ID");
    bytes32 public constant EXIT_REQUEST_LIMIT_ID = keccak256("EXIT_REQUEST_LIMIT_ID");
    // maximum exitable balance in gwei
    uint256 public constant FULL_EXIT_GWEI = 2_048_000_000_000;

    //-------------------------------------------------------------------------
    //-----------------------------  Admin  -----------------------------------
    //-------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _stakingManager, address _roleRegistry, address _rateLimiter) {
        stakingManager = IStakingManager(_stakingManager);
        roleRegistry = IRoleRegistry(_roleRegistry);
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);

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

    function createEigenPod(address node) external onlyEigenlayerAdmin whenNotPaused returns (address) {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        return IEtherFiNode(node).createEigenPod();
    }

    function getEigenPod(uint256 id) public view returns (address) {
        return address(IEtherFiNode(etherfiNodeAddress(id)).getEigenPod());
    }
    function getEigenPod(address node) public view returns (address) {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        return address(IEtherFiNode(node).getEigenPod());
    }

    function startCheckpoint(uint256 id) external onlyPodProver whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).startCheckpoint();
    }
    function startCheckpoint(address node) external onlyPodProver whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        IEtherFiNode(node).startCheckpoint();
    }

    function verifyCheckpointProofs(uint256 id, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyPodProver whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).verifyCheckpointProofs(balanceContainerProof, proofs);
    }
    function verifyCheckpointProofs(address node, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyPodProver whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        IEtherFiNode(node).verifyCheckpointProofs(balanceContainerProof, proofs);
    }

    function setProofSubmitter(uint256 id, address proofSubmitter) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).setProofSubmitter(proofSubmitter);
    }
    function setProofSubmitter(address node, address proofSubmitter) external onlyEigenlayerAdmin whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        IEtherFiNode(node).setProofSubmitter(proofSubmitter);
    }

    function queueETHWithdrawal(uint256 id, uint256 amount) external onlyEigenlayerAdmin whenNotPaused returns (bytes32 withdrawalRoot) {
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(amount / 1 gwei));
        return IEtherFiNode(etherfiNodeAddress(id)).queueETHWithdrawal(amount);
    }
    function queueETHWithdrawal(address node, uint256 amount) external onlyEigenlayerAdmin whenNotPaused returns (bytes32 withdrawalRoot) {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(amount / 1 gwei));
        return IEtherFiNode(node).queueETHWithdrawal(amount);
    }

    function completeQueuedETHWithdrawals(uint256 id, bool receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        uint256 balance = IEtherFiNode(etherfiNodeAddress(id)).completeQueuedETHWithdrawals(receiveAsTokens);
        if(balance > 0) {
            emit FundsTransferred(etherfiNodeAddress(id), balance);
        }
    }
    function completeQueuedETHWithdrawals(address node, bool receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        uint256 balance = IEtherFiNode(node).completeQueuedETHWithdrawals(receiveAsTokens);
        if(balance > 0) {
            emit FundsTransferred(node, balance);
        }
    }

    function queueWithdrawals(uint256 id, IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyEigenlayerAdmin whenNotPaused {
        // need to rate limit any beacon eth being withdrawn
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(sumRestakingETHWithdrawals(params) / 1 gwei));
        IEtherFiNode(etherfiNodeAddress(id)).queueWithdrawals(params);
    }
    function queueWithdrawals(address node, IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyEigenlayerAdmin whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();

        // need to rate limit any beacon eth being withdrawn
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(sumRestakingETHWithdrawals(params) / 1 gwei));
        IEtherFiNode(node).queueWithdrawals(params);
    }

    function completeQueuedWithdrawals(uint256 id, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        IEtherFiNode(etherfiNodeAddress(id)).completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
    }
    function completeQueuedWithdrawals(address node, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external onlyEigenlayerAdmin whenNotPaused {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        IEtherFiNode(node).completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
    }

    function sumRestakingETHWithdrawals(IDelegationManager.QueuedWithdrawalParams[] calldata params) internal pure returns (uint256) {
        // Calculate total beaconETH amount for rate limiting - only rate limit beaconETH strategy withdrawals
        uint256 totalBeaconEth = 0;
        for (uint256 i = 0; i < params.length; i++) {
            for (uint256 j = 0; j < params[i].strategies.length; j++) {
                if (params[i].strategies[j] == IStrategy(BEACON_ETH_STRATEGY_ADDRESS)) {
                    totalBeaconEth += params[i].depositShares[j];
                }
            }
        }
        return totalBeaconEth;
    }

    //-------------------------------------------------------------------
    //-------------  Execution-Layer Triggered Withdrawals  -------------
    //-------------------------------------------------------------------
    /**
     * @notice Triggers EIP-7002 withdrawal requests, grouping by EigenPod automatically.
     * @dev associated etherFiNode is derived from pubkey in the request. Caller should ensure
     *      all provided validators share the same eigenpod
     * @dev Access: only ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, pausable, nonReentrant.
     * @param requests Array of WithdrawalRequest:
     *        - pubkey: 48-byte BLS pubkey
     *        - amountGwei: 0 for full exit, >0 for partial to pod
     * @custom:fee Send enough ETH to cover sum of (feePerPod * requestsForPod). Overpay is OK.
     */
    function requestExecutionLayerTriggeredWithdrawal(IEigenPod.WithdrawalRequest[] calldata requests) external payable whenNotPaused nonReentrant {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, msg.sender)) revert IncorrectRole();
        if (requests.length == 0) revert EmptyWithdrawalsRequest();

        // rate limit the amount of the that can be withdrawn from beacon chain
        uint256 totalExitGwei = getTotalEthRequested(requests);
        rateLimiter.consume(EXIT_REQUEST_LIMIT_ID, SafeCast.toUint64(totalExitGwei));

        bytes32 pubKeyHash = calculateValidatorPubkeyHash(requests[0].pubkey);
        IEtherFiNode node = etherFiNodeFromPubkeyHash[pubKeyHash];
        IEigenPod pod = node.getEigenPod();

        // submitting an execution layer withdrawal request requires paying a fee per request
        if (msg.value < pod.getWithdrawalRequestFee() * requests.length) revert InsufficientWithdrawalFees();
        node.requestExecutionLayerTriggeredWithdrawal{value: msg.value}(requests);

        for (uint256 i = 0; i < requests.length; ) {
            bytes32 currentPubKeyHash = calculateValidatorPubkeyHash(requests[i].pubkey);
            emit ValidatorWithdrawalRequestSent(address(pod), currentPubKeyHash, requests[i].pubkey);
            unchecked { ++i; }
        }
    }

    function getTotalEthRequested (IEigenPod.WithdrawalRequest[] calldata requests) internal pure returns (uint256) {
        uint256 totalGwei;
        for (uint256 i = 0; i < requests.length; ++i) {
            uint256 gweiAmount = requests[i].amountGwei == 0
                ? FULL_EXIT_GWEI
                : uint256(requests[i].amountGwei);

            totalGwei += gweiAmount;
        }
        return totalGwei;
    }


    /**
     * @notice Triggers EIP-7251 consolidation requests for validators in the same EigenPod.
     * @dev Access: only admin role, pausable, nonReentrant.
     * @param requests Array of ConsolidationRequest:
     *        - srcPubkey: 48-byte BLS pubkey of source validator
     *        - targetPubkey: 48-byte BLS pubkey of target validator
     *        - If srcPubkey == targetPubkey, this switches validator from 0x01 to 0x02 credentials
     * @dev EigenLayer validates that validators belong to the pod automatically.
     * @custom:fee Send enough ETH to cover consolidation fees.
     */
    function requestConsolidation(IEigenPod.ConsolidationRequest[] calldata requests) external payable whenNotPaused nonReentrant onlyAdmin {
        if (requests.length == 0) revert EmptyConsolidationRequest();

        // eigenlayer will revert if all validators don't belong to the same pod
        bytes32 pubKeyHash = calculateValidatorPubkeyHash(requests[0].srcPubkey);
        IEtherFiNode node = etherFiNodeFromPubkeyHash[pubKeyHash];
        IEigenPod pod = node.getEigenPod();

        // submitting an execution layer consolidation request requires paying a fee per request
        if (msg.value < pod.getConsolidationRequestFee() * requests.length) revert InsufficientConsolidationFees();
        node.requestConsolidation{value: msg.value}(requests);

        for (uint256 i = 0; i < requests.length; ) {
            bytes32 srcPkHash = calculateValidatorPubkeyHash(requests[i].srcPubkey);
            bytes32 targetPkHash = calculateValidatorPubkeyHash(requests[i].targetPubkey);

            // Emit appropriate event based on whether this is a switch or consolidation
            if (srcPkHash == targetPkHash) {
                emit ValidatorSwitchToCompoundingRequested(address(pod), srcPkHash, requests[i].srcPubkey);
            } else {
                emit ValidatorConsolidationRequested(address(pod), srcPkHash, requests[i].srcPubkey, targetPkHash, requests[i].targetPubkey);
            }
            unchecked { ++i; }
        }
    }

    // returns withdrawal fee per each request
    function getWithdrawalRequestFee(address pod) public view returns (uint256) {
        uint256 feePerRequest = IEigenPod(pod).getWithdrawalRequestFee();
        return feePerRequest;
    }

    // returns consolidation fee per each request
    function getConsolidationRequestFee(address pod) public view returns (uint256) {
        uint256 feePerRequest = IEigenPod(pod).getConsolidationRequestFee();
        return feePerRequest;
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
    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) external onlyCallForwarder whenNotPaused returns (bytes[] memory returnData) {
        if (nodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            IEtherFiNode node = IEtherFiNode(nodes[i]);
            if (!stakingManager.deployedEtherFiNodes(address(node))) revert UnknownNode();

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedExternalCalls[selector][target]) revert ForwardedCallNotAllowed();

            // call validation + whitelist checks performed in node implementation
            returnData[i] = node.forwardExternalCall(target, data[i]);
        }
    }

    /// @notice forward a whitelisted call to the associated eigenPod of the EtherFiNode with the EtherFiNode as the caller.
    ///   This serves to allow us to support minor eigenlayer upgrades without needing to immediately upgrade our contracts.
    function forwardEigenPodCall(address[] calldata nodes, bytes[] calldata data) external onlyCallForwarder whenNotPaused returns (bytes[] memory returnData) {
        if (nodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            IEtherFiNode node = IEtherFiNode(nodes[i]);
            if (!stakingManager.deployedEtherFiNodes(address(node))) revert UnknownNode();

            // validate call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedEigenpodCalls[selector]) revert ForwardedCallNotAllowed();

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

    modifier onlyPodProver() {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_POD_PROVER_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }
}
