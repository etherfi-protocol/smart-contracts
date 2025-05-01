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
import "./TNFT.sol";
import "./BNFT.sol";

contract EtherFiNodesManager is
    Initializable,
    IEtherFiNodesManager,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    LegacyManagerState public legacyState;
    /*
    uint64 public numberOfValidators; // # of validators in LIVE or WAITING_FOR_APPROVAL phases
    uint64 public nonExitPenaltyPrincipal;
    uint64 public nonExitPenaltyDailyRate; // in basis points
    uint64 public SCALE;

    address public treasuryContract;
    address public stakingManagerContract;
    address public DEPRECATED_protocolRevenueManagerContract;

    // validatorId == bidId -> withdrawalSafeAddress
    mapping(uint256 => address) public etherfiNodeAddress;

    TNFT public tnft;
    BNFT public bnft;
    IAuctionManager public auctionManager;
    IProtocolRevenueManager public DEPRECATED_protocolRevenueManager;

    RewardsSplit public stakingRewardsSplit;
    RewardsSplit public DEPRECATED_protocolRewardsSplit;

    address public DEPRECATED_admin;
    mapping(address => bool) public admins;

    IEigenPodManager public eigenPodManager;
    IDelayedWithdrawalRouter public delayedWithdrawalRouter;
    // max number of queued eigenlayer withdrawals to attempt to claim in a single tx
    uint8 public maxEigenlayerWithdrawals;

    // stack of re-usable withdrawal safes to save gas
    address[] public unusedWithdrawalSafes;

    bool public DEPRECATED_enableNodeRecycling;

    mapping(uint256 => ValidatorInfo) private validatorInfos;

    IDelegationManager public delegationManager;

    mapping(address => bool) public operatingAdmin;

    // function -> allowed
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls;
    // function -> target_address -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls;
    */

    address public immutable eigenPodManager;
    address  public immutable delegationManager;
    address public immutable stakingManager;

    //-----------------------------------------------------------------
    //-----------------------  Storage  -------------------------------
    //-----------------------------------------------------------------

    mapping(bytes32 => IEtherFiNode) public etherFiNodeFromPubkeyHash;

    // Call Forwarding: functionSignature -> allowed
    mapping(bytes4 => bool) public allowedForwardedEigenpodCalls;
    // Call Forwarding: functionSignature -> targetAddress -> allowed
    mapping(bytes4 => mapping(address => bool)) public allowedForwardedExternalCalls;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    event NodeExitRequested(uint256 _validatorId);
    event NodeExitProcessed(uint256 _validatorId);
    //event PhaseChanged(uint256 indexed _validatorId, IEtherFiNode.VALIDATOR_PHASE _phase);

    event PartialWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event FullWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, uint256 toOperator, uint256 toTnft, uint256 toBnft, uint256 toTreasury);
    event QueuedRestakingWithdrawal(uint256 indexed _validatorId, address indexed etherFiNode, bytes32[] withdrawalRoots);


    error AlreadyLinked();
    error InvalidPubKeyLength();
    error InvalidCaller();
    event PubkeyLinked(bytes32 indexed pubkeyHash, address indexed nodeAddress, bytes pubkey);
    event NodeDeployed(address indexed nodeAddress, uint256 indexed nodeNonce);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    receive() external payable {}

    error InvalidParams();

    function setProofSubmitter(uint256 id, address proofSubmitter) external {
        // TODO(dave): implement
    }
    function startCheckpoint(uint256 id) external {
        // TODO(dave): implement
    }

    // TODO(dave): reimplement pausing with role registry
    function pauseContract() external { _pause(); }
    function unPauseContract() external { _unpause(); }

    function etherfiNodeAddress(uint256) public view returns (address) {
        // TODO(dave): implement
        return address(0);
    }

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

    function getEigenPod(uint256 id) public view returns (address) {
        IEtherFiNode node = IEtherFiNode(etherFiNodeFromId(id));
        return address(node.getEigenPod());
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


    //--------------------------------------------------------------------------------------
    //-------------------------------- CALL FORWARDING  ------------------------------------
    //--------------------------------------------------------------------------------------
    event AllowedForwardedExternalCallsUpdated(bytes4 indexed selector, address indexed _target, bool _allowed);
    event AllowedForwardedEigenpodCallsUpdated(bytes4 indexed selector, bool _allowed);

    error ForwardedCallNotAllowed();
    error InvalidForwardedCall();

    /// @notice Update the whitelist for external calls that can be executed by an EtherfiNode
    /// @param selector method selector
    /// @param target call target for forwarded call
    /// @param allowed enable or disable the call
    function updateAllowedForwardedExternalCalls(bytes4 selector, address target, bool allowed) external {
        allowedForwardedExternalCalls[selector][target] = allowed;
        emit AllowedForwardedExternalCallsUpdated(selector, target, allowed);
    }

    /// @notice Update the whitelist for external calls that can be executed against the corresponding eigenpod
    /// @param selector method selector
    /// @param allowed enable or disable the call
    function updateAllowedForwardedEigenpodCalls(bytes4 selector, bool allowed) external {
        allowedForwardedEigenpodCalls[selector] = allowed;
        emit AllowedForwardedEigenpodCallsUpdated(selector, allowed);
    }

    function batchForwardEigenpodCall(bytes32[] calldata pubkeys, bytes[] calldata data) external returns (bytes[] memory returnData) {
        returnData = new bytes[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedEigenpodCalls[selector]) revert ForwardedCallNotAllowed();

            returnData[i] = etherFiNodeFromPubkeyHash[pubkeys[i]].forwardEigenPodCall(data[i]);
        }
    }

    function forwardExternalCall(address[] calldata nodes, bytes[] calldata data, address target) public returns (bytes[] memory returnData) {
        returnData = new bytes[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedExternalCalls[selector][target]) revert ForwardedCallNotAllowed();

            returnData[i] = IEtherFiNode(nodes[i]).forwardExternalCall(target, data[i]);
        }
    }

    function forwardExternalCall(bytes32[] calldata pubkeys, bytes[] calldata data, address target) public returns (bytes[] memory returnData) {
        returnData = new bytes[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; i++) {

            // validate the call
            if (data[i].length < 4) revert InvalidForwardedCall();
            bytes4 selector = bytes4(data[i][:4]);
            if (!allowedForwardedExternalCalls[selector][target]) revert ForwardedCallNotAllowed();

            returnData[i] = etherFiNodeFromPubkeyHash[pubkeys[i]].forwardExternalCall(target, data[i]);
        }
    }

    function forwardEigenPodCall(uint256[] calldata ids, bytes[] calldata data) external returns (bytes memory) {
        // TODO(dave): implement
    }

}
