// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./EtherFiAvsOperator.sol";

import "./eigenlayer-interfaces/IAVSDirectory.sol";
import "./eigenlayer-interfaces/IServiceManager.sol";


contract EtherFiAvsOperatorsManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    UpgradeableBeacon public upgradableBeacon;
    uint256 public nextAvsOperatorId;

    mapping(uint256 => EtherFiAvsOperator) public avsOperators;

    IDelegationManager public delegationManager;

    mapping(address => bool) public admins;
    mapping(address => bool) public pausers;

    IAVSDirectory public avsDirectory;

    // Operator -> AvsServiceManager -> whitelisted
    // This structure mirrors how Eigenlayers AvsDirectory tracks operator data
    mapping(address => mapping(address => bool)) public operatorAvsWhitelist;
    //mapping(address => mapping(address => IBLSApkRegistry.PubkeyRegistrationParams)) public operatorBLSKeys;

    // operator -> targetAddress -> selector -> allowed
    // allowed calls that AvsRunner can trigger from operator contract
    mapping(uint256 => mapping(address => mapping(bytes4 => bool))) public allowedOperatorCalls;

    event ForwardedRunnerCall(uint256 indexed id, address target, bytes4 selector, bytes data);
    event CreatedEtherFiAvsOperator(uint256 indexed id, address etherFiAvsOperator);
    event RegisteredBlsKeyAsDelegatedNodeOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers, string socket, IBLSApkRegistry.PubkeyRegistrationParams params);
    event RegisteredOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers, string socket, IBLSApkRegistry.PubkeyRegistrationParams params, ISignatureUtils.SignatureWithSaltAndExpiry operatorSignature);
    event DeregisteredOperator(uint256 indexed id, address avsServiceManager, bytes quorumNumbers);
    event RegisteredAsOperator(uint256 indexed id, IDelegationManager.OperatorDetails detail);
    event UpdatedSocket(uint256 indexed id, address avsServiceManager, string socket);
    event ModifiedOperatorDetails(uint256 indexed id, IDelegationManager.OperatorDetails newOperatorDetails);
    event UpdatedOperatorMetadataURI(uint256 indexed id, string metadataURI);
    event UpdatedAvsNodeRunner(uint256 indexed id, address avsNodeRunner);
    event UpdatedAvsWhitelist(uint256 indexed id, address avsServiceManager, bool isWhitelisted);
    event UpdatedEcdsaSigner(uint256 indexed id, address ecdsaSigner);

     /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize to set variables on deployment
    function initialize(address _delegationManager, address _avsDirectory, address _etherFiAvsOperatorImpl) external initializer {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();

        nextAvsOperatorId = 1;
        upgradableBeacon = new UpgradeableBeacon(_etherFiAvsOperatorImpl);      
        delegationManager = IDelegationManager(_delegationManager);
        avsDirectory = IAVSDirectory(_avsDirectory);
    }

    function initializeAvsDirectory(address _avsDirectory) external onlyOwner {
        avsDirectory = IAVSDirectory(_avsDirectory);
    }



    //--------------------------------------------------------------------------------------
    //---------------------------------  Eigenlayer Core  ----------------------------------
    //--------------------------------------------------------------------------------------


    // This registers the operator contract as delegatable operator within Eigenlayer's core contracts.
    // Once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself"
    function registerAsOperator(uint256 _id, IDelegationManager.OperatorDetails calldata _detail, string calldata _metaDataURI) external onlyOwner {
        avsOperators[_id].registerAsOperator(delegationManager, _detail, _metaDataURI);

        emit RegisteredAsOperator(_id, _detail);
    }

    function modifyOperatorDetails(uint256 _id, IDelegationManager.OperatorDetails calldata _newOperatorDetails) external onlyAdmin {
        avsOperators[_id].modifyOperatorDetails(delegationManager, _newOperatorDetails);

        emit ModifiedOperatorDetails(_id, _newOperatorDetails);
    }

    function updateOperatorMetadataURI(uint256 _id, string calldata _metadataURI) external onlyAdmin {
        avsOperators[_id].updateOperatorMetadataURI(delegationManager, _metadataURI);

        emit UpdatedOperatorMetadataURI(_id, _metadataURI);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  AVS Actions  ------------------------------------
    //--------------------------------------------------------------------------------------

    error InvalidOperatorCall();

    // Forward an arbitrary call to be run by the operator conract.
    // That operator must be approved for the specific method and target
    function runnerForwardCall(uint256 _id, address _target, bytes4 _selector, bytes calldata _args) external onlyOperator(_id) {

        if (!isValidOperatorCall(_id, _target, _selector, _args)) revert InvalidOperatorCall();

        avsOperators[_id].forwardCall(_target, abi.encodePacked(_selector, _args));
        emit ForwardedRunnerCall(_id, _target, _selector, _args);
    }

    // Forward an arbitrary call to be run by the operator conract.
    function adminForwardCall(uint256 _id, address _target, bytes4 _selector, bytes calldata _args) external onlyAdmin {

        avsOperators[_id].forwardCall(_target, abi.encodePacked(_selector, _args));
        emit ForwardedRunnerCall(_id, _target, _selector, _args);
    }

    function isValidOperatorCall(uint256 _id, address _target, bytes4 _selector, bytes calldata _remainingCalldata) public view returns (bool) {

        // ensure this method is allowed by this operator on target contract
        if (!allowedOperatorCalls[_id][_target][_selector]) return false;

        // could add other custom logic here that inspects payload or other data

        return true;
    }

    // This function will work for any AVS implementing the same interface as eigenDA
    function registerEigenDALikeOperator(
        uint256 _id,
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) public onlyOperator(_id) {

        avsOperators[_id].registerEigenDALikeOperator(
            _avsRegistryCoordinator,
            _quorumNumbers,
            _socket,
            _params,
            _operatorSignature
        );

        emit RegisteredOperator(_id, _avsRegistryCoordinator, _quorumNumbers, _socket, _params, _operatorSignature);
    }

    // This function will work for any AVS implementing the same interface as eigenDA
    function registerEigenDALikeOperatorWithChurn(
        uint256 _id,
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers,
        string calldata _socket,
        IBLSApkRegistry.PubkeyRegistrationParams calldata _params,
        IRegistryCoordinator.OperatorKickParam[] calldata _operatorKickParams,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _churnApproverSignature,
        ISignatureUtils.SignatureWithSaltAndExpiry memory _operatorSignature
    ) external onlyOperator(_id) {

        avsOperators[_id].registerEigenDALikeOperatorWithChurn(
            _avsRegistryCoordinator,
            _quorumNumbers,
            _socket,
            _params,
            _operatorKickParams,
            _churnApproverSignature,
            _operatorSignature
        );
        emit RegisteredOperator(_id, _avsRegistryCoordinator, _quorumNumbers, _socket, _params, _operatorSignature);
    }

    function deregisterEigenDALikeOperator(
        uint256 _id,
        address _avsRegistryCoordinator,
        bytes calldata _quorumNumbers
    ) external onlyOperator(_id) {
        avsOperators[_id].deregisterEigenDALikeOperator(_avsRegistryCoordinator, _quorumNumbers);

        emit DeregisteredOperator(_id, _avsRegistryCoordinator, _quorumNumbers);
    }


    //--------------------------------------------------------------------------------------
    //--------------------------------  Ether.fi Operators  --------------------------------
    //--------------------------------------------------------------------------------------

    function updateAvsNodeRunner(uint256 _id, address _avsNodeRunner) external onlyAdmin {
        avsOperators[_id].updateAvsNodeRunner(_avsNodeRunner);

        emit UpdatedAvsNodeRunner(_id, _avsNodeRunner);
    }

    function updateAvsWhitelist(uint256 _id, address _avsRegistryCoordinator, bool _isWhitelisted) external onlyAdmin {
        avsOperators[_id].updateAvsWhitelist(_avsRegistryCoordinator, _isWhitelisted);

        emit UpdatedAvsWhitelist(_id, _avsRegistryCoordinator, _isWhitelisted);
    }

    function updateEcdsaSigner(uint256 _id, address _ecdsaSigner) external onlyAdmin {
        avsOperators[_id].updateEcdsaSigner(_ecdsaSigner);

        emit UpdatedEcdsaSigner(_id, _ecdsaSigner);
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------------  Admin  ---------------------------------------
    //--------------------------------------------------------------------------------------

    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function upgradeEtherFiAvsOperator(address _newImplementation) public onlyOwner {
        upgradableBeacon.upgradeTo(_newImplementation);
    }

    function instantiateEtherFiAvsOperator(uint256 _nums) external onlyOwner returns (uint256[] memory _ids) {
        _ids = new uint256[](_nums);
        for (uint256 i = 0; i < _nums; i++) {
            _ids[i] = _instantiateEtherFiAvsOperator();
        }
    }

    function _instantiateEtherFiAvsOperator() internal returns (uint256 _id) {
        _id = nextAvsOperatorId++;
        require(address(avsOperators[_id]) == address(0), "INVALID_ID");

        BeaconProxy proxy = new BeaconProxy(address(upgradableBeacon), "");
        avsOperators[_id] = EtherFiAvsOperator(address(proxy));
        avsOperators[_id].initialize(address(this));

        emit CreatedEtherFiAvsOperator(_id, address(avsOperators[_id]));

        return _id;
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------  View Functions  -------------------------------------
    //--------------------------------------------------------------------------------------

    // TODO: Rework to check registration status from AvsDirectory
    /*
    /// @param _id The id of etherfi avs operator
    /// @param _avsServiceManager The AVS's service manager contract address
    function avsOperatorStatus(uint256 _id, address _avsServiceManager) external view returns (IAVSDirectory.OperatorAVSRegistrationStatus) {
        return avsDirectory.avsOperatorStatus(_avsServiceManager, address(avsOperators[_id]));
    }
    */

    function isAvsWhitelisted(uint256 _id, address _avsRegistryCoordinator) external view returns (bool) {
        return avsOperators[_id].isAvsWhitelisted(_avsRegistryCoordinator);
    }

    function avsNodeRunner(uint256 _id) external view returns (address) {
        return avsOperators[_id].avsNodeRunner();
    }

    function ecdsaSigner(uint256 _id) external view returns (address) {
        return avsOperators[_id].ecdsaSigner();
    }

    function operatorDetails(uint256 _id) external view returns (IDelegationManager.OperatorDetails memory) {
        return delegationManager.operatorDetails(address(avsOperators[_id]));
    }

    // DEPRECATED
    function getAvsInfo(uint256 _id, address _avsRegistryCoordinator) external view returns (EtherFiAvsOperator.AvsInfo memory) {
         return avsOperators[_id].getAvsInfo(_avsRegistryCoordinator);
    }


    /**
     * @notice Calculates the digest hash to be signed by an operator to register with an AVS
     * @param _id The id of etherfi avs operator
     * @param _avsServiceManager The AVS's service manager contract address
     * @param _salt A unique and single use value associated with the approver signature.
     * @param _expiry Time after which the approver's signature becomes invalid
     */
    function calculateOperatorAVSRegistrationDigestHash(uint256 _id, address _avsServiceManager, bytes32 _salt, uint256 _expiry) external view returns (bytes32) {
        address _operator = address(avsOperators[_id]);
        return avsDirectory.calculateOperatorAVSRegistrationDigestHash(_operator, _avsServiceManager, _salt, _expiry);
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  Modifiers  -------------------------------------
    //--------------------------------------------------------------------------------------

    function _onlyAdmin() internal view {
        require(admins[msg.sender] || msg.sender == owner(), "INCORRECT_CALLER");
    }

    function _onlyOperator(uint256 _id) internal view {
        require(msg.sender == avsOperators[_id].avsNodeRunner() || admins[msg.sender] || msg.sender == owner(), "INCORRECT_CALLER");
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyOperator(uint256 _id) {
        _onlyOperator(_id);
        _;
    }

}
