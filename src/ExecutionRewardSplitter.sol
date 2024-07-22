// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

// This contract splits rewards between a liquidity pool and a BNFT address
// Node operators will configure their node to send rewards to this contract corresponding to their bnft
// An instance of this contract will be deployed for each bnft
contract ExecutionRewardsSplitter is Initializable, OwnableUpgradeable, UUPSUpgradeable {

    address public BNFT_ADDRESS; 
    address public TNFT_ADDRESS; 
    address admin;
    mapping (address => bool) public executionRewardContracts; //contracts that can receive mistransferred rewards
    uint256 public tnftSplit; 
    uint256 public bnftSplit; 


    constructor() {}

    function initialize(address _tnftAddress, address _bnftAddress) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        BNFT_ADDRESS = _bnftAddress;
        TNFT_ADDRESS = _tnftAddress;
    }

    function setAdmin(address _admin) public onlyOwner {
        admin = _admin;
    } 
    // Set the TNFT split percentage
    function setSplit(uint256 _tnftSplit, uint256 _bnftSplit) public isAdmin {
        tnftSplit = _tnftSplit;
        bnftSplit = _bnftSplit;
    }

    function addMistransferredContract(address _contract) public isAdmin {
        executionRewardContracts[_contract] = true;
    }

    //handle mistransferred mev rewards
    function transferMistransferredRewards(address _to, uint256 _amount) public isAdmin {
        require(_amount <= address(this).balance, "Insufficient balance");
        require(executionRewardContracts[_to], "Invalid contract"); //can 
        payable(_to).transfer(_amount);
    }

    receive() external payable {}

    // Withdraw the rewards based on the split percentages
    function withdraw() public isAdmin {
        uint256 scale = tnftSplit + bnftSplit;
        uint256 totalBalance = address(this).balance;
        uint256 tnftRewards = totalBalance * tnftSplit / scale;
        uint256 bnftRewards = totalBalance * bnftSplit / scale;

        payable(TNFT_ADDRESS).call{value: tnftRewards}("");
        if (bnftRewards > 0) {
            payable(BNFT_ADDRESS).call{value: bnftRewards}("");
        }
    }

        modifier isAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "EtherFiAdmin: not an admin");
        _;
    }

    // Required by UUPS upgradeable contracts
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
