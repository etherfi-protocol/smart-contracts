// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "../test/TestSetup.sol";
import "../src/EtherFiTimelock.sol";
import "../src/EtherFiNode.sol";
import "../src/EtherFiNodesManager.sol";
import "../src/LiquidityPool.sol";
import "../src/StakingManager.sol";
import "../src/EtherFiOracle.sol";
import "../src/EtherFiAdmin.sol";
import "../src/EETH.sol";
import "../src/WeETH.sol";
import "../src/RoleRegistry.sol";
import "../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import "forge-std/console2.sol";

contract Rerestake is Script {
    EtherFiNodesManager etherFiNodesManager = EtherFiNodesManager(0x8B71140AD2e5d1E7018d2a7f8a288BD3CD38916F);
    address constant delegationManager = 0x39053D51B77DC0d36036Fc1fCc8Cb819df8Ef37A;
    uint32 public constant EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS = 100800;
    mapping(address => bool) public nodeSeen;
    address[] public nodes = new address[](81);

    function run() public {
        nodes[0] = address(0x3e7230E6184e89525fa89CADBBBCfBd056157d5E);
        nodes[1] = address(0x89c5e2206315Ff914f59CDc3dC93117c2D2274EE);
        nodes[2] = address(0x7AFaeeF339c6767D921420514f11B4D8AA3363F4);
        nodes[3] = address(0xbb31f6dAc34b3646D6339f3696047fFeaC246d4F);
        nodes[4] = address(0x379eBDb23B602970D8c96A08f9F9430fB225d01A);
        nodes[5] = address(0xe08D2106ed8b1A97c160404a14756834280e5ebb);
        nodes[6] = address(0x6893552Bc8a2061fEe4bC7CbdFDc10b5Bb077DaD);
        nodes[7] = address(0x25428435E23683CAD096B55dbD582f1F01Bac1be);
        nodes[8] = address(0xFf1e889CfB8b04BcD99d641a2c25774EdDc507dc);
        nodes[9] = address(0x5d5B49E9AD0D92B02d99e3771C09C947019637c9);
        nodes[10] = address(0xBF4859a818ecbe578C9C98F7F36086e1F45D3d16);
        nodes[11] = address(0x622AE42994eCD2B499BE8B4d3473AD397BCd739d);
        nodes[12] = address(0x25833D3De051493455f6ac61e71b731D108a8cE8);
        nodes[13] = address(0xC12eAAc114e8D5315E97c8b047c895fD83444Ea5);
        nodes[14] = address(0x17f8623EDEc433f17e6838244737d21790bC1DAC);
        nodes[15] = address(0x0e7e0A71B3749fD1dA367B72Fd247127713fC8a1);
        nodes[16] = address(0x3e7230E6184e89525fa89CADBBBCfBd056157d5E);
        nodes[17] = address(0x89c5e2206315Ff914f59CDc3dC93117c2D2274EE);
        nodes[18] = address(0x7AFaeeF339c6767D921420514f11B4D8AA3363F4);
        nodes[19] = address(0xbb31f6dAc34b3646D6339f3696047fFeaC246d4F);
        nodes[20] = address(0x7898333991035242A1115D978c0619F8736dD323);
        nodes[21] = address(0x379eBDb23B602970D8c96A08f9F9430fB225d01A);
        nodes[22] = address(0xe08D2106ed8b1A97c160404a14756834280e5ebb);
        nodes[23] = address(0x6893552Bc8a2061fEe4bC7CbdFDc10b5Bb077DaD);
        nodes[24] = address(0xAb38C425b9fF37D28bA6fF77A132133a3a9ef276);
        nodes[25] = address(0x25428435E23683CAD096B55dbD582f1F01Bac1be);
        nodes[26] = address(0x5d5B49E9AD0D92B02d99e3771C09C947019637c9);
        nodes[27] = address(0xBF4859a818ecbe578C9C98F7F36086e1F45D3d16);
        nodes[28] = address(0x3b8206bFe447260F69ca0618667b0f6180096cA2);
        nodes[29] = address(0x622AE42994eCD2B499BE8B4d3473AD397BCd739d);
        nodes[30] = address(0xe5fcDEd228fa644627C1dfEc053CE3E22cb48112);
        nodes[31] = address(0x25833D3De051493455f6ac61e71b731D108a8cE8);
        nodes[32] = address(0xC12eAAc114e8D5315E97c8b047c895fD83444Ea5);
        nodes[33] = address(0x17f8623EDEc433f17e6838244737d21790bC1DAC);
        nodes[34] = address(0x0e7e0A71B3749fD1dA367B72Fd247127713fC8a1);
        nodes[35] = address(0x975eCc3879C0cCf4433d15D6941d0238357aC325);
        nodes[36] = address(0xEAA1E6Fa654788aDBdeAAc009217Cc4F6b92aD9D);
        nodes[37] = address(0xf75818B3501FF843F6784f6DE1D3F6080cEB96e5);
        nodes[38] = address(0xBe21d6A41Efe662826Ac4953C210C5F5c9748355);
        nodes[39] = address(0x65737AD48b64Be2a766bac2230837a1745d8d11a);
        nodes[40] = address(0xbb7ca966A6F3A0B7216BD55F040A85324eD9Cd87);
        nodes[41] = address(0xb0A72A7E4Af952C4f9d379E3EeF77b7C9c2c2F1e);
        nodes[42] = address(0x1B65AE9Ba310F033E5c15FdaAb4a485aB0b798c8);
        nodes[43] = address(0x5F1245A3ed7e93D87493EF1b152767F26F452956);
        nodes[44] = address(0xC94EBB12830571FCEaEe464BB330723cBBf11308);
        nodes[45] = address(0x92316Ab4BEe3662709DD6a96ea19B06692409B2E);
        nodes[46] = address(0x91B69545B6537d396a9467ed03bc418F8d2472D7);
        nodes[47] = address(0x0F3e5FA1720E0b99d4DF5ed38783d6f7d71AaF12);
        nodes[48] = address(0x877d2a7a6de6E05901954bC8CC0F37f2e9A6f75e);
        nodes[49] = address(0x605B07407E8da3e102330B1B895D1057FD66Add1);
        nodes[50] = address(0x18Ec33F50FbA074e1A8AF006633179cdE8c97957);
        nodes[51] = address(0x1F6368d91B4D0235C4C4aB8D2D357721e0Eb26ae);
        nodes[52] = address(0x5062b28d34a6518D0CA037a50372849a85b446b3);
        nodes[53] = address(0x721636F6bBf037Bcf63d3AD697f529512C712626);
        nodes[54] = address(0x5F522B216A990961584BC857cEe8f5ba3983197c);
        nodes[55] = address(0x880bA04DB0b91B1C46cDa2081EF5C0cC6378Fd32);
        nodes[56] = address(0x0A780528eA8ECe64Fb2e46Fd2600eAE21747291b);
        nodes[57] = address(0x566Faca7Db752D2E9A35f21FF9D1e498541Fb8aB);
        nodes[58] = address(0x6a402D1E19752ccD640d85E1854A2925b36FA439);
        nodes[59] = address(0x75d2672CB618F47bC1CAa417e681100090fDBB99);
        nodes[60] = address(0xaA311B226F4367aacc68DB326016b970F96e07bB);
        nodes[61] = address(0x7f91F0a50A874ADD09027F5C21684209e1338434);
        nodes[62] = address(0x3D8dA83643370df84098AB9bdBd3Ec9aB38d810e);
        nodes[63] = address(0xf60B68889Df46cdc608121417c38232a302cCf2B);
        nodes[64] = address(0xFDB00d95606d33a4E3DEA5872463482DcF8AD51a);
        nodes[65] = address(0x5c4d4A148c4b504Fab5782Da4DA93D69D098B207);
        nodes[66] = address(0xd5438E6bDd74035Dc5931597C23F4c8479E4D0AF);
        nodes[67] = address(0xb8934644879dc160030fb483851Fd7d268aFD437);
        nodes[68] = address(0x1120B0d85824a76625f3e595fcc8F2fff42675fC);
        nodes[69] = address(0xfB082Dc369e7a9DdD4f0dd6D75DbC07daBC5a441);
        nodes[70] = address(0x886Ac426bC13877E89828914589E0980306447eB);
        nodes[71] = address(0x9F7479fb112B6a51325Cf9A4B407a0D3bC48B938);
        nodes[72] = address(0x51B60b00E33BDa11412b518a7223F79f59Bb7E2F);
        nodes[73] = address(0xD57672Fe005D4877100c4E456629eB986d3D974a);
        nodes[74] = address(0x05778C88D86A7E7E3546F2e6dD38a3655E157440);
        nodes[75] = address(0x2556Ac27c67A6f7faA71DEcb863cA6BC2f287A24);
        nodes[76] = address(0x1Af1465D9674caa5Dc53Cf2aF240202462b6C279);
        nodes[77] = address(0x6497Dbc476b07e89572253B73AFa3Fd3AdaA4365);
        nodes[78] = address(0xFc6A02Dcc0807E067d8BEfa544a8496F420Aad27);
        nodes[79] = address(0x09bdd58de99a103292B095FbeA99C75d3970A57c);
        nodes[80] = address(0xb9d000815899360ECfaD44Cd3C150103B37fCE28);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 cnt = 0;
        uint256 cntRemoved = 0;
        uint256 amountRemoved = 0;
        for (uint256 i = 0; i < nodes.length; i++) {
            address node = nodes[i];
            if (nodeSeen[node]) {
                continue;
            }
            nodeSeen[node] = true;
            cnt++;

            (IDelegationManager.Withdrawal[] memory queuedWithdrawals, ) = IDelegationManager(delegationManager).getQueuedWithdrawals(node);

            // no duplicate withdrawals
            if (queuedWithdrawals.length <= 1) {
                console2.log("No withdrawals for node", node);
                continue;
            }

            // we want to "cancel" i.e. re-restake any withdrawals that are not divisible by 32 ether
            // ignoring the first withdrawal that is not divisible by 32 ether
            IDelegationManager.Withdrawal[] memory toClaim = new IDelegationManager.Withdrawal[](queuedWithdrawals.length-1);
            IERC20[][] memory tokens = new IERC20[][](queuedWithdrawals.length-1);
            bool[] memory receiveAsTokens = new bool[](queuedWithdrawals.length-1);

            uint256 numNonDivisibleWithdrawals = 0;
            for (uint256 j = 0; j < queuedWithdrawals.length; j++) {

                // ignore if not ready to claim
                uint32 slashableUntil = queuedWithdrawals[j].startBlock + EIGENLAYER_WITHDRAWAL_DELAY_BLOCKS;
                if (uint32(block.number) <= slashableUntil) continue;

                bool isDivisible = queuedWithdrawals[j].scaledShares[0] % 32 ether == 0;
                if (!isDivisible) {
                    numNonDivisibleWithdrawals++;
                }

                if(isDivisible) {
                    console2.log("The Divisible withdrawal with amount and node", queuedWithdrawals[j].scaledShares[0], node);
                }
                // if this is not the first nonDivisible withdrawal we have seen, "cancel" it
                if (numNonDivisibleWithdrawals > 1 && !isDivisible) {
                    IDelegationManager.Withdrawal[] memory withdrawals = new IDelegationManager.Withdrawal[](1);
                    withdrawals[0] = queuedWithdrawals[j];
                    IERC20[][] memory tokens = new IERC20[][](1);
                    tokens[0] = new IERC20[](1); // don't need to actually set for beacon eth
                    bool[] memory receiveAsTokens = new bool[](1);
                    receiveAsTokens[0] = false;

                    IEtherFiNode(nodes[i]).completeQueuedWithdrawals(withdrawals, tokens, receiveAsTokens);
                    cntRemoved++;
                    amountRemoved += queuedWithdrawals[j].scaledShares[0];
                }
            }
        }
        console2.log("Total nodes", cnt);
        console2.log("Total nodes removed", cntRemoved);
        console2.log("Total amount removed", amountRemoved);

        vm.stopBroadcast();
    }

}
