// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/LiquidityPool.sol";
import "../../src/AuctionManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/UUPSProxy.sol";
import "../../src/interfaces/IStakingManager.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../../test/common/DepositDataGeneration.sol";

contract RegisterValidator is Script {
    using Strings for string;

    AddressProvider public addressProvider;
    LiquidityPool public liquidityPool;
    EtherFiNodesManager public managerInstance;

    bytes32 zeroRoot = 0x0000000000000000000000000000000000000000000000000000000000000000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address addressProviderAddress = vm.envAddress("CONTRACT_REGISTRY");
        addressProvider = AddressProvider(addressProviderAddress);

        liquidityPool = LiquidityPool(payable(addressProvider.getContractAddress("LiquidityPool")));
        managerInstance = EtherFiNodesManager(payable(addressProvider.getContractAddress("EtherFiNodesManager")));

        DepositDataGeneration depGen = new DepositDataGeneration();

        uint256[] memory _validatorIds = new uint256[](1);
        IStakingManager.DepositData[] memory depositDataArray = new IStakingManager.DepositData[](_validatorIds.length);
        bytes32[] memory depositDataRootsForApproval = new bytes32[](_validatorIds.length);
        bytes[] memory sig = new bytes[](_validatorIds.length);
        bytes[] memory pubKey = new bytes[](_validatorIds.length);

        // 1 ETH
        // [{"pubkey": "ad85894db60881bcee956116beae6bc6934d7eca8317dc3084adf665be426a21a1855b5196a7515fd791bf0b6e3727c5", "withdrawal_credentials": "010000000000000000000000b2de3e0380d7229dc9e717342ed042e54eaaa620", "amount": 1000000000, "signature": "848169dd090590d31b4eee23f031b3f0df4bbe097e1ea3f65e4c40b5da412f326adfed4b1c45b83831eb692e906ba1ec0f0cacfc714f1c89ad74eca71be43247965e71ead2dc7625410d69c434fa88895ef2c9e135bb187b04eb62bc87539dcf", "deposit_message_root": "12f106b1c020239e8c2857c5bd355ca4c9fec33b2140367064a7df5a11861f44", "deposit_data_root": "aa08a4fe6761812fb0ae067b98e30239a2aefb609c271edf4efe84f7a5742ff3", "fork_version": "01017000", "network_name": "holesky", "deposit_cli_version": "2.7.0"}]

        // 31 ETH
        // [{"pubkey": "ad85894db60881bcee956116beae6bc6934d7eca8317dc3084adf665be426a21a1855b5196a7515fd791bf0b6e3727c5", "withdrawal_credentials": "010000000000000000000000b2de3e0380d7229dc9e717342ed042e54eaaa620", "amount": 31000000000, "signature": "accff50c4fde87119058770c8fff833b6e052e6a689bc639e3a20f57ebff15315ff7cb15e7c0de2856794e459023862d0539bb1b22d3938730f7ec0e0504dcf12b63ba9f9ca2cceef4914f997d90df3f604c0c3a99706a038ef35ed9b3d166d2", "deposit_message_root": "81566688bde7909767507f4daa38f48aba6858d0f786fa4fb4082129ec86fbe0", "deposit_data_root": "262b9668947937a8135e8f6bd9cf27b07891a4c5d5d2dd9d01ada07eff77ccf1", "fork_version": "01017000", "network_name": "holesky", "deposit_cli_version": "2.7.0"}]

        _validatorIds[0] = 1;

        address etherFiNode = managerInstance.etherFiNodeFromId(_validatorIds[0]);

        depositDataArray[0] = IStakingManager.DepositData({
            publicKey: hex"ad85894db60881bcee956116beae6bc6934d7eca8317dc3084adf665be426a21a1855b5196a7515fd791bf0b6e3727c5",
            signature: hex"848169dd090590d31b4eee23f031b3f0df4bbe097e1ea3f65e4c40b5da412f326adfed4b1c45b83831eb692e906ba1ec0f0cacfc714f1c89ad74eca71be43247965e71ead2dc7625410d69c434fa88895ef2c9e135bb187b04eb62bc87539dcf",
            depositDataRoot: hex"aa08a4fe6761812fb0ae067b98e30239a2aefb609c271edf4efe84f7a5742ff3",
            ipfsHashForEncryptedValidatorKey: "SYKO_TEST"
        });

        depositDataRootsForApproval[0] = 0x262b9668947937a8135e8f6bd9cf27b07891a4c5d5d2dd9d01ada07eff77ccf1;

        sig[0] = hex"accff50c4fde87119058770c8fff833b6e052e6a689bc639e3a20f57ebff15315ff7cb15e7c0de2856794e459023862d0539bb1b22d3938730f7ec0e0504dcf12b63ba9f9ca2cceef4914f997d90df3f604c0c3a99706a038ef35ed9b3d166d2";
     

        vm.startBroadcast(deployerPrivateKey);

        // bytes32 _depositRoot,
        // uint256[] calldata _validatorIds,
        // IStakingManager.DepositData[] calldata _registerValidatorDepositData,
        // bytes32[] calldata _depositDataRootApproval,
        // bytes[] calldata _signaturesForApprovalDeposit
        liquidityPool.batchRegister(zeroRoot, _validatorIds, depositDataArray, depositDataRootsForApproval, sig);

        vm.stopBroadcast();
    }
}
