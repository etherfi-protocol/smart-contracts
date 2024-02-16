// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../src/interfaces/IRateOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// Simple centralized rate oracle to be replaced by decentralized oracle
contract RateOracle is IRateOracle, Ownable {

    mapping(address => bool) public admins;

    /// @notice Last rate updated on the receiver
    uint256 public rate;

    /// @notice Last time rate was updated
    uint256 public lastUpdated;

    /// @notice Emitted when rate is updated
    /// @param newRate the rate that was updated
    event RateUpdated(uint256 newRate);

    /// @notice Information of which token and base token rate is being provided
    RateInfo public rateInfo;

    struct RateInfo {
        string tokenSymbol;
        string baseTokenSymbol;
    }

    constructor(string memory _tokenSymbol, string memory _baseTokenSymbol) {
        rateInfo.tokenSymbol = _tokenSymbol;
        rateInfo.baseTokenSymbol = _baseTokenSymbol;
    }

    error InvalidRate();

    /// @notice Gets the last stored rate in the contract
    function getRate() external view returns (uint256) {
        if (rate == 0) revert InvalidRate();
        return rate;
    }

    /// @notice Sets the new rate
    function setRate(uint256 _rate) external onlyAdmin {

        // sanity check that rate is within 10% of the value of eth.
        // This contract will be deprecated once we have the cross chain price feed
        uint256 tenPercent = 1e18/10;
        uint256 lowerBound = 1e18 - tenPercent;
        uint256 upperBound = 1e18 + tenPercent;
        if (_rate < lowerBound || _rate > upperBound) revert InvalidRate();

        rate = _rate;
        lastUpdated = block.timestamp;
        emit RateUpdated(_rate);
    }

    /// @notice Add or remove accounts that can update rate
    function updateAdmin(address _address, bool _isAdmin) external onlyOwner {
        admins[_address] = _isAdmin;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "Caller is not the admin");
        _;
    }

}
