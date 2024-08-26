// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IStakingManager.sol";
import "./IeETH.sol";

interface ILiquidityPool {

    struct PermitInput {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    } 

    enum SourceOfFunds {
        UNDEFINED,
        EETH,
        ETHER_FAN,
        DELEGATED_STAKING
    }

    struct FundStatistics {
        uint32 numberOfValidators;
        uint32 targetWeight;
    }

    // Necessary to preserve "statelessness" of dutyForWeek().
    // Handles case where new users join/leave holder list during an active slot
    struct HoldersUpdate {
        uint32 timestamp;
        uint32 startOfSlotNumOwners;
    }

    struct BnftHolder {
        address holder;
    }

    struct BnftHoldersIndex {
        bool registered;
    }

    function numPendingDeposits() external view returns (uint32);
    function totalValueOutOfLp() external view returns (uint128);
    function totalValueInLp() external view returns (uint128);
    function getTotalEtherClaimOf(address _user) external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
    function sharesForAmount(uint256 _amount) external view returns (uint256);
    function sharesForWithdrawalAmount(uint256 _amount) external view returns (uint256);
    function amountForShare(uint256 _share) external view returns (uint256);
    function eETH() external view returns (IeETH);

    function deposit() external payable returns (uint256);
    function deposit(address _referral) external payable returns (uint256);
    function deposit(address _user, address _referral) external payable returns (uint256);
    function depositToRecipient(address _recipient, uint256 _amount, address _referral) external returns (uint256);
    function withdraw(address _recipient, uint256 _amount) external returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
    function requestWithdrawWithPermit(address _owner, uint256 _amount, PermitInput calldata _permit) external returns (uint256);
    function requestMembershipNFTWithdraw(address recipient, uint256 amount, uint256 fee) external returns (uint256);

    function batchDeposit(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators) external payable returns (uint256[] memory);
    function batchDeposit(uint256[] calldata _candidateBidIds, uint256 _numberOfValidators, uint256 _validatorIdToCoUseWithdrawalSafe) external payable returns (uint256[] memory);
    function batchRegister(uint256[] calldata _validatorIds, IStakingManager.DepositData[] calldata _registerValidatorDepositData, bytes32[] calldata _depositDataRootApproval, bytes[] calldata _signaturesForApprovalDeposit) external;
    function batchApproveRegistration(uint256[] memory _validatorIds, bytes[] calldata _pubKey, bytes[] calldata _signature) external;
    function batchCancelDeposit(uint256[] calldata _validatorIds) external;
    function sendExitRequests(uint256[] calldata _validatorIds) external;

    function rebase(int128 _accruedRewards) external;
    function payProtocolFees(uint128 _protocolFees) external;
}
