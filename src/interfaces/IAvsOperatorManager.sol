// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../eigenlayer-interfaces/IDelegationManager.sol";
import "../eigenlayer-interfaces/IAVSDirectory.sol";

/**
 * @title IAvsOperatorManager
 * @author ether.fi
 */
interface IAvsOperatorManager {

    function avsOperators(uint256 _id) external returns (address);
    function registerAsOperator(uint256 _id, address _delegationApprover, uint32 _allocationDelay, string calldata _metaDataURI) external;
    function modifyOperatorDetails(uint256 _id, address _delegationApprover) external;
    function updateOperatorMetadataURI(uint256 _id, string calldata _metadataURI) external;
    function forwardOperatorCall(uint256 _id, address _target, bytes4 _selector, bytes calldata _args) external;
    function forwardOperatorCall(uint256 _id, address _target, bytes calldata _input) external;
    function adminForwardCall(uint256 _id, address _target, bytes4 _selector, bytes calldata _args) external;
    function isValidOperatorCall(uint256 _id, address _target, bytes4 _selector, bytes calldata) external returns (bool);
    function isValidAdminCall(address _target, bytes4 _selector, bytes calldata) external view returns (bool);
    function updateAllowedOperatorCalls(uint256 _operatorId, address _target, bytes4 _selector, bool _allowed) external;
    function updateAllowedAdminCalls(address _target, bytes4 _selector, bool _allowed) external;
    function updateAvsNodeRunner(uint256 _id, address _avsNodeRunner) external;
    function updateEcdsaSigner(uint256 _id, address _ecdsaSigner) external;
    function upgradeEtherFiAvsOperator(address _newImplementation) external;
    function instantiateEtherFiAvsOperator(uint256 _nums) external returns (uint256[] memory _ids);
    function avsNodeRunner(uint256 _id) external view returns (address);
    function ecdsaSigner(uint256 _id) external view returns (address);
    function calculateOperatorAVSRegistrationDigestHash(uint256 _id, address _avsServiceManager, bytes32 _salt, uint256 _expiry) external view returns (bytes32);

    //---------------------------------------------------------------------------
    //-----------------------------  Events  -----------------------------------
    //---------------------------------------------------------------------------

    event ForwardedOperatorCall(uint256 indexed id, address indexed target, bytes4 indexed selector, bytes data, address sender);
    event CreatedEtherFiAvsOperator(uint256 indexed id, address etherFiAvsOperator);
    event ModifiedOperatorDetails(uint256 indexed id, IDelegationManager.OperatorDetails newOperatorDetails);
    event UpdatedOperatorMetadataURI(uint256 indexed id, string metadataURI);
    event UpdatedAvsNodeRunner(uint256 indexed id, address avsNodeRunner);
    event UpdatedEcdsaSigner(uint256 indexed id, address ecdsaSigner);
    event AllowedOperatorCallsUpdated(uint256 indexed id, address indexed target, bytes4 indexed selector, bool allowed);
    event AllowedAdminCallsUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event AdminUpdated(address indexed admin, bool isAdmin);

    //--------------------------------------------------------------------------
    //-----------------------------  Errors  -----------------------------------
    //--------------------------------------------------------------------------

    error IncorrectRole();
    error InvalidOperatorCall();
    error InvalidAdminCall();

}
