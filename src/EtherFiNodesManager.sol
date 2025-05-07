// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "./interfaces/IAuctionManager.sol";
import "./interfaces/IEtherFiNode.sol";
import "./interfaces/IEtherFiNodesManager.sol";
import "./interfaces/IProtocolRevenueManager.sol";
import "./interfaces/IStakingManager.sol";
import "./interfaces/ITNFT.sol";
import "./interfaces/IBNFT.sol";
import "./interfaces/IRoleRegistry.sol";

contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{

    // TODO(dave): these are only used by viewer so we should just move them there
    address public immutable eigenPodManager = address(0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338);
    address public immutable delegationManager = address(0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A);

    address public immutable stakingManager;
    IRoleRegistry public immutable roleRegistry;

    //---------------------------------------------------------------------------
    //-----------------------------  Storage  -----------------------------------
    //---------------------------------------------------------------------------

    LegacyNodesManagerState private legacyState;
    // Call Forwarding: functionSelector -> allowed
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls;
    // Call Forwarding: functionSelector -> targetAddress -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls;

    mapping(bytes32 => IEtherFiNode) public etherFiNodeFromPubkeyHash;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _stakingManager) {
        stakingManager = _stakingManager;

        // TODO(dave): add to constructor
        roleRegistry = IRoleRegistry(0x62247D29B4B9BECf4BB73E0c722cf6445cfC7cE9);

        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    receive() external payable {}

    // TODO(dave): reimplement pausing with role registry
    function pauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_PAUSER(), msg.sender)) revert IncorrectRole();
        _pause();
    }
    function unPauseContract() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_UNPAUSER(), msg.sender)) revert IncorrectRole();
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ROLES  ---------------------------------------
    //--------------------------------------------------------------------------------------

    bytes32 public constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = keccak256("ETHERFI_NODES_MANAGER_ADMIN_ROLE");
    bytes32 public constant ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE = keccak256("ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE");

    function etherFiNodeFromId(uint256 id) public view returns (address) {
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

    //--------------------------------------------------------------------------------------
    //---------------------------- Eigenlayer Interactions  --------------------------------
    //--------------------------------------------------------------------------------------

    // TODO(dave): permissions

    function getEigenPod(uint256 id) public view returns (address) {
        return address(IEtherFiNode(etherfiNodeAddress(id)).getEigenPod());
    }

    function createEigenPod(uint256 id) public onlyAdmin returns (address) {
        return IEtherFiNode(etherfiNodeAddress(id)).createEigenPod();
    }

    function startCheckpoint(uint256 id) external onlyAdmin {
        IEtherFiNode(etherfiNodeAddress(id)).startCheckpoint();
    }

    function setProofSubmitter(uint256 id, address proofSubmitter) external onlyAdmin {
        IEtherFiNode(etherfiNodeAddress(id)).setProofSubmitter(proofSubmitter);
    }

    function queueWithdrawal(uint256 id, IDelegationManager.QueuedWithdrawalParams calldata params) external onlyAdmin returns (bytes32 withdrawalRoot) {
        return IEtherFiNode(etherfiNodeAddress(id)).queueWithdrawal(params);
    }

    function completeQueuedWithdrawals(uint256 id, bool receiveAsTokens) external onlyAdmin {
        IEtherFiNode(etherfiNodeAddress(id)).completeQueuedWithdrawals(receiveAsTokens);
    }

    //-------------------------------------------------------------------
    //---------------------  Key Management  ----------------------------
    //-------------------------------------------------------------------

    ///@notice Calculates the pubkey hash of a validator's pubkey as per SSZ spec
    function calculateValidatorPubkeyHash(bytes memory pubkey) public pure returns (bytes32) {
        if (pubkey.length != 48) revert InvalidPubKeyLength();
        return sha256(abi.encodePacked(pubkey, bytes16(0)));
    }

    /// @notice converts a target address to 0x01 withdrawal credential format
    function addressToWithdrawalCredentials(address addr) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(0x01), bytes11(0x0), addr);
    }

    /// @dev associate the provided pubkey with particular EtherFiNode instance.
    function linkPubkeyToNode(bytes calldata pubkey, address nodeAddress, uint256 legacyId) external {
        if (msg.sender != address(stakingManager)) revert InvalidCaller();
        bytes32 pubkeyHash = calculateValidatorPubkeyHash(pubkey);
        if (address(etherFiNodeFromPubkeyHash[pubkeyHash]) != address(0)) revert AlreadyLinked();
        if (legacyState.DEPRECATED_etherfiNodeAddress[legacyId] != address(0)) revert AlreadyLinked();

        // link legacyId for now. We can remove this in a future upgrade
        legacyState.DEPRECATED_etherfiNodeAddress[legacyId] = nodeAddress;

        etherFiNodeFromPubkeyHash[pubkeyHash] = IEtherFiNode(nodeAddress);
        emit PubkeyLinked(pubkeyHash, nodeAddress, pubkey);
    }

    // TODO(dave): is it better to revert if no address exists for provided id?

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


    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------

    error ForwardedCallNotAllowed();
    error InvalidForwardedCall();

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

    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) external onlyCallForwarder returns (bytes[] memory returnData) {
        if (nodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedExternalCalls[selector][target]) revert ForwardedCallNotAllowed();

            returnData[i] = IEtherFiNode(nodes[i]).forwardExternalCall(target, data[i]);
        }
    }

    function forwardExternalCall(uint256[] calldata ids, bytes[] calldata data, address target) external onlyCallForwarder returns (bytes[] memory returnData) {
        if (ids.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedExternalCalls[selector][target]) revert ForwardedCallNotAllowed();

            IEtherFiNode node = IEtherFiNode(etherfiNodeAddress(ids[i]));
            returnData[i] = node.forwardExternalCall(target, data[i]);
        }
    }

    function forwardEigenPodCall(address[] calldata etherFiNodes, bytes[] calldata data) external onlyCallForwarder returns (bytes[] memory returnData) {
        if (etherFiNodes.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](etherFiNodes.length);
        for (uint256 i = 0; i < etherFiNodes.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedEigenpodCalls[selector]) revert ForwardedCallNotAllowed();

            IEtherFiNode node = IEtherFiNode(etherFiNodes[i]);
            returnData[i] = node.forwardEigenPodCall(data[i]);
        }
    }

    function forwardEigenPodCall(uint256[] calldata ids, bytes[] calldata data) external onlyCallForwarder returns (bytes[] memory returnData) {
        if (ids.length != data.length) revert InvalidForwardedCall();

        returnData = new bytes[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedEigenpodCalls[selector]) revert ForwardedCallNotAllowed();

            IEtherFiNode node = IEtherFiNode(etherFiNodeFromId(ids[i]));
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

    modifier onlyCallForwarder() {
        if (!roleRegistry.hasRole(ETHERFI_NODES_MANAGER_CALL_FORWARDER_ROLE, msg.sender)) revert IncorrectRole();
        _;
    }

}
