// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../../src/Treasury.sol";
import "../../src/NodeOperatorManager.sol";
import "../../src/EtherFiNodesManager.sol";
import "../../src/EtherFiNode.sol";
import "../../src/archive/ProtocolRevenueManager.sol";
import "../../src/StakingManager.sol";
import "../../src/AuctionManager.sol";
import "../../src/LiquidityPool.sol";
import "../../src/EETH.sol";
import "../../src/WeETH.sol";
import "../../src/archive/RegulationsManager.sol";
import "../../src/UUPSProxy.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../../src/EtherFiAdmin.sol";
import "../../src/WithdrawRequestNFT.sol";
import "../../src/MembershipManager.sol";
import {MembershipManagerInit} from "../../src/MembershipManagerInit.sol";
import "../../src/MembershipNFT.sol";
import "../../src/EtherFiOracle.sol";
import "../Create2Factory.sol";
import "../../src/helpers/EtherFiOperationParameters.sol";
import "../../src/helpers/EtherFiViewer.sol";
import "../../src/EtherFiRestaker.sol";
import "../../src/EtherFiRewardsRouter.sol";
import "../../src/RoleRegistry.sol";
import "../../src/EtherFiTimelock.sol";
import "../../src/BucketRateLimiter.sol";
import "../../src/TVLOracle.sol";
import "../../src/Liquifier.sol";
import "../../src/helpers/AddressProvider.sol";
import "../../src/EtherFiRedemptionManager.sol";

import "../../test/TestERC20.sol";

contract DeployEtherFiSuiteScript is Script {
    using Strings for string;

    bytes32 initialHash = 0x0000000000000000000000000000000000000000000000000000000000000001;

    // Create2Factory for deterministic deployments
    Create2Factory public create2Factory;
    uint256 public saltNonce = 0;

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
    UUPSProxy public etherFiAdminProxy;
    UUPSProxy public withdrawRequestNFTProxy;
    UUPSProxy public membershipManagerProxy;
    UUPSProxy public membershipNFTProxy;
    UUPSProxy public etherFiOracleProxy;
    UUPSProxy public etherFiOperationParametersProxy;
    UUPSProxy public etherFiViewerProxy;
    UUPSProxy public etherFiRestakerProxy;
    UUPSProxy public etherFiRewardsRouterProxy;
    UUPSProxy public roleRegistryProxy;
    UUPSProxy public etherFiTimelockProxy;
    UUPSProxy public bucketRateLimiterProxy;
    UUPSProxy public tvlOracleProxy;
    UUPSProxy public liquifierProxy;
    UUPSProxy public redemptionManagerProxy;

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

    EtherFiAdmin public etherFiAdminImplementation;
    EtherFiAdmin public etherFiAdmin;

    WithdrawRequestNFT public withdrawRequestNFTImplementation;
    WithdrawRequestNFT public withdrawRequestNFT;

    MembershipManagerInit public membershipManagerImplementationInit;


    MembershipManager public membershipManagerImplementation;
    MembershipManager public membershipManager;

    MembershipNFT public membershipNFTImplementation;
    MembershipNFT public membershipNFT;

    EtherFiOracle public etherFiOracleImplementation;
    EtherFiOracle public etherFiOracle;

    EtherFiOperationParameters public etherFiOperationParametersImplementation;
    EtherFiOperationParameters public etherFiOperationParameters;

    EtherFiViewer public etherFiViewerImplementation;
    EtherFiViewer public etherFiViewer;

    EtherFiRestaker public etherFiRestakerImplementation;
    EtherFiRestaker public etherFiRestaker;

    EtherFiRewardsRouter public etherFiRewardsRouterImplementation;
    EtherFiRewardsRouter public etherFiRewardsRouter;

    RoleRegistry public roleRegistryImplementation;
    RoleRegistry public roleRegistry;

    EtherFiTimelock public etherFiTimelockImplementation;
    EtherFiTimelock public etherFiTimelock;

    BucketRateLimiter public bucketRateLimiterImplementation;
    BucketRateLimiter public bucketRateLimiter;

    TVLOracle public tvlOracleImplementation;
    TVLOracle public tvlOracle;

    Liquifier public liquifierImplementation;
    Liquifier public liquifier;

    EtherFiRedemptionManager public redemptionManagerImplementation;
    EtherFiRedemptionManager public redemptionManager;

    AddressProvider public addressProvider;

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
        address etherFiAdmin;
        address withdrawRequestNFT;
        address membershipManager;
        address membershipNFT;
        address etherFiOracle;
        address etherFiOperationParameters;
        address etherFiViewer;
        address etherFiRestaker;
        address etherFiRewardsRouter;
        address roleRegistry;
        address etherFiTimelock;
        address bucketRateLimiter;
        address tvlOracle;
        address liquifier;
        address etherFiNodeBeacon;
        address redemptionManager;
    }

    suiteAddresses suiteAddressesStruct;
    
    address treasury;
    address nodeOperatorManager;
    EtherFiNode etherFiNode;
    
    function deployWithCreate2(bytes memory bytecode, string memory contractName) internal returns (address payable) {
        address deployed = create2Factory.deploy(bytecode, contractName);
        return payable(deployed);
    }
    
    function deployTreasury() internal {
        bytes memory bytecode = type(Treasury).creationCode;
        treasury = deployWithCreate2(bytecode, "Treasury");
    }
    
    function deployNodeOperatorManager() internal {
        // Deploy implementation
        bytes memory implBytecode = type(NodeOperatorManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "NodeOperatorManagerImpl");
        
        // Deploy proxy
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        nodeOperatorManager = deployWithCreate2(proxyBytecode, "NodeOperatorManager");
        
        NodeOperatorManager(nodeOperatorManager).initialize();
    }
    
    function deployAuctionManager() internal {
        // Deploy implementation
        bytes memory implBytecode = type(AuctionManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "AuctionManagerImpl");
        auctionManagerImplementation = AuctionManager(implementation);
        
        // Deploy proxy
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "AuctionManager");
        auctionManagerProxy = UUPSProxy(proxy);
        auctionManager = AuctionManager(proxy);
        
        auctionManager.initialize(nodeOperatorManager);
    }
    
    function deployStakingManager(address _ethDepositContractAddress) internal {
        // Deploy implementation
        bytes memory implBytecode = type(StakingManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "StakingManagerImpl");
        stakingManagerImplementation = StakingManager(implementation);
        
        // Deploy proxy
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "StakingManager");
        stakingManagerProxy = UUPSProxy(proxy);
        stakingManager = StakingManager(proxy);
        
        stakingManager.initialize(address(auctionManager), _ethDepositContractAddress);
    }
    
    function deployEtherFiNode() internal {
        bytes memory bytecode = type(EtherFiNode).creationCode;
        address payable deployed = deployWithCreate2(bytecode, "EtherFiNode");
        etherFiNode = EtherFiNode(deployed);
    }
    
    function deployNFTContracts() internal {
        // Deploy BNFT
        bytes memory bnftImplBytecode = type(BNFT).creationCode;
        address payable bnftImpl = deployWithCreate2(bnftImplBytecode, "BNFTImpl");
        BNFTImplementation = BNFT(bnftImpl);
        
        bytes memory bnftProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(bnftImpl, ""));
        address payable bnftProxy = deployWithCreate2(bnftProxyBytecode, "BNFT");
        BNFTProxy = UUPSProxy(bnftProxy);
        BNFTInstance = BNFT(bnftProxy);
        BNFTInstance.initialize(address(stakingManager));
        
        // Deploy TNFT
        bytes memory tnftImplBytecode = type(TNFT).creationCode;
        address payable tnftImpl = deployWithCreate2(tnftImplBytecode, "TNFTImpl");
        TNFTImplementation = TNFT(tnftImpl);
        
        bytes memory tnftProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(tnftImpl, ""));
        address payable tnftProxy = deployWithCreate2(tnftProxyBytecode, "TNFT");
        TNFTProxy = UUPSProxy(tnftProxy);
        TNFTInstance = TNFT(tnftProxy);
        TNFTInstance.initialize(address(stakingManager));
    }
    
    function deployProtocolRevenueManager() internal {
        bytes memory implBytecode = type(ProtocolRevenueManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "ProtocolRevenueManagerImpl");
        protocolRevenueManagerImplementation = ProtocolRevenueManager(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "ProtocolRevenueManager");
        protocolRevenueManagerProxy = UUPSProxy(proxy);
        protocolRevenueManager = ProtocolRevenueManager(payable(proxy));
        
        protocolRevenueManager.initialize();
    }
    
    function deployEtherFiNodesManager() internal {
        bytes memory implBytecode = type(EtherFiNodesManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiNodesManagerImpl");
        etherFiNodesManagerImplementation = EtherFiNodesManager(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiNodesManager");
        etherFiNodeManagerProxy = UUPSProxy(proxy);
        etherFiNodesManager = EtherFiNodesManager(payable(proxy));
        
        // EigenLayer addresses for Hoodi testnet
        address eigenPodManager = 0xcd1442415Fc5C29Aa848A49d2e232720BE07976c; // EigenPodManager on Hoodi
        address delayedWithdrawalRouter = address(0); // DelayedWithdrawalRouter doesn't exist on Hoodi
        address delegationManager = 0x867837a9722C512e0862d8c2E15b8bE220E8b87d; // DelegationManager on Hoodi
        
        etherFiNodesManager.initialize(
            treasury,
            address(auctionManager),
            address(stakingManager),
            address(TNFTInstance),
            address(BNFTInstance),
            eigenPodManager, // EigenPodManager address
            delayedWithdrawalRouter, // address(0) - doesn't exist on Hoodi
            delegationManager // DelegationManager address
        );
        
        // Configure EtherFiNodesManager admin roles
        etherFiNodesManager.updateAdmin(msg.sender, true);
    }
    
    function deployRegulationsManager() internal {
        bytes memory implBytecode = type(RegulationsManager).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "RegulationsManagerImpl");
        regulationsManagerImplementation = RegulationsManager(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "RegulationsManager");
        regulationsManagerProxy = UUPSProxy(proxy);
        regulationsManagerInstance = RegulationsManager(proxy);
        
        regulationsManagerInstance.initialize();
    }
    
    function deployMembershipContracts() internal {
        // Deploy WithdrawRequestNFT
        bytes memory withdrawImplBytecode = abi.encodePacked(type(WithdrawRequestNFT).creationCode, abi.encode(treasury));
        address payable withdrawImpl = deployWithCreate2(withdrawImplBytecode, "WithdrawRequestNFTImpl");
        withdrawRequestNFTImplementation = WithdrawRequestNFT(withdrawImpl);
        
        bytes memory withdrawProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(withdrawImpl, ""));
        address payable withdrawProxy = deployWithCreate2(withdrawProxyBytecode, "WithdrawRequestNFT");
        withdrawRequestNFTProxy = UUPSProxy(withdrawProxy);
        withdrawRequestNFT = WithdrawRequestNFT(withdrawProxy);
        
        // Deploy MembershipNFT
        bytes memory membershipNFTImplBytecode = type(MembershipNFT).creationCode;
        address payable membershipNFTImpl = deployWithCreate2(membershipNFTImplBytecode, "MembershipNFTImpl");
        membershipNFTImplementation = MembershipNFT(membershipNFTImpl);
        
        
        bytes memory membershipNFTProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(membershipNFTImpl, ""));
        address payable membershipNFTProxyAddr = deployWithCreate2(membershipNFTProxyBytecode, "MembershipNFT");
        membershipNFTProxy = UUPSProxy(membershipNFTProxyAddr);
        membershipNFT = MembershipNFT(membershipNFTProxyAddr);
        
        // Deploy MembershipManager
        bytes memory membershipMgrImplBytecode = type(MembershipManager).creationCode;
        address payable membershipMgrImpl = deployWithCreate2(membershipMgrImplBytecode, "MembershipManagerImpl");
        membershipManagerImplementation = MembershipManager(membershipMgrImpl);
        
        bytes memory membershipMgrImplInitBytecode = type(MembershipManagerInit).creationCode;
        address payable membershipMgrInitImpl = deployWithCreate2(membershipMgrImplInitBytecode, "MembershipManagerImplInit");
        membershipManagerImplementationInit = MembershipManagerInit(membershipMgrImpl);

        bytes memory membershipMgrProxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(membershipMgrInitImpl, ""));
        address payable membershipMgrProxy = deployWithCreate2(membershipMgrProxyBytecode, "MembershipManager");
        membershipManagerProxy = UUPSProxy(membershipMgrProxy);
        membershipManager = MembershipManager(payable(membershipMgrProxy));
    }
    
    function deployTestTokens() internal {
        bytes memory rETHBytecode = abi.encodePacked(type(TestERC20).creationCode, abi.encode("Rocket Pool ETH", "rETH"));
        address payable rETHAddr = deployWithCreate2(rETHBytecode, "rETH");
        rETH = TestERC20(rETHAddr);
        
        bytes memory cbEthBytecode = abi.encodePacked(type(TestERC20).creationCode, abi.encode("Staked ETH", "wstETH"));
        address payable cbEthAddr = deployWithCreate2(cbEthBytecode, "cbEth");
        cbEth = TestERC20(cbEthAddr);
        
        bytes memory wstETHBytecode = abi.encodePacked(type(TestERC20).creationCode, abi.encode("Coinbase ETH", "cbEth"));
        address payable wstETHAddr = deployWithCreate2(wstETHBytecode, "wstETH");
        wstETH = TestERC20(wstETHAddr);
        
        bytes memory sfrxEthBytecode = abi.encodePacked(type(TestERC20).creationCode, abi.encode("Frax ETH", "sfrxEth"));
        address payable sfrxEthAddr = deployWithCreate2(sfrxEthBytecode, "sfrxEth");
        sfrxEth = TestERC20(sfrxEthAddr);
    }
    
    function deployLiquidityPool() internal {
        bytes memory implBytecode = type(LiquidityPool).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "LiquidityPoolImpl");
        liquidityPoolImplementation = LiquidityPool(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "LiquidityPool");
        liquidityPoolProxy = UUPSProxy(proxy);
        liquidityPool = LiquidityPool(payable(proxy));
    }
    
    function deployEETH() internal {
        bytes memory implBytecode = type(EETH).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EETHImpl");
        eETHImplementation = EETH(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EETH");
        eETHProxy = UUPSProxy(proxy);
        eETHInstance = EETH(proxy);
        
        eETHInstance.initialize(payable(address(liquidityPool)));
    }
    
    function deployEtherFiOracle() internal {
        bytes memory implBytecode = type(EtherFiOracle).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiOracleImpl");
        etherFiOracleImplementation = EtherFiOracle(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiOracle");
        etherFiOracleProxy = UUPSProxy(proxy);
        etherFiOracle = EtherFiOracle(proxy);
    }
    
    function deployEtherFiAdmin() internal {
        bytes memory implBytecode = type(EtherFiAdmin).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiAdminImpl");
        etherFiAdminImplementation = EtherFiAdmin(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiAdmin");
        etherFiAdminProxy = UUPSProxy(proxy);
        etherFiAdmin = EtherFiAdmin(payable(proxy));
    }
    
    function deployWeETH() internal {
        bytes memory implBytecode = type(WeETH).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "WeETHImpl");
        weEthImplementation = WeETH(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "WeETH");
        weETHProxy = UUPSProxy(proxy);
        weEthInstance = WeETH(proxy);
        
        weEthInstance.initialize(payable(address(liquidityPool)), address(eETHInstance));
    }
    
    function deployRoleRegistry() internal {
        bytes memory implBytecode = type(RoleRegistry).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "RoleRegistryImpl");
        roleRegistryImplementation = RoleRegistry(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "RoleRegistry");
        roleRegistryProxy = UUPSProxy(proxy);
        roleRegistry = RoleRegistry(proxy);
        
        roleRegistry.initialize(msg.sender);
    }
    
    function deployEtherFiOperationParameters() internal {
        bytes memory implBytecode = type(EtherFiOperationParameters).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiOperationParametersImpl");
        etherFiOperationParametersImplementation = EtherFiOperationParameters(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiOperationParameters");
        etherFiOperationParametersProxy = UUPSProxy(proxy);
        etherFiOperationParameters = EtherFiOperationParameters(proxy);
        
        etherFiOperationParameters.initialize();
    }
    
    function deployBucketRateLimiter() internal {
        bytes memory implBytecode = type(BucketRateLimiter).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "BucketRateLimiterImpl");
        bucketRateLimiterImplementation = BucketRateLimiter(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "BucketRateLimiter");
        bucketRateLimiterProxy = UUPSProxy(proxy);
        bucketRateLimiter = BucketRateLimiter(proxy);
        
        bucketRateLimiter.initialize();
    }
    
    function deployTVLOracle() internal {
        // TVLOracle is not upgradeable, needs tvlAggregator address
        // For now, use treasury as placeholder
        bytes memory bytecode = abi.encodePacked(type(TVLOracle).creationCode, abi.encode(treasury));
        address payable deployed = deployWithCreate2(bytecode, "TVLOracle");
        tvlOracle = TVLOracle(deployed);
    }
    
    function deployEtherFiTimelock() internal {
        // EtherFiTimelock is not upgradeable
        uint256 minDelay = 2 days; // 48 hours delay
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = msg.sender;
        executors[0] = msg.sender;
        
        bytes memory bytecode = abi.encodePacked(
            type(EtherFiTimelock).creationCode, 
            abi.encode(minDelay, proposers, executors, msg.sender)
        );
        address payable deployed = deployWithCreate2(bytecode, "EtherFiTimelock");
        etherFiTimelock = EtherFiTimelock(payable(deployed));
    }
    
    function deployLiquifier() internal {
        bytes memory implBytecode = type(Liquifier).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "LiquifierImpl");
        liquifierImplementation = Liquifier(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "Liquifier");
        liquifierProxy = UUPSProxy(proxy);
        liquifier = Liquifier(payable(proxy));
        
        // Initialize with placeholder addresses for now
        // These would need to be set to actual protocol addresses on mainnet
        liquifier.initialize(
            treasury,
            address(liquidityPool),
            0xeE45e76ddbEDdA2918b8C7E3035cd37Eab3b5D41, // StrategyManager on Hoodi
            0x07F941C56f155fA4233f0ed8d351C9Af3152E525, // Lido WithdrawalQueue on Hoodi
            0x2C220A2a91602dd93bEAC7b3A1773cdADE369ba1, // stETH on Hoodi
            address(cbEth),
            address(0), // wbETH - placeholder
            address(0), // cbEth_Eth_Pool - placeholder
            address(0), // wbEth_Eth_Pool - placeholder
            address(0), // stEth_Eth_Pool - placeholder
            86400 // 1 day timeBoundCapRefreshInterval
        );
    }
    
    function deployEtherFiRestaker() internal {
        // EtherFiRestaker needs rewardsCoordinator in constructor
        bytes memory bytecode = abi.encodePacked(
            type(EtherFiRestaker).creationCode,
            abi.encode(0x29e8572678e0c272350aa0b4B8f304E47EBcd5e7) // RewardsCoordinator on Hoodi
        );
        address payable implementation = deployWithCreate2(bytecode, "EtherFiRestakerImpl");
        etherFiRestakerImplementation = EtherFiRestaker(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiRestaker");
        etherFiRestakerProxy = UUPSProxy(proxy);
        etherFiRestaker = EtherFiRestaker(payable(proxy));
        
        etherFiRestaker.initialize(address(liquidityPool), address(liquifier));
    }
    
    function deployEtherFiRewardsRouter() internal {
        // EtherFiRewardsRouter needs constructor params
        bytes memory implBytecode = abi.encodePacked(
            type(EtherFiRewardsRouter).creationCode,
            abi.encode(address(liquidityPool), treasury, address(roleRegistry))
        );
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiRewardsRouterImpl");
        etherFiRewardsRouterImplementation = EtherFiRewardsRouter(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiRewardsRouter");
        etherFiRewardsRouterProxy = UUPSProxy(proxy);
        etherFiRewardsRouter = EtherFiRewardsRouter(payable(proxy));
        
        etherFiRewardsRouter.initialize();
    }
    
    function deployAddressProvider() internal {
        // AddressProvider is not upgradeable
        bytes memory bytecode = abi.encodePacked(type(AddressProvider).creationCode, abi.encode(msg.sender));
        address deployed = deployWithCreate2(bytecode, "AddressProvider");
        addressProvider = AddressProvider(deployed);
    }
    
    function deployEtherFiViewer() internal {
        bytes memory implBytecode = type(EtherFiViewer).creationCode;
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiViewerImpl");
        etherFiViewerImplementation = EtherFiViewer(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiViewer");
        etherFiViewerProxy = UUPSProxy(proxy);
        etherFiViewer = EtherFiViewer(proxy);
        
        etherFiViewer.initialize(address(addressProvider));
    }
    
    function deployRedemptionManager() internal {
        // EtherFiRedemptionManager needs constructor params
        bytes memory implBytecode = abi.encodePacked(
            type(EtherFiRedemptionManager).creationCode,
            abi.encode(
                address(liquidityPool),
                address(eETHInstance),
                address(weEthInstance),
                treasury,
                address(roleRegistry)
            )
        );
        address payable implementation = deployWithCreate2(implBytecode, "EtherFiRedemptionManagerImpl");
        redemptionManagerImplementation = EtherFiRedemptionManager(implementation);
        
        bytes memory proxyBytecode = abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(implementation, ""));
        address payable proxy = deployWithCreate2(proxyBytecode, "EtherFiRedemptionManager");
        redemptionManagerProxy = UUPSProxy(proxy);
        redemptionManager = EtherFiRedemptionManager(payable(proxy));
        
        // Initialize with parameters
        redemptionManager.initialize(
            5000, // exitFeeSplitToTreasuryInBps 50%
            50,   // exitFeeInBps 0.5%
            9000, // lowWatermarkInBpsOfTvl 90%
            100 ether, // bucketCapacity 100 ETH
            1 ether    // bucketRefillRate 1 ETH
        );
    }
    
    function setupDependencies() internal {
        // Setup dependencies
        NodeOperatorManager(nodeOperatorManager).setAuctionContractAddress(address(auctionManager));
        
        auctionManager.setStakingManagerContractAddress(address(stakingManager));
        
        protocolRevenueManager.setAuctionManagerAddress(address(auctionManager));
        protocolRevenueManager.setEtherFiNodesManagerAddress(address(etherFiNodesManager));
        
        stakingManager.setEtherFiNodesManagerAddress(address(etherFiNodesManager));
        stakingManager.setLiquidityPoolAddress(address(liquidityPool));
        stakingManager.registerEtherFiNodeImplementationContract(address(etherFiNode));
        stakingManager.registerTNFTContract(address(TNFTInstance));
        stakingManager.registerBNFTContract(address(BNFTInstance));
        
        // Setup AddressProvider with deployed contracts
        addressProvider.addContract(address(etherFiNodesManager), "EtherFiNodesManager");
        addressProvider.addContract(address(liquidityPool), "LiquidityPool");
        addressProvider.addContract(address(stakingManager), "StakingManager");
        addressProvider.addContract(address(auctionManager), "AuctionManager");
        addressProvider.addContract(address(eETHInstance), "EETH");
        addressProvider.addContract(address(weEthInstance), "WeETH");
        addressProvider.addContract(address(etherFiAdmin), "EtherFiAdmin");
        addressProvider.addContract(address(etherFiOracle), "EtherFiOracle");
        addressProvider.addContract(address(membershipManager), "MembershipManager");
        addressProvider.addContract(address(roleRegistry), "RoleRegistry");
        addressProvider.addContract(address(redemptionManager), "RedemptionManager");
        addressProvider.addContract(address(etherFiRewardsRouter), "RewardsRouter");
        addressProvider.addContract(address(etherFiRestaker), "EtherFiRestaker");
        addressProvider.addContract(address(liquifier), "Liquifier");
    }
    
    function initializeContracts() internal {
        MembershipManagerInit(payable(membershipManager)).initialize(liquidityPool,eETHInstance,membershipNFT,treasury);
        membershipManager.initializeOnUpgrade(address(etherFiAdmin),10,7);


        // Initialize LiquidityPool
        liquidityPool.initialize(
            address(eETHInstance), 
            address(stakingManager), 
            address(etherFiNodesManager), 
            address(membershipManager), 
            address(TNFTInstance), 
            address(etherFiAdmin), 
            address(withdrawRequestNFT)
        );
        
        // Initialize contracts that require liquidityPool address
        withdrawRequestNFT.initialize(payable(address(liquidityPool)), address(eETHInstance), address(membershipManager));
        membershipNFT.initialize("https://ether.fi/", address(membershipManager));
        
        // Initialize EtherFiOracle with Hoodi parameters
        uint32 HOODI_GENESIS_TIME = 1742213400; // March 17, 2025, 12:10 UTC
        etherFiOracle.initialize(
            1, // quorumSize - 1 committee member for Hoodi (single oracle setup)
            1024, // reportPeriodSlot - 32 epochs (1024 slots)
            0, // reportStartSlot - start from slot 0
            32, // slotsPerEpoch
            12, // secondsPerSlot
            HOODI_GENESIS_TIME // Hoodi genesis time
        );
        
        // Add oracle committee member
        address oracle1 = 0x100007b3D3DeFCa2D3ECD1b9c52872c93Ad995c5;
        // address oracle2 = 0x20000a680D595B637F591030630365662D9866E1; // Not used in single oracle setup
        etherFiOracle.addCommitteeMember(oracle1);
        // etherFiOracle.addCommitteeMember(oracle2);
        
        // Grant oracle admin permissions to committee member
        etherFiOracle.updateAdmin(oracle1, true);
        // etherFiOracle.updateAdmin(oracle2, true);
        
        // Initialize EtherFiAdmin with oracle address
        etherFiAdmin.initialize(
            address(etherFiOracle), // oracle address
            address(stakingManager),
            address(auctionManager),
            address(etherFiNodesManager),
            address(liquidityPool),
            address(membershipManager),
            address(withdrawRequestNFT),
            10000, // 100% max APR change (10000 bps) - matching reference
            0  // no wait time for testing - matching reference
        );
        
        // Initialize role registry for EtherFiAdmin
        etherFiAdmin.initializeRoleRegistry(address(roleRegistry));
        
        // Note: MembershipManager's initializeOnUpgrade can only be called by the owner
        // Since the contract is not initialized yet, it has no owner
        // The initialization must be done in a separate transaction after deployment
        
        // Add missing initialization calls
        // Initialize LiquidityPool V2.49 upgrade
        liquidityPool.initializeVTwoDotFourNine(address(roleRegistry), address(redemptionManager));
        
        // Initialize LiquidityPool on upgrade with Liquifier
        liquidityPool.initializeOnUpgrade(address(auctionManager), address(liquifier));
        
        
        // Initialize WithdrawRequestNFT on upgrade
        withdrawRequestNFT.initializeOnUpgrade(address(roleRegistry), 1000);
        
        // Initialize AuctionManager on upgrade
        auctionManager.initializeOnUpgrade(
            address(membershipManager),
            1 ether, // accumulatedRevenueThreshold
            address(etherFiAdmin),
            address(nodeOperatorManager)
        );
        
        // Initialize TNFT and BNFT on upgrade
        TNFTInstance.initializeOnUpgrade(address(etherFiNodesManager));
        BNFTInstance.initializeOnUpgrade(address(etherFiNodesManager));
        
        // Set the deployer as admin for RegulationsManager
        address deployer = msg.sender;
        regulationsManagerInstance.updateAdmin(deployer, true);
        
        regulationsManagerInstance.initializeNewWhitelist(initialHash);
        
        // Set oracle admin
        etherFiOracle.setEtherFiAdmin(address(etherFiAdmin));

        stakingManager.initializeOnUpgrade(address(nodeOperatorManager),address(etherFiAdmin));
    }
    
    function getEthDepositContractAddress() internal view returns (address) {
        if (block.chainid == 5) {
            // goerli
            return 0xff50ed3d0ec03aC01D4C79aAd74928BFF48a7b2b;
        } else if (block.chainid == 1) {
            // mainnet
            return 0x00000000219ab540356cBB839Cbe05303d7705Fa;
        } else if (block.chainid == 560048) {
            // hoodi
            return 0x00000000219ab540356cBB839Cbe05303d7705Fa;
        } else if (block.chainid == 31337) {
            // local anvil/hardhat
            return 0x00000000219ab540356cBB839Cbe05303d7705Fa;
        } else {
            revert("Unsupported chain ID");
        }
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Create2Factory first
        create2Factory = new Create2Factory();
        
        // Deploy in phases to avoid stack too deep
        deployTreasury();
        deployNodeOperatorManager();
        deployAuctionManager();
        
        address ethDepositContractAddress = getEthDepositContractAddress();
        deployStakingManager(ethDepositContractAddress);
        deployEtherFiNode();
        
        deployNFTContracts();
        deployProtocolRevenueManager();
        deployEtherFiNodesManager();
        deployRegulationsManager();
        deployMembershipContracts();
        deployTestTokens();
        deployLiquidityPool();
        deployEETH();
        deployEtherFiOracle();
        deployEtherFiAdmin();
        deployWeETH();
        
        // Deploy independent contracts first
        deployRoleRegistry();
        deployEtherFiOperationParameters();
        deployBucketRateLimiter();
        deployTVLOracle();
        deployEtherFiTimelock();
        
        // Deploy Liquifier before EtherFiRestaker (dependency)
        deployLiquifier();
        deployEtherFiRestaker();
        
        // Deploy contracts that depend on previously deployed ones
        deployEtherFiRewardsRouter();
        deployAddressProvider();
        deployEtherFiViewer();
        
        // Deploy RedemptionManager after weETH and eETH
        deployRedemptionManager();
        
        setupDependencies();
        initializeContracts();
        
        // Grant minimal required roles for deployment to complete
        grantMinimalRoles();
        
        // Post-deployment configuration
        postDeploymentConfiguration();

        rollBack();
        
        // Print all deployed addresses
        printDeployedAddresses();
        
        vm.stopBroadcast();
        console.log("ALl done");
        suiteAddressesStruct = suiteAddresses({
            treasury: treasury,
            nodeOperatorManager: nodeOperatorManager,
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
            weEth: address(weEthInstance),
            etherFiAdmin: address(etherFiAdmin),
            withdrawRequestNFT: address(withdrawRequestNFT),
            membershipManager: address(membershipManager),
            membershipNFT: address(membershipNFT),
            etherFiOracle: address(etherFiOracle),
            etherFiOperationParameters: address(etherFiOperationParameters),
            etherFiViewer: address(etherFiViewer),
            etherFiRestaker: address(etherFiRestaker),
            etherFiRewardsRouter: address(etherFiRewardsRouter),
            roleRegistry: address(roleRegistry),
            etherFiTimelock: address(etherFiTimelock),
            bucketRateLimiter: address(bucketRateLimiter),
            tvlOracle: address(tvlOracle),
            liquifier: address(liquifier),
            etherFiNodeBeacon: stakingManager.getEtherFiNodeBeacon(),
            redemptionManager: address(redemptionManager)
        });

        writeSuiteVersionFile();
        writeLpVersionFile();

        // setupValidatorRegistration();
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
        uint256 version;
        
        // Try to read current version, default to 0 if file doesn't exist
        try vm.readLine("release/logs/EtherFiSuite/version.txt") returns (string memory versionString) {
            version = _stringToUint(versionString);
        } catch {
            version = 0;
        }

        version++;

        // Overwrites the version.txt file with incremented version
        vm.writeFile(
            "release/logs/EtherFiSuite/version.txt",
            string(abi.encodePacked(Strings.toString(version)))
        );

        // Build file path
        string memory filePath = string(
            abi.encodePacked(
                "release/logs/EtherFiSuite/",
                Strings.toString(version),
                ".release"
            )
        );

        // Write data in parts to avoid stack too deep
        writeSuiteAddressesPart1(filePath, version);
        writeSuiteAddressesPart2(filePath);
        writeSuiteAddressesPart3(filePath);
    }
    
    function writeSuiteAddressesPart1(string memory filePath, uint256 version) internal {
        string memory content = string(
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
                Strings.toHexString(suiteAddressesStruct.protocolRevenueManager)
            )
        );
        vm.writeFile(filePath, content);
    }
    
    function writeSuiteAddressesPart2(string memory filePath) internal {
        string memory existingContent = vm.readFile(filePath);
        string memory additionalContent = string(
            abi.encodePacked(
                existingContent,
                "\nTNFT: ",
                Strings.toHexString(suiteAddressesStruct.TNFT),
                "\nBNFT: ",
                Strings.toHexString(suiteAddressesStruct.BNFT),
                "\nEtherFiAdmin: ",
                Strings.toHexString(suiteAddressesStruct.etherFiAdmin),
                "\nWithdrawRequestNFT: ",
                Strings.toHexString(suiteAddressesStruct.withdrawRequestNFT),
                "\nMembershipManager: ",
                Strings.toHexString(suiteAddressesStruct.membershipManager),
                "\nMembershipNFT: ",
                Strings.toHexString(suiteAddressesStruct.membershipNFT),
                "\nEtherFiOracle: ",
                Strings.toHexString(suiteAddressesStruct.etherFiOracle)
            )
        );
        vm.writeFile(filePath, additionalContent);
    }
    
    function writeSuiteAddressesPart3(string memory filePath) internal {
        string memory existingContent = vm.readFile(filePath);
        string memory additionalContent = string(
            abi.encodePacked(
                existingContent,
                "\nEtherFiOperationParameters: ",
                Strings.toHexString(suiteAddressesStruct.etherFiOperationParameters),
                "\nEtherFiViewer: ",
                Strings.toHexString(suiteAddressesStruct.etherFiViewer),
                "\nEtherFiRestaker: ",
                Strings.toHexString(suiteAddressesStruct.etherFiRestaker),
                "\nEtherFiRewardsRouter: ",
                Strings.toHexString(suiteAddressesStruct.etherFiRewardsRouter),
                "\nRoleRegistry: ",
                Strings.toHexString(suiteAddressesStruct.roleRegistry),
                "\nEtherFiTimelock: ",
                Strings.toHexString(suiteAddressesStruct.etherFiTimelock),
                "\nBucketRateLimiter: ",
                Strings.toHexString(suiteAddressesStruct.bucketRateLimiter),
                "\nTVLOracle: ",
                Strings.toHexString(suiteAddressesStruct.tvlOracle),
                "\nLiquifier: ",
                Strings.toHexString(suiteAddressesStruct.liquifier),
                "\nEtherFiNodeBeacon: ",
                Strings.toHexString(suiteAddressesStruct.etherFiNodeBeacon),
                "\nRedemptionManager: ",
                Strings.toHexString(suiteAddressesStruct.redemptionManager)
            )
        );
        vm.writeFile(filePath, additionalContent);
    }

    function writeLpVersionFile() internal {
        uint256 version;
        
        // Try to read current version, default to 0 if file doesn't exist
        try vm.readLine("release/logs/LiquidityPool/version.txt") returns (string memory versionString) {
            version = _stringToUint(versionString);
        } catch {
            version = 0;
        }

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
    
    function grantMinimalRoles() internal {
        // Grant only the essential roles needed for the deployment script to complete
        address deployer = msg.sender;
        address oracle1 = 0x100007b3D3DeFCa2D3ECD1b9c52872c93Ad995c5;
        // address oracle2 = 0x20000a680D595B637F591030630365662D9866E1; // Not used in single oracle setup
        
        // Grant LIQUIDITY_POOL_ADMIN_ROLE to deployer for setFeeRecipient
        roleRegistry.grantRole(liquidityPool.LIQUIDITY_POOL_ADMIN_ROLE(), deployer);
        
        // Grant LIQUIDITY_POOL_ADMIN_ROLE to EtherFiAdmin for validator approval
        roleRegistry.grantRole(liquidityPool.LIQUIDITY_POOL_ADMIN_ROLE(), address(etherFiAdmin));
        
        // Grant PROTOCOL_UNPAUSER role to deployer for unPauseContract
        roleRegistry.grantRole(roleRegistry.PROTOCOL_UNPAUSER(), deployer);
        
        // CRITICAL: Grant oracle executor roles to oracle committee member
        roleRegistry.grantRole(etherFiAdmin.ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE(), oracle1);
        roleRegistry.grantRole(etherFiAdmin.ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE(), oracle1);

        roleRegistry.grantRole(etherFiAdmin.ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE(), deployer);

        // roleRegistry.grantRole(etherFiAdmin.ETHERFI_ORACLE_EXECUTOR_ADMIN_ROLE(), oracle2);
        // roleRegistry.grantRole(etherFiAdmin.ETHERFI_ORACLE_EXECUTOR_TASK_MANAGER_ROLE(), oracle2);
        
        // Grant WithdrawRequestNFT roles
        roleRegistry.grantRole(withdrawRequestNFT.WITHDRAW_REQUEST_NFT_ADMIN_ROLE(), address(etherFiAdmin));
        roleRegistry.grantRole(withdrawRequestNFT.IMPLICIT_FEE_CLAIMER_ROLE(), treasury);
        
        // Grant redemption manager admin role to deployer for initial configuration
        roleRegistry.grantRole(redemptionManager.ETHERFI_REDEMPTION_MANAGER_ADMIN_ROLE(), deployer);
        
        // Grant rewards router admin role for management
        roleRegistry.grantRole(etherFiRewardsRouter.ETHERFI_REWARDS_ROUTER_ADMIN_ROLE(), deployer);
    }
    
    function postDeploymentConfiguration() internal {
        // Set the fee recipient for protocol fees
        liquidityPool.setFeeRecipient(treasury);

        liquidityPool.setRestakeBnftDeposits(true);
        
        // Unpause the liquidity pool to enable operations
        liquidityPool.unPauseContract();
        
        // Unpause WithdrawRequestNFT after ensuring configuration is complete`
        if (withdrawRequestNFT.isScanOfShareRemainderCompleted()) {
            withdrawRequestNFT.unPauseContract();
        }
        
        // Configure operation parameters for Hoodi`
        configureOperationParameters();
    }
    
    function rollBack() internal {

        membershipManager.upgradeTo(address(membershipManagerImplementation));
    }
    
    function printDeployedAddresses() internal view {
        console.log("\n========================================");
        console.log("====== ALL DEPLOYED ADDRESSES =========");
        console.log("========================================\n");
        
        console.log("Core Infrastructure:");
        console.log("--------------------");
        console.log("Treasury:                    ", treasury);
        console.log("NodeOperatorManager (proxy): ", nodeOperatorManager);
        console.log("Create2Factory:              ", address(create2Factory));
        
        console.log("\nStaking Contracts:");
        console.log("--------------------");
        console.log("AuctionManager (proxy):      ", address(auctionManager));
        console.log("AuctionManager (impl):       ", address(auctionManagerImplementation));
        console.log("StakingManager (proxy):      ", address(stakingManager));
        console.log("StakingManager (impl):       ", address(stakingManagerImplementation));
        console.log("EtherFiNodesManager (proxy): ", address(etherFiNodesManager));
        console.log("EtherFiNodesManager (impl):  ", address(etherFiNodesManagerImplementation));
        console.log("EtherFiNode (implementation):", address(etherFiNode));
        console.log("EtherFiNode Beacon:          ", stakingManager.getEtherFiNodeBeacon());
        
        console.log("\nNFT Contracts:");
        console.log("--------------------");
        console.log("TNFT (proxy):                ", address(TNFTInstance));
        console.log("TNFT (impl):                 ", address(TNFTImplementation));
        console.log("BNFT (proxy):                ", address(BNFTInstance));
        console.log("BNFT (impl):                 ", address(BNFTImplementation));
        console.log("WithdrawRequestNFT (proxy):  ", address(withdrawRequestNFT));
        console.log("WithdrawRequestNFT (impl):   ", address(withdrawRequestNFTImplementation));
        console.log("MembershipNFT (proxy):       ", address(membershipNFT));
        console.log("MembershipNFT (impl):        ", address(membershipNFTImplementation));
        
        console.log("\nLiquidity & Tokens:");
        console.log("--------------------");
        console.log("LiquidityPool (proxy):       ", address(liquidityPool));
        console.log("LiquidityPool (impl):        ", address(liquidityPoolImplementation));
        console.log("eETH (proxy):                ", address(eETHInstance));
        console.log("eETH (impl):                 ", address(eETHImplementation));
        console.log("weETH (proxy):               ", address(weEthInstance));
        console.log("weETH (impl):                ", address(weEthImplementation));
        console.log("Liquifier (proxy):           ", address(liquifier));
        console.log("Liquifier (impl):            ", address(liquifierImplementation));
        console.log("RedemptionManager (proxy):   ", address(redemptionManager));
        console.log("RedemptionManager (impl):    ", address(redemptionManagerImplementation));
        
        console.log("\nTest Tokens:");
        console.log("--------------------");
        console.log("rETH:                        ", address(rETH));
        console.log("wstETH:                      ", address(wstETH));
        console.log("cbEth:                       ", address(cbEth));
        console.log("sfrxEth:                     ", address(sfrxEth));
        
        console.log("\nGovernance & Admin:");
        console.log("--------------------");
        console.log("EtherFiAdmin (proxy):        ", address(etherFiAdmin));
        console.log("EtherFiAdmin (impl):         ", address(etherFiAdminImplementation));
        console.log("RoleRegistry (proxy):        ", address(roleRegistry));
        console.log("RoleRegistry (impl):         ", address(roleRegistryImplementation));
        console.log("EtherFiTimelock:             ", address(etherFiTimelock));
        console.log("RegulationsManager (proxy):  ", address(regulationsManagerInstance));
        console.log("RegulationsManager (impl):   ", address(regulationsManagerImplementation));
        console.log("MembershipManager (proxy):   ", address(membershipManager));
        console.log("MembershipManager (impl):    ", address(membershipManagerImplementation));
        console.log("MembershipManager (init impl):", address(membershipManagerImplementationInit));
        
        console.log("\nOracle & Parameters:");
        console.log("--------------------");
        console.log("EtherFiOracle (proxy):       ", address(etherFiOracle));
        console.log("EtherFiOracle (impl):        ", address(etherFiOracleImplementation));
        console.log("EtherFiOperationParams (proxy):", address(etherFiOperationParameters));
        console.log("EtherFiOperationParams (impl):", address(etherFiOperationParametersImplementation));
        console.log("TVLOracle:                   ", address(tvlOracle));
        console.log("BucketRateLimiter (proxy):   ", address(bucketRateLimiter));
        console.log("BucketRateLimiter (impl):    ", address(bucketRateLimiterImplementation));
        
        console.log("\nRewards & Restaking:");
        console.log("--------------------");
        console.log("EtherFiRestaker (proxy):     ", address(etherFiRestaker));
        console.log("EtherFiRestaker (impl):      ", address(etherFiRestakerImplementation));
        console.log("EtherFiRewardsRouter (proxy):", address(etherFiRewardsRouter));
        console.log("EtherFiRewardsRouter (impl): ", address(etherFiRewardsRouterImplementation));
        console.log("ProtocolRevenueManager (proxy):", address(protocolRevenueManager));
        console.log("ProtocolRevenueManager (impl):", address(protocolRevenueManagerImplementation));
        
        console.log("\nUtility Contracts:");
        console.log("--------------------");
        console.log("EtherFiViewer (proxy):       ", address(etherFiViewer));
        console.log("EtherFiViewer (impl):        ", address(etherFiViewerImplementation));
        console.log("AddressProvider:             ", address(addressProvider));
        
        console.log("\n========================================");
        console.log("====== DEPLOYMENT COMPLETE ============");
        console.log("========================================\n");
    }
    function configureOperationParameters() internal {
        address oracle1 = 0x100007b3D3DeFCa2D3ECD1b9c52872c93Ad995c5;
        // address oracle2 = 0x20000a680D595B637F591030630365662D9866E1; // Not used in single oracle setup
        
        // Grant admin role to the deployer temporarily to set parameters
        etherFiOperationParameters.updateTagAdmin("ORACLE", msg.sender, true);
        
        // Set ORACLE parameters
        etherFiOperationParameters.updateTagKeyValue("ORACLE", "MAX_NUM_VALIDATORS_TO_APPROVE", "1500");
        etherFiOperationParameters.updateTagKeyValue("ORACLE", "MIN_SLOTS_TO_SUBMIT_REPORT", "2400");
        etherFiOperationParameters.updateTagKeyValue("ORACLE", "MAX_WITHDRAWAL_BPS", "1000"); // 10% max withdrawal
        etherFiOperationParameters.updateTagKeyValue("ORACLE", "TARGET_LIQUIDITY_IN_PERCENT_OF_TVL", "20"); // 2% target liquidity
        etherFiOperationParameters.updateTagKeyValue("ORACLE", "MIN_WITHDRAWAL_FINALIZATION_DELAY_IN_SLOTS", "6400"); // ~21 hours at 12 sec/slot
        
        // Grant admin role to oracle member so they can update parameters
        etherFiOperationParameters.updateTagAdmin("ORACLE", oracle1, true);
        // etherFiOperationParameters.updateTagAdmin("ORACLE", oracle2, true);
        
        // Revoke deployer's admin role if not needed
        etherFiOperationParameters.updateTagAdmin("ORACLE", msg.sender, false);
    }
}
