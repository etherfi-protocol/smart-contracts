// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import "@etherfi/oracle/interfaces/IEtherFiOracle.sol";
import "@etherfi/oracle/interfaces/IEtherFiAdmin.sol";
import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/Pausable.sol";
import "@etherfi/governance/utils/DeprecatedOZPausable.sol";


contract EtherFiOracle is Initializable, OwnableUpgradeable, DeprecatedOZPausable, UUPSUpgradeable, IEtherFiOracle, RolesLibrary, Pausable {

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------
    mapping(address => IEtherFiOracle.CommitteeMemberState) public committeeMemberStates; // committee member wallet address to its State
    mapping(bytes32 => IEtherFiOracle.ConsensusState) public consensusStates; // report's hash -> Consensus State

    uint32 public consensusVersion; // the version of the consensus
    uint32 public quorumSize; // the required supports to reach the consensus
    uint32 public reportPeriodSlot; // the period of the oracle report in # of slots
    uint32 public reportStartSlot; // the first report slot

    uint32 public lastPublishedReportRefSlot; // the ref slot of the last published report
    uint32 public lastPublishedReportRefBlock; // the ref block of the last published report

    /// Chain specification
    uint32 internal SLOTS_PER_EPOCH;
    uint32 internal SECONDS_PER_SLOT;
    uint32 internal BEACON_GENESIS_TIME;

    uint32 public numCommitteeMembers; // the total number of committee members
    uint32 public numActiveCommitteeMembers; // the number of active (enabled) committee members

    // deprecated storage slots
    uint160 private __gap_0;
    uint256 private __gap_1;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    IEtherFiAdmin public immutable etherFiAdmin;
    uint32 public immutable minQuorumSize;

    //--------------------------------------------------------------------------------------
    //---------------------------------  EVENTS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    event CommitteeMemberAdded(address indexed member);
    event CommitteeMemberRemoved(address indexed member);
    event CommitteeMemberUpdated(address indexed member, bool enabled);
    event QuorumUpdated(uint32 newQuorumSize);
    event ConsensusVersionUpdated(uint32 newConsensusVersion);
    event OracleReportPeriodUpdated(uint32 newOracleReportPeriod);
    event ReportStartSlotUpdated(uint32 reportStartSlot);

    event ReportPublished(uint32 consensusVersion, uint32 refSlotFrom, uint32 refSlotTo, uint32 refBlockFrom, uint32 refBlockTo, bytes32 indexed hash);
    event ReportSubmitted(uint32 consensusVersion, uint32 refSlotFrom, uint32 refSlotTo, uint32 refBlockFrom, uint32 refBlockTo, bytes32 indexed hash, address indexed committeeMember);
    event ReportUnpublished(bytes32 indexed hash);

    //--------------------------------------------------------------------------------------
    //-------------------------------------  ERRORS  ---------------------------------------
    //--------------------------------------------------------------------------------------
    error ConsensusAlreadyReached();
    error ReportNotNeeded();
    error NotRegistered();
    error MemberDisabled();
    error EpochNotFinalized();
    error ReportSlotNotStarted();
    error LastReportNotHandled();
    error WrongConsensusVersion();
    error WrongSlotFrom();
    error WrongSlotTo();
    error WrongBlockFrom();
    error WrongBlockTo();
    error ReportBlockTooOld();
    error ConsensusNotReached();
    error ReportExecuted();
    error AlreadyRegistered();
    error AlreadyInTargetState();
    error InvalidReportPeriod();
    error InvalidConsensusVersion();
    error InvalidQuorum();

    //--------------------------------------------------------------------------------------
    //-------------------------------------  CONSTRUCTOR  ----------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _minQuorumSize The minimum quorum size
     * @param _etherFiAdmin The address of the EtherFiAdmin contract
     * @param _roleRegistry The address of the RoleRegistry contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(uint32 _minQuorumSize, address _etherFiAdmin, address _roleRegistry) RolesLibrary(_roleRegistry) {
        minQuorumSize = _minQuorumSize;
        etherFiAdmin = IEtherFiAdmin(_etherFiAdmin);
        _disableInitializers();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ----------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EtherFiOracle
     * @param _quorumSize The quorum size
     * @param _reportPeriodSlot The report period slot
     * @param _reportStartSlot The report start slot
     * @param _slotsPerEpoch The slots per epoch
     * @param _secondsPerSlot The seconds per slot
     * @param _genesisTime The genesis time
     */
    function initialize(uint32 _quorumSize, uint32 _reportPeriodSlot, uint32 _reportStartSlot, uint32 _slotsPerEpoch, uint32 _secondsPerSlot, uint32 _genesisTime)
        external
        initializer
    {
        __Ownable_init();
        __UUPSUpgradeable_init();

        consensusVersion = 1;
        reportPeriodSlot = _reportPeriodSlot;
        quorumSize = _quorumSize;
        reportStartSlot = _reportStartSlot;
        SLOTS_PER_EPOCH = _slotsPerEpoch;
        SECONDS_PER_SLOT = _secondsPerSlot;
        BEACON_GENESIS_TIME = _genesisTime;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  SUBMIT REPORT FUNCTION  --------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Submit a report
     * @param _report The report
     * @return True if the report was submitted, false otherwise
     */
    function submitReport(OracleReport calldata _report) external whenNotPaused returns (bool) {
        bytes32 reportHash = generateReportHash(_report);
        if (consensusStates[reportHash].consensusReached) revert ConsensusAlreadyReached();
        if (!shouldSubmitReport(msg.sender)) revert ReportNotNeeded();
        verifyReport(_report);


        // update the member state
        CommitteeMemberState storage memberState = committeeMemberStates[msg.sender];
        memberState.lastReportRefSlot = _report.refSlotTo;
        memberState.numReports++;

        // update the consensus state
        ConsensusState storage consenState = consensusStates[reportHash];

        emit ReportSubmitted(
            _report.consensusVersion,
            _report.refSlotFrom,
            _report.refSlotTo,
            _report.refBlockFrom,
            _report.refBlockTo,
            reportHash,
            msg.sender
            );

        // if the consensus reaches
        consenState.support++;
        bool consensusReached = (consenState.support >= quorumSize);
        if (consensusReached) {
            consenState.consensusReached = true;
            consenState.consensusTimestamp = uint32(block.timestamp);
            _publishReport(_report, reportHash);
        }

        return consensusReached;
    }

    //--------------------------------------------------------------------------------------
    //------------------------------  ADMIN FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Add a committee member
     * @param _address The address of the committee member
     * @param _quorumSize The quorum size
     */
    function addCommitteeMember(address _address, uint32 _quorumSize) public onlyAdmin {
        if (committeeMemberStates[_address].registered) revert AlreadyRegistered();
        numCommitteeMembers++;
        numActiveCommitteeMembers++;
        committeeMemberStates[_address] = CommitteeMemberState(true, true, 0, 0);
        quorumSize = _quorumSize;
        _checkQuorum();
        emit CommitteeMemberAdded(_address);
    }

    /**
     * @notice Remove a committee member
     * @param _address The address of the committee member
     * @param _quorumSize The quorum size
     */
    function removeCommitteeMember(address _address, uint32 _quorumSize) public onlyAdmin {
        if (!committeeMemberStates[_address].registered) revert NotRegistered();
        numCommitteeMembers--;
        if (committeeMemberStates[_address].enabled) numActiveCommitteeMembers--;
        delete committeeMemberStates[_address];
        quorumSize = _quorumSize;
        _checkQuorum();
        emit CommitteeMemberRemoved(_address);
    }

    /**
     * @notice Manage a committee member
     * @param _address The address of the committee member
     * @param _enabled True if the committee member is enabled, false otherwise
     * @param _quorumSize The quorum size
     */
    function manageCommitteeMember(address _address, bool _enabled, uint32 _quorumSize) public onlyOperatingMultisig {
        if (!committeeMemberStates[_address].registered) revert NotRegistered();
        if (committeeMemberStates[_address].enabled == _enabled) revert AlreadyInTargetState();
        committeeMemberStates[_address].enabled = _enabled;
        if (_enabled) {
            numActiveCommitteeMembers++;
        } else {
            numActiveCommitteeMembers--;
        }
        quorumSize = _quorumSize;
        _checkQuorum();
        emit CommitteeMemberUpdated(_address, _enabled);
    }

    /**
     * @notice Set the quorum size
     * @param _quorumSize The quorum size
     */
    function setQuorumSize(uint32 _quorumSize) public onlyAdmin {
        quorumSize = _quorumSize;
        _checkQuorum();
        emit QuorumUpdated(_quorumSize);
    }

    /**
     * @notice Set the oracle report period
     * @param _reportPeriodSlot The report period slot
     */
    function setOracleReportPeriod(uint32 _reportPeriodSlot) public onlyAdmin {
        if (_reportPeriodSlot == 0 || _reportPeriodSlot % SLOTS_PER_EPOCH != 0) revert InvalidReportPeriod();
        reportPeriodSlot = _reportPeriodSlot;

        emit OracleReportPeriodUpdated(_reportPeriodSlot);
    }

    /**
     * @notice Set the consensus version
     * @param _consensusVersion The consensus version
     */
    function setConsensusVersion(uint32 _consensusVersion) public onlyAdmin {
        if (_consensusVersion <= consensusVersion) revert InvalidConsensusVersion();
        consensusVersion = _consensusVersion;

        emit ConsensusVersionUpdated(_consensusVersion);
    }

    /**
     * @notice Unpublish a report
     * @param _report The report
     */
    function unpublishReport(OracleReport calldata _report) public onlyOperatingMultisig {
        bytes32 _hash = generateReportHash(_report);
        if (!consensusStates[_hash].consensusReached) revert ConsensusNotReached();
        if (_report.refSlotTo <= etherFiAdmin.lastHandledReportRefSlot()) revert ReportExecuted();
        consensusStates[_hash].support = 0;
        consensusStates[_hash].consensusReached = false;
        lastPublishedReportRefSlot = _report.refSlotFrom - 1;
        lastPublishedReportRefBlock = _report.refBlockFrom - 1;
        emit ReportUnpublished(_hash);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Check if the slot is finalized
     * @param _slot The slot
     * @return True if the slot is finalized, false otherwise
     */
    function _isFinalized(uint32 _slot) internal view returns (bool) {
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 currEpoch = (currSlot / SLOTS_PER_EPOCH);
        uint32 slotEpoch = (_slot / SLOTS_PER_EPOCH);
        return slotEpoch + 2 < currEpoch;
    }

    /**
     * @notice Publish a report
     * @param _report The report
     * @param _hash The hash of the report
     */
    function _publishReport(OracleReport calldata _report, bytes32 _hash) internal {
        lastPublishedReportRefSlot = _report.refSlotTo;
        lastPublishedReportRefBlock = _report.refBlockTo;

        // emit report published event
        emit ReportPublished(
            _report.consensusVersion,
            _report.refSlotFrom,
            _report.refSlotTo,
            _report.refBlockFrom,
            _report.refBlockTo,
            _hash
            );
    }

    /**
     * @notice Check the quorum
     * @dev If the quorum size is less than the minimum quorum size, or the number of active committee members is less than the quorum size, 
     *      or the number of active committee members is greater than or equal to 2 times the quorum size, revert InvalidQuorum
     */
    function _checkQuorum() internal view {
        if (quorumSize < minQuorumSize || numActiveCommitteeMembers < quorumSize || numActiveCommitteeMembers >= 2 * quorumSize) revert InvalidQuorum();
    }

    /**
     * @notice Authorize the upgrade
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //--------------------------------  VIEW FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the block stamp for the next report
     * @return slotFrom The slot from
     * @return slotTo The slot to
     * @return blockFrom The block from
     * @dev For generating the next report, the starting & ending points need to be specified.
     *      The report should include data for the specified slot and block ranges (inclusive)
     */
    function blockStampForNextReport() public view returns (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) {
        slotFrom = lastPublishedReportRefSlot == 0 ? reportStartSlot : lastPublishedReportRefSlot + 1;
        slotTo = slotForNextReport();
        blockFrom = lastPublishedReportRefBlock == 0 ? reportStartSlot : lastPublishedReportRefBlock + 1;
        // `blockTo` can't be decided since a slot may not have any block (`missed slot`)
    }

    /**
     * @notice Check if the report should be submitted
     * @param _member The member address
     * @return True if the report should be submitted, false otherwise
     */
    function shouldSubmitReport(address _member) public view returns (bool) {
        if (!committeeMemberStates[_member].registered) revert NotRegistered();
        if (!committeeMemberStates[_member].enabled) revert MemberDisabled();
        uint32 slot = slotForNextReport();
        if (!_isFinalized(slot)) revert EpochNotFinalized();
        if (computeSlotAtTimestamp(block.timestamp) < reportStartSlot) revert ReportSlotNotStarted();
        if (lastPublishedReportRefSlot != etherFiAdmin.lastHandledReportRefSlot()) revert LastReportNotHandled();

        return slot > committeeMemberStates[_member].lastReportRefSlot;
    }

    /**
     * @notice Verify a report
     * @param _report The report
     */
    function verifyReport(OracleReport calldata _report) public view {
        if (_report.consensusVersion != consensusVersion) revert WrongConsensusVersion();

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = blockStampForNextReport();
        if (_report.refSlotFrom != slotFrom) revert WrongSlotFrom();
        if (_report.refSlotTo != slotTo) revert WrongSlotTo();
        if (_report.refBlockFrom != blockFrom) revert WrongBlockFrom();
        if (_report.refBlockTo >= block.number) revert WrongBlockTo();
        if (_report.refBlockTo <= etherFiAdmin.lastAdminExecutionBlock()) revert ReportBlockTooOld();

        // If two epochs in a row are justified, the current_epoch - 2 is considered finalized
        // Put 1 epoch more as a safe buffer
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 currEpoch = (currSlot / SLOTS_PER_EPOCH);
        uint32 reportEpoch = (_report.refSlotTo / SLOTS_PER_EPOCH);
        if (reportEpoch + 2 >= currEpoch) revert EpochNotFinalized();
    }

    /**
     * @notice Check if the consensus has reached
     * @param _hash The hash of the report
     * @return True if the consensus has reached, false otherwise
     */
    function isConsensusReached(bytes32 _hash) public view returns (bool) {
        return consensusStates[_hash].consensusReached;
    }

    /**
     * @notice Get the consensus timestamp
     * @param _hash The hash of the report
     * @return The consensus timestamp
     */
    function getConsensusTimestamp(bytes32 _hash) public view returns (uint32) {
        if (!consensusStates[_hash].consensusReached) revert ConsensusNotReached();
        return consensusStates[_hash].consensusTimestamp;
    }

    /**
     * @notice Get the consensus slot
     * @param _hash The hash of the report
     * @return The consensus slot
     */
    function getConsensusSlot(bytes32 _hash) public view returns (uint32) {
        if (!consensusStates[_hash].consensusReached) revert ConsensusNotReached();
        return computeSlotAtTimestamp(consensusStates[_hash].consensusTimestamp);
    }

    /**
     * @notice Get the next report's slot to
     * @return The next report's slot to
     * @dev Given the last published report AND the current slot number,
     *      Return the next report's `slotTo` that we are waiting for
     */
    function slotForNextReport() public view returns (uint32) {
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 pastSlot = reportStartSlot < lastPublishedReportRefSlot ? lastPublishedReportRefSlot + 1 : reportStartSlot;
        uint32 diff = currSlot > pastSlot ? currSlot - pastSlot : 0;
        uint32 tmp = pastSlot + (diff / reportPeriodSlot) * reportPeriodSlot;
        uint32 __slotForNextReport = (tmp > pastSlot + reportPeriodSlot) ? tmp : pastSlot + reportPeriodSlot;
        return __slotForNextReport - 1;
    }

    /**
     * @notice Compute the slot at a given timestamp
     * @param timestamp The timestamp
     * @return The slot at the given timestamp
     */
    function computeSlotAtTimestamp(uint256 timestamp) public view returns (uint32) {
        return uint32((timestamp - BEACON_GENESIS_TIME) / SECONDS_PER_SLOT);
    }

    /**
     * @notice Generate the report hash
     * @param _report The report
     * @return The report hash
     */
    function generateReportHash(OracleReport calldata _report) public pure returns (bytes32) {
        bytes32 chunk1 = keccak256(
            abi.encode(
                _report.consensusVersion,
                _report.refSlotFrom,
                _report.refSlotTo,
                _report.refBlockFrom,
                _report.refBlockTo,
                _report.accruedRewards,
                _report.protocolFees
            )
        );

        bytes32 chunk2 = keccak256(
            abi.encode(
                _report.validatorsToApprove
            )
        );

       bytes32 chunk3 = keccak256(
            abi.encode(
                _report.lastFinalizedWithdrawalRequestId,
                _report.finalizedWithdrawalAmount
            )
        );
        return keccak256(abi.encode(chunk1, chunk2, chunk3));
    }

    /**
     * @notice Get the beacon genesis timestamp
     * @return The beacon genesis timestamp
     */
    function beaconGenesisTimestamp() external view returns (uint32) {
        return BEACON_GENESIS_TIME;
    }

    /**
     * @notice Get the implementation address
     * @return The implementation address
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
