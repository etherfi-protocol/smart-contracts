pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

contract EtherFiRewardsRouter is OwnableUpgradeable, UUPSUpgradeable  {
    address public liquidityPoolAddress;

    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);

    constructor() {
        _disableInitializers();
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    function initialize(address _liquidityPoolAddress) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        liquidityPoolAddress = _liquidityPoolAddress;
    }

    function transferToLiquidityPool() external {
        uint256 balance = address(this).balance;
        require(balance > 0, "Contract balance is zero");
        (bool success, ) = liquidityPoolAddress.call{value: balance}("");
        require(success, "TRANSFER_FAILED");
        
        emit EthSent(address(this), liquidityPoolAddress, balance);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {return _getImplementation();}
}
