
interface IAddressProvider {
    function addContract(address _contractAddress, string memory _name) external;
    function getContractAddress(string memory _name) external view returns (address);
}