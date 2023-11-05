// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;


import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";

import "./interfaces/IEtherFiOracle.sol";
import "./interfaces/IEtherFiAdmin.sol";

import "forge-std/console.sol";

contract EtherFiOracle is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, IEtherFiOracle {

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

    IEtherFiAdmin etherFiAdmin;

    event CommitteeMemberAdded(address indexed member);
    event CommitteeMemberRemoved(address indexed member);
    event CommitteeMemberUpdated(address indexed member, bool enabled);
    event QuorumUpdated(uint32 newQuorumSize);
    event ConsensusVersionUpdated(uint32 newConsensusVersion);
    event OracleReportPeriodUpdated(uint32 newOracleReportPeriod);
    event ReportStartSlotUpdated(uint32 reportStartSlot);

    event ReportPublished(uint32 consensusVersion, uint32 refSlotFrom, uint32 refSlotTo, uint32 refBlockFrom, uint32 refBlockTo, bytes32 indexed hash);
    event ReportSubmitted(uint32 consensusVersion, uint32 refSlotFrom, uint32 refSlotTo, uint32 refBlockFrom, uint32 refBlockTo, bytes32 indexed hash, address indexed committeeMember);


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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

    function submitReport(OracleReport calldata _report) external whenNotPaused returns (bool) {
        bytes32 reportHash = generateReportHash(_report);
        require(!consensusStates[reportHash].consensusReached, "Consensus already reached");
        require(shouldSubmitReport(msg.sender), "You don't need to submit a report");
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

    // For generating the next report, the starting & ending points need to be specified.
    // The report should include data for the specified slot and block ranges (inclusive)
    function blockStampForNextReport() public view returns (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) {
        slotFrom = lastPublishedReportRefSlot == 0 ? reportStartSlot : lastPublishedReportRefSlot + 1;
        slotTo = slotForNextReport();
        blockFrom = lastPublishedReportRefBlock == 0 ? reportStartSlot : lastPublishedReportRefBlock + 1;
        // `blockTo` can't be decided since a slot may not have any block (`missed slot`)
    }

    function shouldSubmitReport(address _member) public view returns (bool) {
        require(committeeMemberStates[_member].registered, "You are not registered as the Oracle committee member");
        require(committeeMemberStates[_member].enabled, "You are disabled");
        uint32 slot = slotForNextReport();
        require(_isFinalized(slot), "Report Epoch is not finalized yet");
        require(computeSlotAtTimestamp(block.timestamp) >= reportStartSlot, "Report Slot has not started yet");
        require(lastPublishedReportRefSlot == etherFiAdmin.lastHandledReportRefSlot(), "Last published report is not handled yet");
        return slot > committeeMemberStates[_member].lastReportRefSlot;
    }

    function verifyReport(OracleReport calldata _report) public view {
        require(_report.consensusVersion == consensusVersion, "Report is for wrong consensusVersion");

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) = blockStampForNextReport();
        require(_report.refSlotFrom == slotFrom, "Report is for wrong slotFrom");
        require(_report.refSlotTo == slotTo, "Report is for wrong slotTo");
        require(_report.refBlockFrom == blockFrom, "Report is for wrong blockFrom");
        require(_report.refBlockTo < block.number, "Report is for wrong blockTo");

        // If two epochs in a row are justified, the current_epoch - 2 is considered finalized
        // Put 1 epoch more as a safe buffer
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 currEpoch = (currSlot / SLOTS_PER_EPOCH);
        uint32 reportEpoch = (_report.refSlotTo / SLOTS_PER_EPOCH);
        require(reportEpoch + 2 < currEpoch, "Report Epoch is not finalized yet");
    }

    function isConsensusReached(bytes32 _hash) public view returns (bool) {
        return consensusStates[_hash].consensusReached;
    }

    function getConsensusTimestamp(bytes32 _hash) public view returns (uint32) {
        require(consensusStates[_hash].consensusReached, "Consensus is not reached yet");
        return consensusStates[_hash].consensusTimestamp;
    }

    function getConsensusSlot(bytes32 _hash) public view returns (uint32) {
        require(consensusStates[_hash].consensusReached, "Consensus is not reached yet");
        return computeSlotAtTimestamp(consensusStates[_hash].consensusTimestamp);
    }

    function _isFinalized(uint32 _slot) internal view returns (bool) {
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 currEpoch = (currSlot / SLOTS_PER_EPOCH);
        uint32 slotEpoch = (_slot / SLOTS_PER_EPOCH);
        return slotEpoch + 2 < currEpoch;
    }

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

    // Given the last published report AND the current slot number,
    // Return the next report's `slotTo` that we are waiting for
    function slotForNextReport() public view returns (uint32) {
        uint32 currSlot = computeSlotAtTimestamp(block.timestamp);
        uint32 pastSlot = reportStartSlot < lastPublishedReportRefSlot ? lastPublishedReportRefSlot + 1 : reportStartSlot;
        uint32 diff = currSlot > pastSlot ? currSlot - pastSlot : 0;
        uint32 tmp = pastSlot + (diff / reportPeriodSlot) * reportPeriodSlot;
        uint32 __slotForNextReport = (tmp > pastSlot + reportPeriodSlot) ? tmp : pastSlot + reportPeriodSlot;
        return __slotForNextReport - 1;
    }

    function computeSlotAtTimestamp(uint256 timestamp) public view returns (uint32) {
        return uint32((timestamp - BEACON_GENESIS_TIME) / SECONDS_PER_SLOT);
    }

    function generateReportHash(OracleReport calldata _report) public pure returns (bytes32) {
        bytes32 chunk1 = keccak256(
            abi.encode(
                _report.consensusVersion,
                _report.refSlotFrom,
                _report.refSlotTo,
                _report.refBlockFrom,
                _report.refBlockTo,
                _report.accruedRewards
            )
        );

        bytes32 chunk2 = keccak256(
            abi.encode(
                _report.validatorsToApprove,
                _report.liquidityPoolValidatorsToExit,
                _report.exitedValidators,
                _report.exitedValidatorsExitTimestamps,
                _report.slashedValidators
            )
        );

       bytes32 chunk3 = keccak256(
            abi.encode(
                _report.withdrawalRequestsToInvalidate,
                _report.lastFinalizedWithdrawalRequestId,
                _report.eEthTargetAllocationWeight,
                _report.etherFanTargetAllocationWeight,
                _report.finalizedWithdrawalAmount,
                _report.numValidatorsToSpinUp
            )
        );
        return keccak256(abi.encode(chunk1, chunk2, chunk3));
    }

    function beaconGenesisTimestamp() external view returns (uint32) {
        return BEACON_GENESIS_TIME;
    }

    function addCommitteeMember(address _address) public onlyOwner {
        require(committeeMemberStates[_address].registered == false, "Already registered");
        numCommitteeMembers++;
        numActiveCommitteeMembers++;
        committeeMemberStates[_address] = CommitteeMemberState(true, true, 0, 0);

        emit CommitteeMemberAdded(_address);
    }

    function removeCommitteeMember(address _address) public onlyOwner {
        require(committeeMemberStates[_address].registered == true, "Not registered");
        numCommitteeMembers--;
        if (committeeMemberStates[_address].enabled) numActiveCommitteeMembers--;
        delete committeeMemberStates[_address];

        emit CommitteeMemberRemoved(_address);
    }

    function manageCommitteeMember(address _address, bool _enabled) public onlyOwner {
        require(committeeMemberStates[_address].registered == true, "Not registered");
        require(committeeMemberStates[_address].enabled != _enabled, "Already in the target state");
        committeeMemberStates[_address].enabled = _enabled;
        if (_enabled) {
            numActiveCommitteeMembers++;
        } else {
            numActiveCommitteeMembers--;
        }

        emit CommitteeMemberUpdated(_address, _enabled);
    }

    function setReportStartSlot(uint32 _reportStartSlot) public onlyOwner {
        // check if the start slot is at the beginning of the epoch
        require(_reportStartSlot > computeSlotAtTimestamp(block.timestamp), "The start slot should be in the future");
        require(_reportStartSlot > lastPublishedReportRefSlot, "The start slot should be after the last published report");
        require(_reportStartSlot % SLOTS_PER_EPOCH == 0, "The start slot should be at the beginning of the epoch");
        reportStartSlot = _reportStartSlot;
        
        emit ReportStartSlotUpdated(_reportStartSlot);
    }

    function setQuorumSize(uint32 _quorumSize) public onlyOwner {
        quorumSize = _quorumSize;

        emit QuorumUpdated(_quorumSize);
    }

    function setOracleReportPeriod(uint32 _reportPeriodSlot) public onlyOwner {
        require(_reportPeriodSlot != 0, "Report period cannot be zero");
        require(_reportPeriodSlot % SLOTS_PER_EPOCH == 0, "Report period must be a multiple of the epoch");
        reportPeriodSlot = _reportPeriodSlot;

        emit OracleReportPeriodUpdated(_reportPeriodSlot);
    }

    function setConsensusVersion(uint32 _consensusVersion) public onlyOwner {
        require(_consensusVersion > consensusVersion, "New consensus version must be greater than the current one");
        consensusVersion = _consensusVersion;

        emit ConsensusVersionUpdated(_consensusVersion);
    }

    function setEtherFiAdmin(address _etherFiAdminAddress) external onlyOwner {
        require(etherFiAdmin == IEtherFiAdmin(address(0)), "EtherFiAdmin is already set");
        etherFiAdmin = IEtherFiAdmin(_etherFiAdminAddress);
    }
    
    function unpublishReport(bytes32 _hash) external onlyOwner {
        require(consensusStates[_hash].consensusReached, "Consensus is not reached yet");
        consensusStates[_hash].support = 0;
        consensusStates[_hash].consensusReached = false;
    }

    function updateLastPublishedBlockStamps(uint32 _lastPublishedReportRefSlot, uint32 _lastPublishedReportRefBlock) external onlyOwner {
        lastPublishedReportRefSlot = _lastPublishedReportRefSlot;
        lastPublishedReportRefBlock = _lastPublishedReportRefBlock;
    }

    function pauseContract() external onlyOwner {
        _pause();
    }

    function unPauseContract() external onlyOwner {
        _unpause();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
