// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import "src/eigenlayer-interfaces/IStrategy.sol";

import "test/eigenlayer-contracts/EigenPod.sol";

contract EigenPodManagerMock is Test {
    receive() external payable {}
    fallback() external payable {}

    mapping(address => int256) public podOwnerDepositShares;

    mapping(address => uint256) public podOwnerSharesWithdrawn;

    mapping(address => address) public ownerToPod;

    struct BeaconChainSlashingFactor {
        bool isSet;
        uint64 slashingFactor;
    }

    mapping(address => BeaconChainSlashingFactor) _beaconChainSlashingFactor;

    constructor() {
        // _setPausedStatus(0);
    }

    function createPod() external returns (address) {
        EigenPod pod = new EigenPod(IETHPOSDeposit(address(0)), IEigenPodManager(address(this)), 0);
        pod.initialize(msg.sender);
        ownerToPod[msg.sender] = address(pod);
        return address(pod);
    }

    function getPod(address podOwner) external view returns (IEigenPod) {
        return IEigenPod(ownerToPod[podOwner]);
    }

    function podOwnerShares(address podOwner) external view returns (int256) {
        return podOwnerDepositShares[podOwner];
    }

    function stakerDepositShares(address user, address) public view returns (uint256 depositShares) {
        return podOwnerDepositShares[user] < 0 ? 0 : uint256(podOwnerDepositShares[user]);
    } 

    function setPodOwnerShares(address podOwner, int256 shares) external {
        podOwnerDepositShares[podOwner] = shares;
    }

    function addShares(
        address podOwner,
        IStrategy,
        IERC20,
        uint256 shares
    ) external returns (uint256, uint256) {
        uint256 existingDepositShares = uint256(podOwnerDepositShares[podOwner]);
        podOwnerDepositShares[podOwner] += int256(shares);
        return (existingDepositShares, shares);
    }

    function removeDepositShares(
        address podOwner, 
        IStrategy, // strategy 
        uint256 shares
    ) external {
        podOwnerDepositShares[podOwner] -= int256(shares);
    }

    function denebForkTimestamp() external pure returns (uint64) {
        return type(uint64).max;
    }

    function withdrawSharesAsTokens(address podOwner, address /** strategy */, address /** token */, uint256 shares) external {
        podOwnerSharesWithdrawn[podOwner] += shares;
    }

    function setBeaconChainSlashingFactor(address staker, uint64 bcsf) external {
        _beaconChainSlashingFactor[staker] = BeaconChainSlashingFactor({
            isSet: true,
            slashingFactor: bcsf
        });
    }

    function beaconChainSlashingFactor(address staker) external view returns (uint64) {
        BeaconChainSlashingFactor memory bsf = _beaconChainSlashingFactor[staker];
        return bsf.isSet ? bsf.slashingFactor : WAD;
    }
}