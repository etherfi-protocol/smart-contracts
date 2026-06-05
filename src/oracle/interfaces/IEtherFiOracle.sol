// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IEtherFiOracle {
    struct OracleReport {
        uint32 consensusVersion;
        uint32 refSlotFrom;
        uint32 refSlotTo;
        uint32 refBlockFrom;
        uint32 refBlockTo;
        int128 accruedRewards;
        uint128 protocolFees;
        uint256[] validatorsToApprove;
        uint32 lastFinalizedWithdrawalRequestId;
        uint128 finalizedWithdrawalAmount;
    }

    struct CommitteeMemberState {
        bool registered;
        bool enabled;
        uint32 lastReportRefSlot;
        uint32 numReports;
    }

    struct ConsensusState {
        uint32 support;
        bool consensusReached;
        uint32 consensusTimestamp;
    }

    function consensusVersion() external view returns (uint32);
    function quorumSize() external view returns (uint32);
    function reportPeriodSlot() external view returns (uint32);
    function numCommitteeMembers() external view returns (uint32);
    function numActiveCommitteeMembers() external view returns (uint32);
    function lastPublishedReportRefSlot() external view returns (uint32);
    function lastPublishedReportRefBlock() external view returns (uint32);

    function submitReport(OracleReport calldata _report) external returns (bool);
    function shouldSubmitReport(address _member) external view returns (bool);
    function verifyReport(OracleReport calldata _report) external view;
    function isConsensusReached(bytes32 _hash) external view returns (bool);
    function getConsensusTimestamp(bytes32 _hash) external view returns (uint32);
    function getConsensusSlot(bytes32 _hash) external view returns (uint32);
    function generateReportHash(OracleReport calldata _report) external pure returns (bytes32);
    function computeSlotAtTimestamp(uint256 timestamp) external view returns (uint32);

    function addCommitteeMember(address _address, uint32 _quorumSize) external;
    function removeCommitteeMember(address _address, uint32 _quorumSize) external;
    function manageCommitteeMember(address _address, bool _enabled, uint32 _quorumSize) external;
    function setQuorumSize(uint32 _quorumSize) external;
    function setOracleReportPeriod(uint32 _reportPeriodSlot) external;
    function setConsensusVersion(uint32 _consensusVersion) external;
}