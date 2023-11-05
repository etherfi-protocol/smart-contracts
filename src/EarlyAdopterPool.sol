// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EarlyAdopterPool is Ownable, ReentrancyGuard, Pausable {
    using Math for uint256;

    struct UserDepositInfo {
        uint256 depositTime;
        uint256 etherBalance;
        uint256 totalERC20Balance;
    }

    //--------------------------------------------------------------------------------------
    //---------------------------------  STATE-VARIABLES  ----------------------------------
    //--------------------------------------------------------------------------------------

    //After a certain time, claiming funds is not allowed and users will need to simply withdraw
    uint256 public claimDeadline;

    //Time when depositing closed and will be used for calculating reards
    uint256 public endTime;

    address private immutable rETH; // 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address private immutable wstETH; // 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private immutable sfrxETH; // 0xac3e018457b222d93114458476f3e3416abbe38f;
    address private immutable cbETH; // 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;

    //Future contract which funds will be sent to on claim (Most likely LP)
    address public claimReceiverContract;

    //Status of claims, 1 means claiming is open
    uint8 public claimingOpen;

    //user address => token address = balance
    mapping(address => mapping(address => uint256)) public userToErc20Balance;
    mapping(address => UserDepositInfo) public depositInfo;

    IERC20 rETHInstance;
    IERC20 wstETHInstance;
    IERC20 sfrxETHInstance;
    IERC20 cbETHInstance;

    //--------------------------------------------------------------------------------------
    //-------------------------------------  EVENTS  ---------------------------------------
    //--------------------------------------------------------------------------------------

    event DepositERC20(address indexed sender, uint256 amount);
    event DepositEth(address indexed sender, uint256 amount);
    event Withdrawn(address indexed sender);
    event ClaimReceiverContractSet(address indexed receiverAddress);
    event ClaimingOpened(uint256 deadline);
    event Fundsclaimed(
        address indexed user,
        uint256 indexed pointsAccumulated
    );
    event ERC20TVLUpdated(
        uint256 rETHBal,
        uint256 wstETHBal,
        uint256 sfrxETHBal,
        uint256 cbETHBal,
        uint256 ETHBal,
        uint256 tvl
    );

    event EthTVLUpdated(uint256 ETHBal, uint256 tvl);

    /// @notice Allows ether to be sent to this contract
    receive() external payable {}

    //--------------------------------------------------------------------------------------
    //----------------------------------  CONSTRUCTOR   ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Sets state variables needed for future functions
    /// @param _rETH address of the rEth contract to receive
    /// @param _wstETH address of the wstEth contract to receive
    /// @param _sfrxETH address of the sfrxEth contract to receive
    /// @param _cbETH address of the _cbEth contract to receive
    constructor(
        address _rETH,
        address _wstETH,
        address _sfrxETH,
        address _cbETH
    ) {
        rETH = _rETH;
        wstETH = _wstETH;
        sfrxETH = _sfrxETH;
        cbETH = _cbETH;

        rETHInstance = IERC20(_rETH);
        wstETHInstance = IERC20(_wstETH);
        sfrxETHInstance = IERC20(_sfrxETH);
        cbETHInstance = IERC20(_cbETH);
    }

    //--------------------------------------------------------------------------------------
    //----------------------------  STATE-CHANGING FUNCTIONS  ------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice deposits ERC20 tokens into contract
    /// @dev User must have approved contract before
    /// @param _erc20Contract erc20 token contract being deposited
    /// @param _amount amount of the erc20 token being deposited
    function deposit(address _erc20Contract, uint256 _amount)
        external
        OnlyCorrectAmount(_amount)
        DepositingOpen
        whenNotPaused
    {
        require(
            (_erc20Contract == rETH ||
                _erc20Contract == sfrxETH ||
                _erc20Contract == wstETH ||
                _erc20Contract == cbETH),
            "Unsupported token"
        );

        depositInfo[msg.sender].depositTime = block.timestamp;
        depositInfo[msg.sender].totalERC20Balance += _amount;
        userToErc20Balance[msg.sender][_erc20Contract] += _amount;
        require(IERC20(_erc20Contract).transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        emit DepositERC20(msg.sender, _amount);
        emit ERC20TVLUpdated(
            rETHInstance.balanceOf(address(this)),
            wstETHInstance.balanceOf(address(this)),
            sfrxETHInstance.balanceOf(address(this)),
            cbETHInstance.balanceOf(address(this)),
            address(this).balance,
            getContractTVL()
        );
    }

    /// @notice deposits Ether into contract
    function depositEther()
        external
        payable
        OnlyCorrectAmount(msg.value)
        DepositingOpen
        whenNotPaused
    {
        depositInfo[msg.sender].depositTime = block.timestamp;
        depositInfo[msg.sender].etherBalance += msg.value;

        emit DepositEth(msg.sender, msg.value);
        emit EthTVLUpdated(address(this).balance, getContractTVL());
    }

    /// @notice withdraws all funds from pool for the user calling
    /// @dev no points allocated to users who withdraw
    function withdraw() public nonReentrant {
        require(depositInfo[msg.sender].depositTime != 0, "No deposit stored");
        transferFunds(0);
        emit Withdrawn(msg.sender);
    }

    /// @notice Transfers users funds to a new contract such as LP
    /// @dev can only call once receiver contract is ready and claiming is open
    function claim() public nonReentrant {
        require(claimingOpen == 1, "Claiming not open");
        require(
            claimReceiverContract != address(0),
            "Claiming address not set"
        );
        require(block.timestamp <= claimDeadline, "Claiming is complete");
        require(depositInfo[msg.sender].depositTime != 0, "No deposit stored");

        uint256 pointsRewarded = calculateUserPoints(msg.sender);
        transferFunds(1);

        emit Fundsclaimed(msg.sender, pointsRewarded);
    }

    /// @notice Sets claiming to be open, to allow users to claim their points
    /// @param _claimDeadline the amount of time in days until claiming will close
    function setClaimingOpen(uint256 _claimDeadline) public onlyOwner {        
        claimDeadline = block.timestamp + (_claimDeadline * 86400);
        claimingOpen = 1;
        endTime = block.timestamp;

        emit ClaimingOpened(claimDeadline);
    }

    /// @notice Set the contract which will receive claimed funds
    /// @param _receiverContract contract address for where claiming will send the funds
    function setClaimReceiverContract(address _receiverContract)
        public
        onlyOwner
    {
        require(_receiverContract != address(0), "Cannot set as address zero");
        claimReceiverContract = _receiverContract;

        emit ClaimReceiverContractSet(_receiverContract);
    }

    /// @notice Calculates how many points a user currently has owed to them
    /// @return the amount of points a user currently has accumulated
    function calculateUserPoints(address _user) public view returns (uint256) {
        uint256 lengthOfDeposit;

        if (claimingOpen == 0) {
            lengthOfDeposit = block.timestamp - depositInfo[_user].depositTime;
        } else {
            lengthOfDeposit = endTime - depositInfo[_user].depositTime;
        }

        //Scaled by 1000, therefore, 1005 would be 1.005
        uint256 userMultiplier = Math.min(
            2000,
            1000 + ((lengthOfDeposit * 10) / 2592) / 10
        );
        uint256 totalUserBalance = depositInfo[_user].etherBalance +
            depositInfo[_user].totalERC20Balance;

        //Formula for calculating points total
        return
            ((Math.sqrt(totalUserBalance) * lengthOfDeposit) *
                userMultiplier) / 1e14;
    }

    //Pauses the contract
    function pauseContract() external onlyOwner {
        _pause();
    }

    //Unpauses the contract
    function unPauseContract() external onlyOwner {
        _unpause();
    }

    //--------------------------------------------------------------------------------------
    //--------------------------------  INTERNAL FUNCTIONS  --------------------------------
    //--------------------------------------------------------------------------------------

    /// @notice Transfers funds to relevant parties and updates data structures
    /// @param _identifier identifies which contract function called the function
    function transferFunds(uint256 _identifier) internal {
        uint256 rETHbal = userToErc20Balance[msg.sender][rETH];
        uint256 wstETHbal = userToErc20Balance[msg.sender][wstETH];
        uint256 sfrxEthbal = userToErc20Balance[msg.sender][sfrxETH];
        uint256 cbEthBal = userToErc20Balance[msg.sender][cbETH];

        uint256 ethBalance = depositInfo[msg.sender].etherBalance;

        depositInfo[msg.sender].depositTime = 0;
        depositInfo[msg.sender].totalERC20Balance = 0;
        depositInfo[msg.sender].etherBalance = 0;

        userToErc20Balance[msg.sender][rETH] = 0;
        userToErc20Balance[msg.sender][wstETH] = 0;
        userToErc20Balance[msg.sender][sfrxETH] = 0;
        userToErc20Balance[msg.sender][cbETH] = 0;

        address receiver;

        if (_identifier == 0) {
            receiver = msg.sender;
        } else {
            receiver = claimReceiverContract;
        }

        require(rETHInstance.transfer(receiver, rETHbal), "Transfer failed");
        require(wstETHInstance.transfer(receiver, wstETHbal), "Transfer failed");
        require(sfrxETHInstance.transfer(receiver, sfrxEthbal), "Transfer failed");
        require(cbETHInstance.transfer(receiver, cbEthBal), "Transfer failed");

        (bool sent, ) = receiver.call{value: ethBalance}("");
        require(sent, "Failed to send Ether");
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------     GETTERS  ------------------------------------
    //--------------------------------------------------------------------------------------

    /// @dev Returns the total value locked of all currencies in contract
    function getContractTVL() public view returns (uint256 tvl) {
        tvl = (rETHInstance.balanceOf(address(this)) +
            wstETHInstance.balanceOf(address(this)) +
            sfrxETHInstance.balanceOf(address(this)) +
            cbETHInstance.balanceOf(address(this)) +
            address(this).balance);
    }

    function getUserTVL(address _user)
        public
        view
        returns (
            uint256 rETHBal,
            uint256 wstETHBal,
            uint256 sfrxETHBal,
            uint256 cbETHBal,
            uint256 ethBal,
            uint256 totalBal
        )
    {
        rETHBal = userToErc20Balance[_user][rETH];
        wstETHBal = userToErc20Balance[_user][wstETH];
        sfrxETHBal = userToErc20Balance[_user][sfrxETH];
        cbETHBal = userToErc20Balance[_user][cbETH];
        ethBal = depositInfo[_user].etherBalance;
        totalBal = (rETHBal + wstETHBal + sfrxETHBal + cbETHBal + ethBal);
    }

    //--------------------------------------------------------------------------------------
    //-------------------------------------  MODIFIERS  ------------------------------------
    //--------------------------------------------------------------------------------------

    modifier OnlyCorrectAmount(uint256 _amount) {
        require(
            _amount >= 0.1 ether && _amount <= 100 ether,
            "Incorrect Deposit Amount"
        );
        _;
    }

    modifier DepositingOpen() {
        require(claimingOpen == 0, "Depositing closed");
        _;
    }
}
