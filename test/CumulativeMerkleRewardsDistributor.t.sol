import "./TestSetup.sol";
import "forge-std/console2.sol";

contract  CumulativeMerkleRewardsDistributorTest is TestSetup {
    address[] public accounts = new address[](4);
    uint256[] public amounts = new uint256[](4);
    bytes32[] public leaves = new bytes32[](4);
    bytes32 public node1;
    bytes32 public node2;
    bytes32 public merkleRoot;
    bytes32[][] public proofs = new bytes32[][](4);


    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b 
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function generateMerkleTree(uint256 multipler) internal {
        // Create leaves for each account/amount pair
        for(uint256 i = 0; i < 4; i++) {
            accounts[i] = address(uint160(i+1));
            amounts[i] = (i+1) * multipler * 1 ether;
            leaves[i] = keccak256(abi.encodePacked(accounts[i], amounts[i]));
            proofs[i] = new bytes32[](2);
            vm.prank(admin);
            cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[i], true);
        }

        node1 = hashPair(leaves[0], leaves[1]);
        node2 = hashPair(leaves[2], leaves[3]);
        merkleRoot = hashPair(node1, node2);

        proofs[0][0] = leaves[1];
        proofs[0][1] = node2;
        
        proofs[1][0] = leaves[0];
        proofs[1][1] = node2;    
        
        proofs[2][0] = leaves[3];          
        proofs[2][1] = node1;  

        proofs[3][0] = leaves[2];
        proofs[3][1] = node1;      
    }

    function setMerkleRoot(address token) internal {
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(token, merkleRoot);
    vm.roll(block.number + 15000);
    vm.warp(block.timestamp + 15000 * 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(token, block.number - 15000);
    vm.stopPrank();
    }

   //write setup method
   function setUp() public {
    setUpTests();
    generateMerkleTree(100);
    rETH.mint(address(cumulativeMerkleRewardsDistributorInstance), 1000 ether);
    vm.deal(address(cumulativeMerkleRewardsDistributorInstance), 1000 ether);
    vm.prank(address(cumulativeMerkleRewardsDistributorInstance));
    liquidityPoolInstance.deposit{value: 1000 ether}();
   } 

   function test_claiming() public {
    setMerkleRoot(address(eETHInstance));
    vm.prank(accounts[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[1], 200 ether, merkleRoot, proofs[1]); 
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[2], 300 ether, merkleRoot, proofs[2]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[3], 400 ether, merkleRoot, proofs[3]);
    assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
    assertEq(eETHInstance.balanceOf(accounts[1]), 200 ether);
    assertEq(eETHInstance.balanceOf(accounts[2]), 300 ether);
    assertEq(eETHInstance.balanceOf(accounts[3]), 400 ether);
   }

   function test_verification() public {
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.MerkleRootWasUpdated.selector);
    //need to pass correct merkle root
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, bytes32(uint256(1)), proofs[0]);
    setMerkleRoot(address(eETHInstance));
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], false);
    //claimer must be whitelisted
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.NonWhitelistedUser.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]); 
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], true);
    vm.stopPrank();

    //must provide correct balance
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[0]);

    //must provide  correct user
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[1]);
 
    //must provide  correct user
    bytes32[] memory incorrectProofs = new bytes32[](2);
    incorrectProofs[0] = proofs[0][0];
    incorrectProofs[1] = proofs[0][0];
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InvalidProof.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, incorrectProofs);
   }

   function test_whitelisting() public {
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.IncorrectRole.selector);
    cumulativeMerkleRewardsDistributorInstance.updateWhitelistedRecipient(accounts[0], false);
   }

   function test_claiming_delay() public {
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
    vm.roll(block.number + 14399);
    vm.warp(block.timestamp + 14399 * 12);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.InsufficentDelay.selector);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    vm.roll(block.number + 1);
    vm.warp(block.timestamp + 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    vm.assertEq(cumulativeMerkleRewardsDistributorInstance.claimableMerkleRoots(address(eETHInstance)), merkleRoot);
    vm.stopPrank();
   }

   function test_multiple_token() public {
    setMerkleRoot(address(eETHInstance));
    setMerkleRoot(address(rETH));
    console.logBytes32(merkleRoot);

    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    cumulativeMerkleRewardsDistributorInstance.claim(address(rETH), accounts[0], 100 ether, merkleRoot, proofs[0]);
    assertEq(eETHInstance.balanceOf(accounts[0]), 100 ether);
    assertEq(rETH.balanceOf(accounts[0]), 100 ether);
   }

   function test_cummulative_claim() public {
    setMerkleRoot(address(eETHInstance));
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    generateMerkleTree(200);
    setMerkleRoot(address(eETHInstance));
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 200 ether, merkleRoot, proofs[0]);
   }

   function test_pausing() public {
    vm.prank(chad);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.IncorrectRole.selector);
    cumulativeMerkleRewardsDistributorInstance.pause();
    vm.startPrank(admin);
    cumulativeMerkleRewardsDistributorInstance.pause();
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    cumulativeMerkleRewardsDistributorInstance.claim(address(eETHInstance), accounts[0], 100 ether, merkleRoot, proofs[0]);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    cumulativeMerkleRewardsDistributorInstance.setPendingMerkleRoot(address(eETHInstance), merkleRoot);
    vm.expectRevert(ICumulativeMerkleRewardsDistributor.ContractPaused.selector);
    vm.roll(block.number + 15000);
    vm.warp(block.timestamp + 15000 * 12);
    cumulativeMerkleRewardsDistributorInstance.finalizeMerkleRoot(address(eETHInstance), block.number - 12000);
    cumulativeMerkleRewardsDistributorInstance.unpause();
    test_claiming();
    vm.stopPrank();
   }
   function test_upgrading() public {
    vm.prank(chad);
    vm.expectRevert(RoleRegistry.OnlyProtocolUpgrader.selector);
    cumulativeMerkleRewardsDistributorInstance.upgradeTo(address(0x555));
    CumulativeMerkleRewardsDistributor newImpl = new CumulativeMerkleRewardsDistributor(address(roleRegistryInstance)); 
    vm.prank(roleRegistryInstance.owner());
    cumulativeMerkleRewardsDistributorInstance.upgradeTo(address(newImpl));
    vm.assertEq(cumulativeMerkleRewardsDistributorInstance.getImplementation(), address(newImpl));
   }

   function test_verify_bytes() public {
    initializeRealisticFork(MAINNET_FORK);
    CumulativeMerkleRewardsDistributor cumulativeMerkleRewardsDistributorImplementation = new CumulativeMerkleRewardsDistributor(address(roleRegistryInstance));
    CumulativeMerkleRewardsDistributor cumulativeMerkleRewardsDistributorInstance = CumulativeMerkleRewardsDistributor(payable(0x9A8c5046a290664Bf42D065d33512fe403484534));
    address deployedProxy = address(0x9A8c5046a290664Bf42D065d33512fe403484534);
    address deployedImpl = address(0xD3F3480511FB25a3D86568B6e1eFBa09d0aDEebF);
    verifyContractByteCodeMatch(deployedImpl, address(cumulativeMerkleRewardsDistributorImplementation));
    verifyContractByteCodeMatch(deployedProxy, address(cumulativeMerkleRewardsDistributorInstance));
   }
}