// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface EtherFiProxy {
    function getImplementation() external view returns (address);
}

contract AddressProvider {

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    struct ContractData {
        address contractAddress;
        string name;
    }

    mapping(string => ContractData) public contracts;
    uint256 public numberOfContracts;

    address public owner;

    event ContractAdded(address contractAddress, string name);
    event ContractRemoved(address contractAddress, string name);

    constructor(address _owner) {
        owner = _owner;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Adds contracts to the address provider that have already been deployed
    /// @dev Only called by the contract owner
    /// @param _contractAddress the proxy address of the contract we are adding
    /// @param _name the name of the contract for reference
    function addContract(address _contractAddress, string memory _name) external onlyOwner {
        require(contracts[_name].contractAddress == address(0), "Contract already exists");
        contracts[_name] = ContractData({
            contractAddress: _contractAddress,
            name: _name
        });
        numberOfContracts++;

        emit ContractAdded(_contractAddress, _name);
    }

    /// @notice Removes a contract
    /// @dev Only called by the contract owner
    /// @param _name the name of the contract for reference
    function removeContract(string memory _name) external onlyOwner {
        ContractData memory contractData = contracts[_name];
        require(contracts[_name].contractAddress != address(0), "Contract does not exist");
        
        address contractAddress = contractData.contractAddress;
        delete contracts[_name];
        numberOfContracts--;

        emit ContractRemoved(contractAddress, _name);
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  SETTER  -----------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Facilitates the change of ownership
    /// @dev Only called by the contract owner
    /// @param _newOwner the address of the new owner
    function setOwner(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Cannot be zero addr");
        owner = _newOwner;
    }

    //--------------------------------------------------------------------------------------
    //------------------------------------  GETTER  ----------------------------------------
    //--------------------------------------------------------------------------------------

    function getContractAddress(string memory _name) external view returns (address) {
        return contracts[_name].contractAddress;
    }

    function getImplementationAddress(string memory _name) external view returns (address) {
        address localContractAddress = contracts[_name].contractAddress;
        try EtherFiProxy(localContractAddress).getImplementation() returns (address result) {
            return result;
        } catch {
            return address(0);
        }
    }

    //--------------------------------------------------------------------------------------
    //-----------------------------------  MODIFIERS  --------------------------------------
    //--------------------------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner function");
        _;
    }
}