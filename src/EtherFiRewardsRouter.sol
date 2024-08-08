pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import "./RoleRegistry.sol";

contract EtherFiRewardsRouter is OwnableUpgradeable, UUPSUpgradeable  {
    address public immutable liquidityPoolAddress;
    RoleRegistry public immutable roleRegistry;

    bytes32 public constant ETHERFI_ROUTER_ADMIN = keccak256("ETHERFI_ROUTER_ADMIN");

    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);

    error IncorrectRole();

    constructor(address _liquidityPoolAddress, address _roleRegistry) {
        _disableInitializers();
        liquidityPoolAddress = _liquidityPoolAddress;
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function transferToLiquidityPool() external {
        if (!roleRegistry.hasRole(ETHERFI_ROUTER_ADMIN, msg.sender)) revert IncorrectRole();
        uint256 balance = address(this).balance;
        require(balance > 0, "Contract balance is zero");
        (bool success, ) = liquidityPoolAddress.call{value: balance}("");
        require(success, "TRANSFER_FAILED");
        
        emit EthSent(address(this), liquidityPoolAddress, balance);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {return _getImplementation();}
}
