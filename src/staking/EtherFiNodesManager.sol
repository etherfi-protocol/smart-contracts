// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import "@etherfi/interfaces/eigenlayer-interfaces/IEigenPod.sol";
import "@etherfi/staking/interfaces/IEtherFiNode.sol";
import "@etherfi/staking/interfaces/IEtherFiNodesManager.sol";
import "@etherfi/staking/interfaces/IStakingManager.sol";
import "@etherfi/governance/rate-limiting/interfaces/IEtherFiRateLimiter.sol";
import "@etherfi/governance/utils/PausableUntil.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";
import "@etherfi/governance/utils/DeprecatedOZReentrancyGuard.sol";

contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    DeprecatedOZOwnable,
    DeprecatedOZPausable,
    PausableUntil,
    DeprecatedOZReentrancyGuard,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    //---------------------------------------------------------------------------
    //-----------------------------  STATE-VARIABLES  ---------------------------
    //---------------------------------------------------------------------------
    LegacyNodesManagerState private legacyState;
    mapping(address => mapping(bytes4 => bool)) public allowedForwardedEigenpodCalls; // Call Forwarding: user -> functionSelector -> allowed
    mapping(address => mapping(bytes4 => mapping(address => bool))) public allowedForwardedExternalCalls; // Call Forwarding: user -> functionSelector -> targetAddress -> allowed
    mapping(bytes32 => IEtherFiNode) public etherFiNodeFromPubkeyHash;

    //--------------------------------------------------------------------------------------
    //-----------------------------  IMMUTABLES  --------------------------------------------
    //--------------------------------------------------------------------------------------
    IStakingManager public immutable stakingManager;
    IEtherFiRateLimiter public immutable rateLimiter;

    //--------------------------------------------------------------------------------------
    //-----------------------------  CONSTANTS  --------------------------------------------
    //--------------------------------------------------------------------------------------
    address public constant BEACON_ETH_STRATEGY_ADDRESS = address(0xbeaC0eeEeeeeEEeEeEEEEeeEEeEeeeEeeEEBEaC0);
    // rate limiting constants
    bytes32 public constant UNRESTAKING_LIMIT_ID = keccak256("UNRESTAKING_LIMIT_ID");
    bytes32 public constant EXIT_REQUEST_LIMIT_ID = keccak256("EXIT_REQUEST_LIMIT_ID");
    bytes32 public constant CONSOLIDATION_REQUEST_LIMIT_ID = keccak256("CONSOLIDATION_REQUEST_LIMIT_ID");
    // maximum exitable balance in gwei
    uint256 public constant FULL_EXIT_GWEI = 2_048_000_000_000;
    uint256 public constant VALIDATOR_PUBKEY_LENGTH = 48;

    //--------------------------------------------------------------------------------------
    //-----------------------------  CONSTRUCTOR  --------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _stakingManager The address of the staking manager
     * @param _roleRegistry The address of the role registry
     * @param _rateLimiter The address of the rate limiter
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address _stakingManager, address _roleRegistry, address _rateLimiter) RolesLibrary(_roleRegistry) {
        stakingManager = IStakingManager(_stakingManager);
        rateLimiter = IEtherFiRateLimiter(_rateLimiter);

        _disableInitializers();
    }

    /// @dev under normal conditions ETH should not accumulate in the EtherFiNode. This will forward
    ///   the eth to the liquidity pool in the event of ETH being accidentally sent there
    function sweepFunds(uint256 id) external onlyHousekeepingOperations whenNotPaused {
        address nodeAddr = etherfiNodeAddress(id);
        uint256 balance = IEtherFiNode(nodeAddr).sweepFunds();
        if(balance > 0) {
            emit FundsTransferred(nodeAddr, balance);
        }
    }

    //--------------------------------------------------------------------------------------
    //---------------------------- OPERATIONAL FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    // Note that most of these calls are pod-level actions and it is a little awkward to always
    // provide a specific validator ID. This is to maintain compatibility with much of our existing
    // tooling which used to operate on a per-validator level instead of per-pod/per-node.
    // Over time we will migrate to directly calling the associated method on the EtherFiNode contract where applicable.

    /**
     * @notice Creates a new eigenpod for a given node
     * @param node The node to create the eigenpod for
     * @return The address of the new eigenpod
     */
    function createEigenPod(address node) external whenNotPaused returns (address) {
        if (msg.sender != address(stakingManager)) revert InvalidCaller();
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
        return IEtherFiNode(node).createEigenPod();
    }

    /**
     * @notice Starts a checkpoint for a given node
     * @param node The node to start the checkpoint for
     */
    function startCheckpoint(address node) public onlyEigenpodOperations whenNotPaused {
        _validateNode(node);
        IEtherFiNode(node).startCheckpoint();
    }
    
    /**
     * @notice Starts a checkpoint for a given node
     * @param id The id of the node to start the checkpoint for
     */
    function startCheckpoint(uint256 id) external onlyEigenpodOperations whenNotPaused {
        startCheckpoint(etherfiNodeAddress(id));
    }

    /**
     * @notice Verifies checkpoint proofs for a given node
     * @param node The node to verify the checkpoint proofs for
     * @param balanceContainerProof The balance container proof
     * @param proofs The proofs to verify
     */
    function verifyCheckpointProofs(address node, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) public onlyEigenpodOperations whenNotPaused {
        _validateNode(node);
        IEtherFiNode(node).verifyCheckpointProofs(balanceContainerProof, proofs);
    }
    
    /**
     * @notice Verifies checkpoint proofs for a given node
     * @param id The id of the node to verify the checkpoint proofs for
     * @param balanceContainerProof The balance container proof
     * @param proofs The proofs to verify
     */
    function verifyCheckpointProofs(uint256 id, BeaconChainProofs.BalanceContainerProof calldata balanceContainerProof, BeaconChainProofs.BalanceProof[] calldata proofs) external onlyEigenpodOperations whenNotPaused {
        verifyCheckpointProofs(etherfiNodeAddress(id), balanceContainerProof, proofs);
    }

    //--------------------------------------------------------------------------------------
    //---------------------------- WITHDRAWAL OPERATIONS  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Queues a beaconETH withdrawal for a given node
     * @param node The node to queue the beaconETH withdrawal for
     * @param amount The amount of beaconETH to withdraw
     * @return withdrawalRoot The withdrawal root
     */
    function queueETHWithdrawal(address node, uint256 amount) public onlyExecutorOperations whenNotPaused returns (bytes32 withdrawalRoot) {
        _validateNode(node);
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(amount / 1 gwei));
        return IEtherFiNode(node).queueETHWithdrawal(amount);
    }
    
    /**
     * @notice Queues a beaconETH withdrawal for a given node
     * @param id The id of the node to queue the beaconETH withdrawal for
     * @param amount The amount of beaconETH to withdraw
     * @return withdrawalRoot The withdrawal root
     */
    function queueETHWithdrawal(uint256 id, uint256 amount) external onlyExecutorOperations whenNotPaused returns (bytes32 withdrawalRoot) {
        return queueETHWithdrawal(etherfiNodeAddress(id), amount);
    }

    /**
     * @notice Queues a withdrawal for a given node
     * @param node The node to queue the withdrawal for
     * @param params The parameters to queue the withdrawal with
     */
    function queueWithdrawals(address node, IDelegationManager.QueuedWithdrawalParams[] calldata params) public onlyExecutorOperations whenNotPaused {
        _validateNode(node);
        // need to rate limit any beacon eth being withdrawn
        rateLimiter.consume(UNRESTAKING_LIMIT_ID, SafeCast.toUint64(_sumRestakingETHWithdrawals(params) / 1 gwei));
        IEtherFiNode(node).queueWithdrawals(params);
    }
    
    /**
     * @notice Queues a withdrawal for a given node
     * @param id The id of the node to queue the withdrawal for
     * @param params The parameters to queue the withdrawal with
     */
    function queueWithdrawals(uint256 id, IDelegationManager.QueuedWithdrawalParams[] calldata params) external onlyExecutorOperations whenNotPaused {
        queueWithdrawals(etherfiNodeAddress(id), params);
    }

    /**
     * @notice Completes all queued beaconETH withdrawals for a given node
     * @param node The node to complete the queued beaconETH withdrawals for
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     */
    function completeQueuedETHWithdrawals(address node, bool receiveAsTokens) public onlyHousekeepingOperations whenNotPaused {
        _validateNode(node);
        uint256 balance = IEtherFiNode(node).completeQueuedETHWithdrawals(receiveAsTokens);
        if(balance > 0) {
            emit FundsTransferred(node, balance);
        }
    }
    
    /**
     * @notice Completes all queued beaconETH withdrawals for a given node
     * @param id The id of the node to complete the queued beaconETH withdrawals for
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     */
    function completeQueuedETHWithdrawals(uint256 id, bool receiveAsTokens) external onlyHousekeepingOperations whenNotPaused {
        completeQueuedETHWithdrawals(etherfiNodeAddress(id), receiveAsTokens);
    }

    /**
     * @notice Completes all queued withdrawals for a given node
     * @param node The node to complete the queued withdrawals for
     * @param withdrawals The withdrawals to complete
     * @param tokens The tokens to complete the withdrawals with
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     */
    function completeQueuedWithdrawals(address node, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) public onlyHousekeepingOperations whenNotPaused {
        _validateNode(node);
        uint256 balance = IEtherFiNode(node).completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
        if (balance > 0) {
            emit FundsTransferred(node, balance);
        }
    }
    
    /**
     * @notice Completes all queued withdrawals for a given node
     * @param id The id of the node to complete the queued withdrawals for
     * @param withdrawals The withdrawals to complete
     * @param tokens The tokens to complete the withdrawals with
     * @param receiveAsTokens Whether to receive the withdrawals as tokens
     */
    function completeQueuedWithdrawals(uint256 id, IDelegationManager.Withdrawal[] calldata withdrawals, IERC20[][] calldata tokens, bool[] calldata receiveAsTokens) external onlyHousekeepingOperations whenNotPaused {
        completeQueuedWithdrawals(etherfiNodeAddress(id), withdrawals, tokens, receiveAsTokens);
    }

    //-------------------------------------------------------------------
    //--------------------  EL TRIGGER FUNCTIONS  -----------------------
    //-------------------------------------------------------------------
    /**
     * @notice Triggers EIP-7002 withdrawal requests, grouping by EigenPod automatically.
     * @dev associated etherFiNode is derived from pubkey in the request. Caller should ensure
     *      all provided validators share the same eigenpod
     * @dev Access: only ETHERFI_NODES_MANAGER_EL_TRIGGER_EXIT_ROLE, pausable, nonReentrant.
     * @param requests Array of WithdrawalRequest:
     *        - pubkey: 48-byte BLS pubkey
     *        - amountGwei: 0 for full exit, >0 for partial to pod
     * @custom:fee Send EXACT ETH to cover sum of (feePerPod * requestsForPod).
     */
    function requestExecutionLayerTriggeredWithdrawal(IEigenPod.WithdrawalRequest[] calldata requests) external payable nonReentrant onlyExecutorOperations whenNotPaused {
        if (requests.length == 0) revert EmptyWithdrawalsRequest();

        // rate limit the amount of the that can be withdrawn from beacon chain
        uint256 totalExitGwei = _getTotalEthRequested(requests);
        rateLimiter.consume(EXIT_REQUEST_LIMIT_ID, SafeCast.toUint64(totalExitGwei));

        bytes32 pubKeyHash = calculateValidatorPubkeyHash(requests[0].pubkey);
        IEtherFiNode node = etherFiNodeFromPubkeyHash[pubKeyHash];
        IEigenPod pod = node.getEigenPod();

        // submitting an execution layer withdrawal request requires paying a fee per request
        if (msg.value < pod.getWithdrawalRequestFee() * requests.length) revert InsufficientWithdrawalFees();
        node.requestExecutionLayerTriggeredWithdrawal{value: msg.value}(requests);

        for (uint256 i = 0; i < requests.length; i++) {
            bytes32 currentPubKeyHash = calculateValidatorPubkeyHash(requests[i].pubkey);
            emit ValidatorWithdrawalRequestSent(address(pod), currentPubKeyHash, requests[i].pubkey);
        }
    }

    /**
     * @notice Triggers EIP-7251 consolidation requests for validators in the same EigenPod.
     * @dev Access: only ETHERFI_NODES_MANAGER_EL_CONSOLIDATION_ROLE, pausable, nonReentrant.
     * @param requests Array of ConsolidationRequest:
     *        - srcPubkey: 48-byte BLS pubkey of source validator
     *        - targetPubkey: 48-byte BLS pubkey of target validator
     *        - If srcPubkey == targetPubkey, this switches validator from 0x01 to 0x02 credentials
     * @dev EigenLayer validates that validators belong to the pod automatically.
     * @custom:fee Send EXACT ETH to cover consolidation fees.
     */
    function requestConsolidation(IEigenPod.ConsolidationRequest[] calldata requests) external payable nonReentrant onlyExecutorOperations whenNotPaused {
        if (requests.length == 0) revert EmptyConsolidationRequest();

        // rate limit consolidation requests - each request could affect up to FULL_EXIT_GWEI
        uint256 totalConsolidationGwei = _getTotalConsolidationGwei(requests);
        rateLimiter.consume(CONSOLIDATION_REQUEST_LIMIT_ID, SafeCast.toUint64(totalConsolidationGwei));

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

    //-------------------------------------------------------------------
    //---------------------  VALIDATOR LINKING FUNCTIONS ---------------
    //-------------------------------------------------------------------
    /**
     * @notice Associate the provided pubkey with particular EtherFiNode instance.
     * @param pubkey The pubkey to associate with the node
     * @param nodeAddress The address of the node to associate the pubkey with
     * @param legacyId The legacy id of the node to associate the pubkey with
     */
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

    /**
     * @notice Link legacy validator ids that were created before we started tracking pubkeys onchain
     * @param validatorIds The legacy validator ids to link
     * @param pubkeys The pubkeys to link the validator ids to
     * @dev We can delete this method once we have linked all of our legacy validators
     */
    function linkLegacyValidatorIds(uint256[] calldata validatorIds, bytes[] calldata pubkeys) external onlyExecutorOperations {
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
    //-------------------------------  ADMIN FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Update the whitelist for external calls that can be executed by an EtherfiNode
     * @param user The address to grant/revoke permission for
     * @param selector method selector
     * @param target call target for forwarded call
     * @param allowed enable or disable the call
     */
    function updateAllowedForwardedExternalCalls(address user, bytes4 selector, address target, bool allowed) external onlyOperatingTimelock {
        allowedForwardedExternalCalls[user][selector][target] = allowed;
        emit UserAllowedForwardedExternalCallsUpdated(user, selector, target, allowed);
    }

    /**
     * @notice Update the whitelist for external calls that can be executed against the corresponding eigenpod
     * @param user The address to grant/revoke permission for
     * @param selector method selector
     * @param allowed enable or disable the call
     */
    function updateAllowedForwardedEigenpodCalls(address user, bytes4 selector, bool allowed) external onlyOperatingTimelock {
        allowedForwardedEigenpodCalls[user][selector] = allowed;
        emit UserAllowedForwardedEigenpodCallsUpdated(user, selector, allowed);
    }

    /**
     * @notice Set the proof submitter for a specific node
     * @param node The node address to set the proof submitter for
     * @param proofSubmitter The address of the proof submitter
     */
    function setProofSubmitter(address node, address proofSubmitter) public onlyOperatingMultisig whenNotPaused {
        _validateNode(node);
        IEtherFiNode(node).setProofSubmitter(proofSubmitter);
    }
    
    /**
     * @notice Set the proof submitter for a specific node
     * @param id The id of the node to set the proof submitter for
     * @param proofSubmitter The address of the proof submitter
     */
    function setProofSubmitter(uint256 id, address proofSubmitter) external onlyOperatingMultisig whenNotPaused {
        setProofSubmitter(etherfiNodeAddress(id), proofSubmitter);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice forward a whitelisted call to a whitelisted external contract with the EtherFiNode as the caller
     * @param nodes The nodes to forward the call to
     * @param data The data to forward the call with
     * @param target The target to forward the call to
     * @return returnData The return data from the call
     */
    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) external onlyEigenpodOperations whenNotPaused returns (bytes[] memory returnData) {
        if (nodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            _validateNode(nodes[i]);
            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);

            // Check if user is allowed to call this selector on this target
            if (!allowedForwardedExternalCalls[msg.sender][selector][target]) revert ForwardedCallNotAllowed();

            // call validation + whitelist checks performed in node implementation
            returnData[i] = IEtherFiNode(nodes[i]).forwardExternalCall(target, data[i]);
        }
    }

    /**
     * @notice forward a whitelisted call to the associated eigenPod of the EtherFiNode with the EtherFiNode as the caller.
     * @param nodes The nodes to forward the call to
     * @param data The data to forward the call with
     * @return returnData The return data from the call
     * @dev This serves to allow us to support minor eigenlayer upgrades without needing to immediately upgrade our contracts.
     */
    function forwardEigenPodCall(address[] calldata nodes, bytes[] calldata data) external onlyEigenpodOperations whenNotPaused returns (bytes[] memory returnData) {
        if (nodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            _validateNode(nodes[i]);
            // validate call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);

            // Check if user is allowed to call this selector on eigenpod
            if (!allowedForwardedEigenpodCalls[msg.sender][selector]) revert ForwardedCallNotAllowed();

            returnData[i] = IEtherFiNode(nodes[i]).forwardEigenPodCall(data[i]);
        }
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  INTERNAL FUNCTIONS  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Calculates the total Gwei requested for withdrawal requests
     * @param requests The withdrawal requests to process
     * @return totalGwei The total Gwei to rate limit
     */
    function _getTotalEthRequested (IEigenPod.WithdrawalRequest[] calldata requests) internal pure returns (uint256) {
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
     * @notice Calculates the total Gwei affected by consolidation requests for rate limiting
     * @dev For true consolidations (src != target), the source validator's full balance is merged
     *      For credential switches (src == target), we count 0 as no ETH movement occurs
     * @param requests The consolidation requests to process
     * @return totalGwei The total Gwei to rate limit
     */
    function _getTotalConsolidationGwei(IEigenPod.ConsolidationRequest[] calldata requests) internal pure returns (uint256 totalGwei) {
        for (uint256 i = 0; i < requests.length; ) {
            // Only count true consolidations where source validator balance is moved
            // Credential switches (src == target) don't move ETH
            if (calculateValidatorPubkeyHash(requests[i].srcPubkey) != calculateValidatorPubkeyHash(requests[i].targetPubkey)) {
                totalGwei += FULL_EXIT_GWEI;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Calculates the total beaconETH amount for rate limiting - only rate limit beaconETH strategy withdrawals
     * @param params The withdrawal parameters to process
     * @return totalBeaconEth The total beaconETH amount
     */
    function _sumRestakingETHWithdrawals(IDelegationManager.QueuedWithdrawalParams[] calldata params) internal pure returns (uint256) {
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

    /**
     * @notice Validate that the node exists and revert if not
     * @param node The node address to validate
     */
    function _validateNode(address node) internal view {
        if (!stakingManager.deployedEtherFiNodes(node)) revert UnknownNode();
    }

    /**
     * @notice Authorize the upgrade of the EtherFiNodesManager contract
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------  GETTERS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Returns the associated eigenpod for a given node
     * @param node The node to get the eigenpod for
     * @return The associated eigenpod
     */
    function getEigenPod(address node) public view returns (address) {
        _validateNode(node);
        return address(IEtherFiNode(node).getEigenPod());
    }
    
    /**
     * @notice Returns the associated eigenpod for a given node
     * @param id The id of the node to get the eigenpod for
     * @return The associated eigenpod
     */
    function getEigenPod(uint256 id) public view returns (address) {
        return getEigenPod(etherfiNodeAddress(id));
    }

    /**
     * @notice Returns the withdrawal fee per each request
     * @param pod The pod to get the withdrawal fee for
     * @return The withdrawal fee
     */
    function getWithdrawalRequestFee(address pod) public view returns (uint256) {
        return IEigenPod(pod).getWithdrawalRequestFee();
    }

    /**
     * @notice Returns the consolidation fee per each request
     * @param pod The pod to get the consolidation fee for
     * @return The consolidation fee
     */
    function getConsolidationRequestFee(address pod) public view returns (uint256) {
        return IEigenPod(pod).getConsolidationRequestFee();
    }
    /**
     * @notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
     * @param pubkey The pubkey to calculate the hash of
     * @return The hash of the pubkey
     */
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != VALIDATOR_PUBKEY_LENGTH) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }

    /**
     * @notice Converts a target address to 0x01 withdrawal credential format for a traditional 32eth validator
     * @param addr The address to convert
     * @return The withdrawal credential format
     */
    function addressToWithdrawalCredentials(address addr) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), bytes11(0x0), addr);
    }

    /**
     * @notice Converts a target address to 0x02 withdrawal credential format for a post Pectra compounding validator
     * @param addr The address to convert
     * @return The withdrawal credential format
     */
    function addressToCompoundingWithdrawalCredentials(address addr) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x02), bytes11(0x0), addr);
    }

    /**
     * @notice Get the etherFiNode instance associated with the provided ID. (Legacy validatorId or pubkeyHash)
     * @param id The ID to get the etherFiNode instance for
     * @dev Note that this ID can either be a a traditional etherfi validatorID or
     *      a validatorPubkeyHash cast as a uint256. This was done maintaint compatibility
     *      with minimal changes as we migrate from our id system to using pubkey hash instead
     * @return The etherFiNode instance
     */
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
}
