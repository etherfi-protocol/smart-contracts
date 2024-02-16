// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./ILiquidityPool.sol";

interface IStakingManager {
    struct DepositData {
        bytes publicKey;
        bytes signature;
        bytes32 depositDataRoot;
        string ipfsHashForEncryptedValidatorKey;
    }

    struct StakerInfo {
        address staker;
        ILiquidityPool.SourceOfFunds sourceOfFund;
    }

    function bidIdToStaker(uint256 id) external view returns (address);

    function getEtherFiNodeBeacon() external view returns (address);

    function initialize(address _auctionAddress, address _depositContractAddress) external;
    function setEtherFiNodesManagerAddress(address _managerAddress) external;
    function setLiquidityPoolAddress(address _liquidityPoolAddress) external;
    function batchDepositWithBidIds(uint256[] calldata _candidateBidIds, address _staker, ILiquidityPool.SourceOfFunds source, bool _enableRestaking) external payable returns (uint256[] memory);
    function batchDepositWithBidIds(uint256[] calldata _candidateBidIds, bool _enableRestaking) external payable returns (uint256[] memory);

    function batchRegisterValidators(bytes32 _depositRoot, uint256[] calldata _validatorId, DepositData[] calldata _depositData) external;

    function batchRegisterValidators(bytes32 _depositRoot, uint256[] calldata _validatorId, address _bNftRecipient, address _tNftRecipient, DepositData[] calldata _depositData, address _user) external;

    function batchApproveRegistration(uint256[] memory _validatorId, bytes[] calldata _pubKey, bytes[] calldata _signature, bytes32[] calldata _depositDataRootApproval) external;

    function batchCancelDeposit(uint256[] calldata _validatorIds) external;

    function batchCancelDepositAsBnftHolder(uint256[] calldata _validatorIds, address _caller) external;

    function updateAdmin(address _address, bool _isAdmin) external;
    function pauseContract() external;
    function unPauseContract() external;
}
