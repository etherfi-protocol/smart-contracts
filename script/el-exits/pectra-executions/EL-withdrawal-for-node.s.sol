// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../../../src/EtherFiTimelock.sol";
import "../../../src/interfaces/IEtherFiNode.sol";
// import {IEtherFiNodesManager} from "../../../src/interfaces/IEtherFiNodesManager.sol";
import "../../../src/EtherFiNodesManager.sol";
import {IEigenPod, IEigenPodTypes} from "../../../src/eigenlayer-interfaces/IEigenPod.sol";
import "forge-std/Script.sol";
import "forge-std/console2.sol";

/**
forge script script/el-exits/pectra-executions/EL-withdrawal-for-node.s.sol:ELWithdrawalForNode --fork-url <mainnet-rpc> -vvvv
*/

contract ELWithdrawalForNode is Script {
    EtherFiTimelock etherFiTimelock =
        EtherFiTimelock(payable(0x9f26d4C958fD811A1F59B01B86Be7dFFc9d20761));
    EtherFiTimelock etherFiOperatingTimelock = EtherFiTimelock(payable(0xcD425f44758a08BaAB3C4908f3e3dE5776e45d7a));

    //--------------------------------------------------------------------------------------
    //------------------------- Existing Users/Proxies -------------------------------------
    //--------------------------------------------------------------------------------------
    address constant ETHERFI_NODES_MANAGER_ADDRESS =
        0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F;

    EtherFiNodesManager etherFiNodesManager = EtherFiNodesManager(payable(ETHERFI_NODES_MANAGER_ADDRESS));

    address constant ETHERFI_NODES_MANAGER_ADMIN_ROLE = 0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;

    address constant EIGEN_POD_ADDRESS = 0x9563794BEf554667f4650eaAe192FfeC1C656C23; // 20 validators

    address constant ETHERFI_OPERATING_ADMIN =
        0x2aCA71020De61bb532008049e1Bd41E451aE8AdC;
    address constant TIMELOCK_CONTROLLER = 0xcdd57D11476c22d265722F68390b036f3DA48c21;

    address constant EL_TRIGGER_EXITER = 0x12582A27E5e19492b4FcD194a60F8f5e1aa31B0F;

    uint256 MIN_DELAY_OPERATING_TIMELOCK = 28800; // 8 hours
    uint256 MIN_DELAY_TIMELOCK = 259200; // 72 hours

    bytes constant PK_54043 = hex"8014c4704f081bd4b8470cb93722601095a314c3db7ccf79c129189d01c432db968a64131f23a94c8ff1e280500ae3d3";
    bytes constant PK_54045 = hex"820cf0499d0d908d10c19d85027ed4077322096cd4fb322a763c3bf5e4eb70db30b44ef1284e6fb713421a195735d942";
    bytes constant PK_54041 = hex"87d657860a8b0450d7e700d60aa88a42ee5e6fdedeeb25dd3aee7e1112697f837b4b2e94d37167a900921e6b90c7f3ac";
    bytes constant PK_54050 = hex"8838691e23c67fc8a3021d1dfe49abdbd803469dd3471960f973fa6ed08eb180104d1ddd66938b4dc6264f04e489c6e7";
    bytes constant PK_54040 = hex"895186127b42e8202949b9fff00c112df8070c25d96fbe4238fab3a133c49f4a6401dc55828ad5b89093af7602487a2c";
    bytes constant PK_54049 = hex"8c64ee1865c48b01ef1af561c41b0e3b363f2a83d99b835d6312638b380d2f698c78f2d405133d8b2aec8c439820f50e";
    bytes constant PK_54044 = hex"917f7c7916ee8ba15289810ea118d458c8b4fefb88caa5bef970aa972f7605ed47b54451d9b7c5128c484cf3ce989c1c";
    bytes constant PK_54048 = hex"9310d317f4df0b52f8fa2191b6826e93ccd613b2fb4f4e1463c5b112be9102b689ad628c717f201ededf18555d775b43";
    bytes constant PK_54035 = hex"936dfac756c52488607b7f07d8905cbff4ae647aaeea75645f28f73a46ae3f6cc9dd55be57ea8ebbf1052197be97bb28";
    bytes constant PK_54053 = hex"a160a281269a464e89ca8cdd0521200232c2d37140f218daaa9393aa008c6b3b5ed48040a3e4f46b059532c6b07af360";
    bytes constant PK_54039 = hex"a3b265189b2cb571a2d48043a7da96c918df480983c89f86480a1ae5af8a6aa14c381ef091387c201fe5c886b8c27755";
    bytes constant PK_54051 = hex"a3e60bce7da064113757a74572909242403654e11ad48c9ee646ea926c026ebf9e60bde5054117b0c74600762693f90c";
    bytes constant PK_54047 = hex"a3fb69cd6685e6df16d9dc6e5a0fd174d4460e393bf151b62d4ed62fc4524125f665c3ef91e8673154ce30a934562127";
    bytes constant PK_54042 = hex"a481a9553e9cd70a28685c3c86da72cb7cc47fc4132aa79609bc121f3d1c1fe693fb82b70ab1792267837f03fd8b480a";
    bytes constant PK_54036 = hex"a702539fb750fa7524a382f0a80572161786be488e77cd680d41d3ba47acd2bd9218036e218e61f7a397b25f6fd473b9";
    bytes constant PK_54052 = hex"a9e0d47715165646896c9dd1eaad3822824340f9432978fe2220d1d849509711fa822080d69a5604a7df372dcd7290ff";
    bytes constant PK_54037 = hex"ab82fc4c1eee2b1c26d3adcf6a1240beb18aafe86ac0ca897cd94611eefae7a88e3b3c80dd768b6f2da9326ecebfcc54";
    bytes constant PK_54054 = hex"b72d2761774961ee47a8b9a917110a70425b4500909ccd972f72c7219e3f0c76f086de76cb80a4598ecb44245effeaa9";
    bytes constant PK_54046 = hex"b7ca7c4dccc74cc17a1b2325a95e690aca40fd4d2980bd65180d98bf0da447cf84254da073c28c1b1efc959611e5cfe1";
    bytes constant PK_54038 = hex"b974967fa38e82a9983019ccdb754df1c176edf5e542ec7377c23bcce730c094007fb84d9816f5fb22f09b725e46d99a";

    function run() public {
        console2.log("================================================");
        console2.log("======================== Running EL Withdrawal For Node Transactions ========================");
        console2.log("================================================");
        console2.log("");

        // vm.startBroadcast(ETHERFI_OPERATING_ADMIN);
        // vm.prank(ETHERFI_OPERATING_ADMIN);
        linkLegacyValidatorIds();
        // vm.stopPrank();
        // vm.stopBroadcast();

        // vm.startBroadcast(EL_TRIGGER_EXITER);
        executeELWithdrawalForNodeTransactions();
        // vm.stopBroadcast();
    }

    function linkLegacyValidatorIds() public {
        uint256[] memory legacyIdsForOneValidator = new uint256[](1);
        legacyIdsForOneValidator[0] = 54043;
        bytes[] memory pubkeysForOneValidator = new bytes[](1);
        pubkeysForOneValidator[0] = PK_54043;

        address[] memory targets = new address[](1);
        targets[0] = address(etherFiNodesManager);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            etherFiNodesManager.linkLegacyValidatorIds.selector,
            legacyIdsForOneValidator,
            pubkeysForOneValidator
        );

        bytes32 timelockSalt = keccak256(
            abi.encode(targets, data, block.number)
        );

        bytes memory scheduleCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.scheduleBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Scheduled linkLegacyValidatorIds Tx");
        console2.log("================================================");
        console2.logBytes(scheduleCalldata);
        console2.log("================================================");
        console2.log("");

        bytes memory executeCalldata = abi.encodeWithSelector(
            etherFiOperatingTimelock.executeBatch.selector,
            targets,
            values,
            data,
            bytes32(0), //predecessor
            timelockSalt,
            MIN_DELAY_OPERATING_TIMELOCK
        );
        console2.log("Executed linkLegacyValidatorIds Tx");
        console2.log("================================================");
        console2.logBytes(executeCalldata);
        console2.log("================================================");
        console2.log("");

        vm.prank(address(ETHERFI_OPERATING_ADMIN));
        etherFiNodesManager.linkLegacyValidatorIds(legacyIdsForOneValidator, pubkeysForOneValidator);
        vm.stopPrank();

        // uncomment to run against fork
        // console2.log("=== SCHEDULING BATCH ===");
        // // console2.log("Current timestamp:", block.timestamp);
        // etherFiOperatingTimelock.scheduleBatch(targets, values, data, bytes32(0), timelockSalt, MIN_DELAY_OPERATING_TIMELOCK);

        // console2.log("=== FAST FORWARDING TIME ===");
        // vm.warp(block.timestamp + MIN_DELAY_OPERATING_TIMELOCK + 1); // +1 to ensure it's past the delay
        // // console2.log("New timestamp:", block.timestamp);
        // etherFiOperatingTimelock.executeBatch(targets, values, data, bytes32(0), timelockSalt);
    }

    function executeELWithdrawalForNodeTransactions() public {
        console2.log("Executing EL Withdrawal For Node Transactions");

        // STEP 1: GET EIGEN POD
        IEigenPod pod = IEigenPod(EIGEN_POD_ADDRESS);

        // STEP 2: GET WITHDRAWAL REQUESTS
        IEigenPodTypes.WithdrawalRequest[] memory withdrawalRequests = _getWithdrawalsRequests();

        // STEP 3: GET WITHDRAWAL REQUEST FEE
        uint256 feePer = pod.getWithdrawalRequestFee();
        uint256 n = withdrawalRequests.length;
        uint256 valueToSend = feePer * n;

        // STEP 4: EXECUTE EL WITHDRAWAL FOR NODE TRANSACTIONS
        vm.prank(address(EL_TRIGGER_EXITER));
        etherFiNodesManager.requestExecutionLayerTriggeredWithdrawal{value: valueToSend}(withdrawalRequests);
        vm.stopPrank();
    }

    function _getWithdrawalsRequests() public pure returns (IEigenPodTypes.WithdrawalRequest[] memory withdrawalRequests) {
        bytes[] memory pubkeys = new bytes[](20);
        uint64[] memory amountsGwei = new uint64[](20);

        pubkeys[0] = PK_54043;
        amountsGwei[0] = 0;
        pubkeys[1] = PK_54045;
        amountsGwei[1] = 0;
        pubkeys[2] = PK_54041;
        amountsGwei[2] = 0;
        pubkeys[3] = PK_54050;
        amountsGwei[3] = 0;
        pubkeys[4] = PK_54040;
        amountsGwei[4] = 0;
        pubkeys[5] = PK_54049;
        amountsGwei[5] = 0;
        pubkeys[6] = PK_54044;
        amountsGwei[6] = 0;
        pubkeys[7] = PK_54048;
        amountsGwei[7] = 0;
        pubkeys[8] = PK_54035;
        amountsGwei[8] = 0;
        pubkeys[9] = PK_54053;
        amountsGwei[9] = 0;
        pubkeys[10] = PK_54039;
        amountsGwei[10] = 0;
        pubkeys[11] = PK_54051;
        amountsGwei[11] = 0;
        pubkeys[12] = PK_54047;
        amountsGwei[12] = 0;
        pubkeys[13] = PK_54042;
        amountsGwei[13] = 0;
        pubkeys[14] = PK_54036;
        amountsGwei[14] = 0;
        pubkeys[15] = PK_54052;
        amountsGwei[15] = 0;
        pubkeys[16] = PK_54037;
        amountsGwei[16] = 0;
        pubkeys[17] = PK_54054;
        amountsGwei[17] = 0;
        pubkeys[18] = PK_54046;
        amountsGwei[18] = 0;
        pubkeys[19] = PK_54038;
        amountsGwei[19] = 0;

        withdrawalRequests = new IEigenPodTypes.WithdrawalRequest[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; i++) {
            withdrawalRequests[i] = IEigenPodTypes.WithdrawalRequest({
                pubkey: pubkeys[i],
                amountGwei: amountsGwei[i]
            });
        }
        return withdrawalRequests;
    }
}