// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/Treasury.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/ProtocolRevenueManager.sol";
import "../../src/StakingManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EETH.sol";
import "../../src/WeETH.sol";
import "../../src/RegulationsManager.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../../test/TestERC20.sol";

contract DeployEtherFiSuiteScript is Script {
    using Strings for string;

    bytes32 initialHash = vm.envBytes32("INITIAL_HASH");


    /*---- Storage variables ----*/

    TestERC20 public rETH;
    TestERC20 public wstETH;
    TestERC20 public sfrxEth;
    TestERC20 public cbEth;

    UUPSProxy public auctionManagerProxy;
    UUPSProxy public stakingManagerProxy;
    UUPSProxy public etherFiNodeManagerProxy;
    UUPSProxy public protocolRevenueManagerProxy;
    UUPSProxy public TNFTProxy;
    UUPSProxy public BNFTProxy;
    UUPSProxy public liquidityPoolProxy;
    UUPSProxy public eETHProxy;
    UUPSProxy public claimReceiverPoolProxy;
    UUPSProxy public regulationsManagerProxy;
    UUPSProxy public weETHProxy;

    BNFT public BNFTImplementation;
    BNFT public BNFTInstance;

    TNFT public TNFTImplementation;
    TNFT public TNFTInstance;

    WeETH public weEthImplementation;
    WeETH public weEthInstance;

    AuctionManager public auctionManagerImplementation;
    AuctionManager public auctionManager;

    StakingManager public stakingManagerImplementation;
    StakingManager public stakingManager;

    ProtocolRevenueManager public protocolRevenueManagerImplementation;
    ProtocolRevenueManager public protocolRevenueManager;

    EtherFiNodesManager public etherFiNodesManagerImplementation;
    EtherFiNodesManager public etherFiNodesManager;

    LiquidityPool public liquidityPoolImplementation;
    LiquidityPool public liquidityPool;

    EETH public eETHImplementation;
    EETH public eETHInstance;

    RegulationsManager public regulationsManagerInstance;
    RegulationsManager public regulationsManagerImplementation;

    struct suiteAddresses {
        address treasury;
        address nodeOperatorManager;
        address auctionManager;
        address stakingManager;
        address TNFT;
        address BNFT;
        address etherFiNodesManager;
        address protocolRevenueManager;
        address etherFiNode;
        address regulationsManager;
        address liquidityPool;
        address eETH;
        address weEth;
    }

    suiteAddresses suiteAddressesStruct;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy contracts
        Treasury treasury = new Treasury();
        NodeOperatorManager nodeOperatorManager = new NodeOperatorManager();

        auctionManagerImplementation = new AuctionManager();
        auctionManagerProxy = new UUPSProxy(address(auctionManagerImplementation),"");
        auctionManager = AuctionManager(address(auctionManagerProxy));
        auctionManager.initialize(address(nodeOperatorManager));

        stakingManagerImplementation = new StakingManager();
        stakingManagerProxy = new UUPSProxy(address(stakingManagerImplementation),"");
        stakingManager = StakingManager(address(stakingManagerProxy));
        stakingManager.initialize(address(auctionManager));

        BNFTImplementation = new BNFT();
        BNFTProxy = new UUPSProxy(address(BNFTImplementation),"");
        BNFTInstance = BNFT(address(BNFTProxy));
        BNFTInstance.initialize(address(stakingManager));

        TNFTImplementation = new TNFT();
        TNFTProxy = new UUPSProxy(address(TNFTImplementation),"");
        TNFTInstance = TNFT(address(TNFTProxy));
        TNFTInstance.initialize(address(stakingManager));

        protocolRevenueManagerImplementation = new ProtocolRevenueManager();
        protocolRevenueManagerProxy = new UUPSProxy(address(protocolRevenueManagerImplementation),"");
        protocolRevenueManager = ProtocolRevenueManager(payable(address(protocolRevenueManagerProxy)));
        protocolRevenueManager.initialize();

        etherFiNodesManagerImplementation = new EtherFiNodesManager();
        etherFiNodeManagerProxy = new UUPSProxy(address(etherFiNodesManagerImplementation),"");
        etherFiNodesManager = EtherFiNodesManager(payable(address(etherFiNodeManagerProxy)));
        etherFiNodesManager.initialize(
            address(treasury),
            address(auctionManager),
            address(stakingManager),
            address(TNFTInstance),
            address(BNFTInstance)
        );

        regulationsManagerImplementation = new RegulationsManager();
        regulationsManagerProxy = new UUPSProxy(address(regulationsManagerImplementation), "");
        regulationsManagerInstance = RegulationsManager(address(regulationsManagerProxy));
        regulationsManagerInstance.initialize();

        EtherFiNode etherFiNode = new EtherFiNode();

        // Mainnet Addresses
        // address private immutable rETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
        // address private immutable wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        // address private immutable sfrxETH = 0xac3E018457B222d93114458476f3E3416Abbe38F;
        // address private immutable cbETH = 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704;
        rETH = new TestERC20("Rocket Pool ETH", "rETH");
        cbEth = new TestERC20("Staked ETH", "wstETH");
        wstETH = new TestERC20("Coinbase ETH", "cbEth");
        sfrxEth = new TestERC20("Frax ETH", "sfrxEth");

        liquidityPoolImplementation = new LiquidityPool();
        liquidityPoolProxy = new UUPSProxy(
            address(liquidityPoolImplementation),
            ""
        );
        liquidityPool = LiquidityPool(
            payable(address(liquidityPoolProxy))
        );
        liquidityPool.initialize();

        eETHImplementation = new EETH();
        eETHProxy = new UUPSProxy(address(eETHImplementation), "");
        eETHInstance = EETH(address(eETHProxy));
        eETHInstance.initialize(payable(address(liquidityPool)));
        
        // Setup dependencies
        nodeOperatorManager.setAuctionContractAddress(address(auctionManager));

        auctionManager.setStakingManagerContractAddress(address(stakingManager));

        protocolRevenueManager.setAuctionManagerAddress(address(auctionManager));
        protocolRevenueManager.setEtherFiNodesManagerAddress(address(etherFiNodesManager));

        stakingManager.setEtherFiNodesManagerAddress(address(etherFiNodesManager));
        stakingManager.setLiquidityPoolAddress(address(liquidityPool));
        stakingManager.registerEtherFiNodeImplementationContract(address(etherFiNode));
        stakingManager.registerTNFTContract(address(TNFTInstance));
        stakingManager.registerBNFTContract(address(BNFTInstance));

        liquidityPool.setTokenAddress(address(eETHInstance));
        liquidityPool.setStakingManager(address(stakingManager));
        liquidityPool.setEtherFiNodesManager(address(etherFiNodesManager));

        weEthImplementation = new WeETH();
        weETHProxy = new UUPSProxy(address(weEthImplementation), "");
        weEthInstance = WeETH(address(weETHProxy));
        weEthInstance.initialize(payable(address(liquidityPool)), address(eETHInstance));

        regulationsManagerInstance.initializeNewWhitelist(initialHash);
        
        vm.stopBroadcast();

        suiteAddressesStruct = suiteAddresses({
            treasury: address(treasury),
            nodeOperatorManager: address(nodeOperatorManager),
            auctionManager: address(auctionManager),
            stakingManager: address(stakingManager),
            TNFT: address(TNFTInstance),
            BNFT: address(BNFTInstance),
            etherFiNodesManager: address(etherFiNodesManager),
            protocolRevenueManager: address(protocolRevenueManager),
            etherFiNode: address(etherFiNode),
            regulationsManager: address(regulationsManagerInstance),
            liquidityPool: address(liquidityPool),
            eETH: address(eETHInstance),
            weEth: address(weEthInstance)
        });

        writeSuiteVersionFile();
        writeLpVersionFile();
    }

    function _stringToUint(
        string memory numString
    ) internal pure returns (uint256) {
        uint256 val = 0;
        bytes memory stringBytes = bytes(numString);
        for (uint256 i = 0; i < stringBytes.length; i++) {
            uint256 exp = stringBytes.length - i;
            bytes1 ival = stringBytes[i];
            uint8 uval = uint8(ival);
            uint256 jval = uval - uint256(0x30);

            val += (uint256(jval) * (10 ** (exp - 1)));
        }
        return val;
    }

    function writeSuiteVersionFile() internal {
        // Read Current version
        string memory versionString = vm.readLine("release/logs/EtherFiSuite/version.txt");

        // Cast string to uint256
        uint256 version = _stringToUint(versionString);

        version++;

        // Overwrites the version.txt file with incremented version
        vm.writeFile(
            "release/logs/EtherFiSuite/version.txt",
            string(abi.encodePacked(Strings.toString(version)))
        );

        // Writes the data to .release file
        vm.writeFile(
            string(
                abi.encodePacked(
                    "release/logs/EtherFiSuite/",
                    Strings.toString(version),
                    ".release"
                )
            ),
            string(
                abi.encodePacked(
                    Strings.toString(version),
                    "\nTreasury: ",
                    Strings.toHexString(suiteAddressesStruct.treasury),
                    "\nNode Operator Key Manager: ",
                    Strings.toHexString(suiteAddressesStruct.nodeOperatorManager),
                    "\nAuctionManager: ",
                    Strings.toHexString(suiteAddressesStruct.auctionManager),
                    "\nStakingManager: ",
                    Strings.toHexString(suiteAddressesStruct.stakingManager),
                    "\nEtherFi Node Manager: ",
                    Strings.toHexString(suiteAddressesStruct.etherFiNodesManager),
                    "\nProtocol Revenue Manager: ",
                    Strings.toHexString(suiteAddressesStruct.protocolRevenueManager),
                    "\nTNFT: ",
                    Strings.toHexString(suiteAddressesStruct.TNFT),
                    "\nBNFT: ",
                    Strings.toHexString(suiteAddressesStruct.BNFT)
                )
            )
        );
    }

    function writeLpVersionFile() internal {
        // Read Current version
        string memory versionString = vm.readLine("release/logs/LiquidityPool/version.txt");

        // Cast string to uint256
        uint256 version = _stringToUint(versionString);

        version++;

        // Overwrites the version.txt file with incremented version
        vm.writeFile(
            "release/logs/LiquidityPool/version.txt",
            string(abi.encodePacked(Strings.toString(version)))
        );

        // Writes the data to .release file
        vm.writeFile(
            string(
                abi.encodePacked(
                    "release/logs/LiquidityPool/",
                    Strings.toString(version),
                    ".release"
                )
            ),
            string(
                abi.encodePacked(
                    Strings.toString(version),
                    "\nRegulations Manager: ",
                    Strings.toHexString(suiteAddressesStruct.regulationsManager),
                    "\nLiquidity Pool: ",
                    Strings.toHexString(suiteAddressesStruct.liquidityPool),
                    "\neETH: ",
                    Strings.toHexString(suiteAddressesStruct.eETH),
                    "\nweETH: ",
                    Strings.toHexString(suiteAddressesStruct.weEth)
                )
            )
        );
    }
}
