pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./RoleRegistry.sol";

contract EtherFiRewardsRouter is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    address public immutable treasury;
    address public immutable liquidityPool;
    RoleRegistry public immutable roleRegistry;

    bytes32 public constant ETHERFI_REWARDS_ROUTER_ADMIN_ROLE = keccak256("ETHERFI_REWARDS_ROUTER_ADMIN_ROLE");

    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event UpdatedTreasury(address indexed treasury);
    event Erc20Sent(address indexed caller, address indexed token, uint256 amount);
    event Erc721Sent(address indexed caller, address indexed token, uint256 tokenId);

    error IncorrectRole();

    constructor(address _liquidityPool, address _treasury, address _roleRegistry) {
        _disableInitializers();
        liquidityPool = _liquidityPool;
        treasury = _treasury;
        roleRegistry = RoleRegistry(_roleRegistry);
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    function initialize() public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    function withdrawToLiquidityPool() external {
        uint256 balance = address(this).balance;
        require(balance > 0, "Contract balance is zero");
        (bool success,) = liquidityPool.call{value: balance}("");
        require(success, "TRANSFER_FAILED");

        emit EthSent(address(this), liquidityPool, balance);
    }

    function recoverERC20(address _token, uint256 _amount) external {
        if (!roleRegistry.hasRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        IERC20(_token).safeTransfer(treasury, _amount);

        emit Erc20Sent(msg.sender, _token, _amount);
    }

    function recoverERC721(address _token, uint256 _tokenId) external {
        if (!roleRegistry.hasRole(ETHERFI_REWARDS_ROUTER_ADMIN_ROLE, msg.sender)) revert IncorrectRole();

        IERC721(_token).transferFrom(address(this), treasury, _tokenId);

        emit Erc721Sent(msg.sender, _token, _tokenId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
