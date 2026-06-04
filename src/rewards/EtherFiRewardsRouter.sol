pragma solidity ^0.8.24;

import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@etherfi/governance/utils/RolesLibrary.sol";
import "@etherfi/governance/utils/DeprecatedOZOwnable.sol";
import "@etherfi/core/interfaces/ILiquidityPool.sol";

contract EtherFiRewardsRouter is DeprecatedOZOwnable, UUPSUpgradeable, RolesLibrary {
    using SafeERC20 for IERC20;

    //--------------------------------------------------------------------------------------
    //---------------------------------  IMMUTABLES  --------------------------------------
    //--------------------------------------------------------------------------------------
    address public immutable treasury;
    address public immutable liquidityPool;

    //--------------------------------------------------------------------------------------
    //---------------------------------  EVENTS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    event EthReceived(address indexed from, uint256 value);
    event EthSent(address indexed from, address indexed to, uint256 value);
    event UpdatedTreasury(address indexed treasury);
    event Erc20Sent(address indexed caller, address indexed token, uint256 amount);
    event Erc721Sent(address indexed caller, address indexed token, uint256 tokenId);

    //--------------------------------------------------------------------------------------
    //---------------------------------  ERRORS  -------------------------------------------
    //--------------------------------------------------------------------------------------
    error ContractBalanceIsZero();
    error EthTransferFailed();

    //--------------------------------------------------------------------------------------
    //---------------------------------  CONSTRUCTOR  --------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Constructor
     * @param _liquidityPool The address of the liquidity pool
     * @param _treasury The address of the treasury
     * @param _roleRegistry The address of the role registry
     */
    constructor(address _liquidityPool, address _treasury, address _roleRegistry) RolesLibrary(_roleRegistry) {
        _disableInitializers();
        liquidityPool = _liquidityPool;
        treasury = _treasury;
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INITIALIZERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Initialize the EtherFiRewardsRouter
     */
    function initialize() public initializer {
        __UUPSUpgradeable_init();
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECEIVE FUNCTIONS  -------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Receive ETH
     */
    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  WITHDRAW FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Withdraw ETH to the liquidity pool
     */
    function withdrawToLiquidityPool() external {

        uint256 contractBalance = address(this).balance;
        uint256 totalValueOutOfLp = ILiquidityPool(payable(liquidityPool)).totalValueOutOfLp();
        uint256 balance = contractBalance < totalValueOutOfLp ? contractBalance : totalValueOutOfLp;
        if (balance == 0) revert ContractBalanceIsZero();
        (bool success, ) = liquidityPool.call{value: balance}("");
        if (!success) revert EthTransferFailed();
        
        emit EthSent(address(this), liquidityPool, balance);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  RECOVERY FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Recover ERC20 tokens
     * @param _token The address of the token
     * @param _amount The amount of tokens
     */
    function recoverERC20(address _token, uint256 _amount) external onlyOperatingMultisig {
        IERC20(_token).safeTransfer(treasury, _amount);

        emit Erc20Sent(msg.sender, _token, _amount);
    }

    /**
     * @notice Recover ERC721 tokens
     * @param _token The address of the token
     * @param _tokenId The ID of the token
     */
    function recoverERC721(address _token, uint256 _tokenId) external onlyOperatingMultisig {

        IERC721(_token).transferFrom(address(this), treasury, _tokenId);

        emit Erc721Sent(msg.sender, _token, _tokenId);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  INTERNAL FUNCTIONS  ------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Authorize upgrade
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgradeTimelock {}

    //--------------------------------------------------------------------------------------
    //---------------------------------  GETTERS  ------------------------------------------
    //--------------------------------------------------------------------------------------
    /**
     * @notice Get the implementation
     * @return The implementation
     */
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }
}
