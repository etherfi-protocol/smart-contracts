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
        uint256[] validatorsToApprove;
        uint256[] liquidityPoolValidatorsToExit;
        uint256[] exitedValidators;
        uint32[]  exitedValidatorsExitTimestamps;
        uint256[] slashedValidators;
        uint256[] withdrawalRequestsToInvalidate;
        uint32 lastFinalizedWithdrawalRequestId;
        uint32 eEthTargetAllocationWeight;
        uint32 etherFanTargetAllocationWeight;
        uint128 finalizedWithdrawalAmount;
        uint32 numValidatorsToSpinUp;
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

    function addCommitteeMember(address _address) external;
    function removeCommitteeMember(address _address) external;
    function manageCommitteeMember(address _address, bool _enabled) external;
    function setQuorumSize(uint32 _quorumSize) external;
    function setOracleReportPeriod(uint32 _reportPeriodSlot) external;
    function setConsensusVersion(uint32 _consensusVersion) external;
    function setEtherFiAdmin(address _etherFiAdminAddress) external;

    function pauseContract() external;
    function unPauseContract() external;
}
