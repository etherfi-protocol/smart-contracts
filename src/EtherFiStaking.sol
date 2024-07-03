

/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;


import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EtherFi Staking Contract
 * @notice This contract allows users to stake ETHFI tokens, earn votes through delegation, and withdraw their staked tokens. 
 * Users can delegate their votes to another address or self-delegate if no delegation is specified. The contract uses 
 * OpenZeppelin upgradeable libraries for security and upgradability, including Ownable, Pausable, and ReentrancyGuard. 
 * It ensures safe ERC20 token transfers and maintains mappings for user balances, delegations, and vote counts. 
 * Key functionalities include deposit, withdraw, balance checking, and vote delegation management.
 */

contract EtherFiStaking is Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public ethfiToken;

    mapping(address => uint256) private _balances; // from user address to their staked balance
    mapping(address => address) private _delegation; // from user address to their delegatee
    mapping(address => uint256) private _votes; // from delegatee address to their total votes

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _ethfiToken) initializer external {
        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        ethfiToken = IERC20(_ethfiToken);
    }

    /// @notice deposit ETHFI tokens to stake
    /// @param amount The amount of ETHFI tokens to deposit
    /// @param delegatee The address to delegate the votes to
    // - If the user is already delegating, undelegate and move the whole votes to the new delegatee
    function deposit(uint256 amount, address delegatee) external whenNotPaused nonReentrant checkDepositInvariant(amount, delegatee) {
        require(amount > 0, "Deposit amount must be greater than zero");
        require(delegatee != address(0), "Delegatee cannot be zero address");

        // If the user is not delegating to the delegatee, undelegate
        if (delegates(msg.sender) != delegatee) {
            _undelegate(msg.sender);
        }

        assert(delegates(msg.sender) == address(0) || delegates(msg.sender) == delegatee);

        // Update the user's staked balance
        _balances[msg.sender] += amount;

        if (delegates(msg.sender) == address(0)) {
            // If the user is not delegating to anyone, delegate to themself
            _delegate(msg.sender, delegatee);
        } else {
            // If the user is already delegating, move the `amount` votes to the delegatee
            _moveDelegateVotes(address(0), delegates(msg.sender), amount);
        }

        // Transfer the tokens to the contract
        ethfiToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(msg.sender, amount);
    }

    /// @notice unstake and withdraw ETHFI tokens
    /// @param amount The amount of ETHFI tokens to withdraw
    function withdraw(uint256 amount) external whenNotPaused nonReentrant checkWithdrawInvariant(amount) {
        require(amount > 0, "Withdrawal amount must be greater than zero");
        require(_balances[msg.sender] >= amount, "Insufficient balance for withdrawal");

        // Update the user's staked balance
        _balances[msg.sender] -= amount;

        // Reduce the delegatee's votes
        _moveDelegateVotes(delegates(msg.sender), address(0), amount);

        // Transfer the tokens to the user
        ethfiToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice delegate votes to a delegatee
    /// @param delegatee The address to delegate the votes to
    // If the `msg.sender` is already delegating, it will move the votes to the new delegatee
    function delegate(address delegatee) external whenNotPaused {
        _delegate(msg.sender, delegatee);
    }

    /// @notice staked balance of a user
    /// @param user The address of the user
    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    /**
     * @dev Returns the current amount of votes that `account` has.
     */
    function getVotes(address account) public view virtual returns (uint256) {
        return _votes[account];
    }

    /**
     * @dev Returns the delegate that `account` has chosen.
     */
    function delegates(address account) public view virtual returns (address) {
        return _delegation[account];
    }

    function _moveDelegateVotes(
        address from,
        address to,
        uint256 amount
    ) private {
        if (from != to && amount > 0) {
            if (from != address(0)) {
                uint256 oldValue = _votes[from];
                uint256 newValue = oldValue - amount;
                _votes[from] = newValue;
                emit DelegateVotesChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                uint256 oldValue = _votes[to];
                uint256 newValue = oldValue + amount;
                _votes[to] = newValue;
                emit DelegateVotesChanged(to, oldValue, newValue);
            }
        }
    }
    
    /**
     * @dev Delegate all of `account`'s voting units to `delegatee`.
     *
     * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
     */
    function _delegate(address account, address delegatee) internal virtual {
        address oldDelegate = delegates(account);
        _delegation[account] = delegatee;

        emit DelegateChanged(account, oldDelegate, delegatee);
        _moveDelegateVotes(oldDelegate, delegatee, _getVotingUnits(account));
    }

    // undelegate and get the votes back to `account`
    function _undelegate(address account) internal virtual {
        address oldDelegate = delegates(account);
        _delegation[account] = address(0);

        emit DelegateChanged(account, oldDelegate, address(0));
        _moveDelegateVotes(oldDelegate, address(0), _getVotingUnits(account));
    }

    function _getVotingUnits(address account) internal view virtual returns (uint256) {
        return _balances[account];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Modifier to check the invariant after deposit
    modifier checkDepositInvariant(uint256 amount, address delegatee) {
        uint256 contractTokenBalance = ethfiToken.balanceOf(address(this));
        _;
        require(ethfiToken.balanceOf(address(this)) == contractTokenBalance + amount, "Invariant check failed after deposit");
        require(delegates(msg.sender) == delegatee, "Invariant check failed after deposit");
    }

    /// @dev Modifier to check the invariant after withdraw
    modifier checkWithdrawInvariant(uint256 amount) {
        uint256 contractTokenBalance = ethfiToken.balanceOf(address(this));
        _;
        require(ethfiToken.balanceOf(address(this)) == contractTokenBalance - amount, "Invariant check failed after withdrawal");
    }
}   
