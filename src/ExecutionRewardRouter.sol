pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract EtherFiExecutionLayerRewardsRouter is OwnableUpgradeable, UUPSUpgradeable  {
    address public liquidityPoolAddress;

    event TransferToLiquidityPool(address indexed from, address indexed to, uint256 value);

    constructor() {}

    function initialize(address _liquidityPoolAddress) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        liquidityPoolAddress = _liquidityPoolAddress;
    }

    function transferToLiquidityPool() public {
        uint256 balance = address(this).balance;
        require(balance > 0, "Contract balance is zero");
        (bool success, ) = liquidityPoolAddress.call{value: balance}("");
        if(success) {
        emit TransferToLiquidityPool(address(this), liquidityPoolAddress, balance);
        }
    }

    function setLiquidityPoolAddress(address _liquidityPoolAddress) public onlyOwner {
        liquidityPoolAddress = _liquidityPoolAddress;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {return _getImplementation();}
}