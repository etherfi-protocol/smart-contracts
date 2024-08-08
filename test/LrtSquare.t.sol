// pragma solidity ^0.8.13;

// import "forge-std/Test.sol";
// import "forge-std/console.sol";

// import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

// import "../src/UUPSProxy.sol";
// import "../src/LrtSquare.sol";

// contract LrtSquareTest is Test {
//     address owner;
//     address alice;
//     address bob;

//     LrtSquare public lrtSquare;
//     ERC20PresetMinterPauser[] public tokens;

//     function setUp() public {
//         owner = vm.addr(1004);
//         alice = vm.addr(1005);
//         bob = vm.addr(1006);

//         vm.startPrank(owner);    
//         LrtSquare lrtSquareImpl = new LrtSquare();
//         UUPSProxy lrtSquareProxy = new UUPSProxy(address(lrtSquareImpl), "");
//         lrtSquare = LrtSquare(address(lrtSquareProxy));

//         lrtSquare.initialize("LrtSquare", "LRT2");

//         tokens = new ERC20PresetMinterPauser[](3);
//         for (uint256 i = 0; i < tokens.length; i++) {
//             tokens[i] = new ERC20PresetMinterPauser("Token", "TKN");
//         }
//         vm.stopPrank();
//     }

//     function test_mint() public {
//         vm.startPrank(owner);
//         for (uint256 i = 0; i < 3; i++) {
//             tokens[i].mint(owner, 100 ether);
//         }
//         lrtSquare.mint(alice, 1 ether);
//         assertEq(lrtSquare.balanceOf(alice), 1 ether);
//         vm.stopPrank();
//     }

//     function test_deposit_1() public {
//         test_mint();

//         lrtSquare.underlyingAssetsOf(alice);

//         address[] memory depositTokens = new address[](1);
//         uint256[] memory depositAmounts = new uint256[](1);

//         vm.startPrank(owner);
//         lrtSquare.registerToken(address(tokens[0]));

//         tokens[0].approve(address(lrtSquare), 10 ether);
//         depositTokens[0] = address(tokens[0]);
//         depositAmounts[0] = 10 ether;
//         lrtSquare.depositAndMint(depositTokens, depositAmounts, 0, address(0));
        
//         assertEq(lrtSquare.underlyingAssetOf(alice, address(tokens[0])), 10 ether);

//         // Can directly send tokens to the contract as well
//         ERC20(tokens[0]).transfer(address(lrtSquare), 10 ether);
//         assertEq(lrtSquare.underlyingAssetOf(alice, address(tokens[0])), 20 ether);

//         (address[] memory assets, uint256[] memory amounts) = lrtSquare.underlyingAssetsOf(alice);
//         assertEq(assets.length, 1);
//         assertEq(assets[0], address(tokens[0]));
//         assertEq(amounts[0], 20 ether);

//         vm.stopPrank();
//     }

//     function test_deposit_2() public {
//         test_deposit_1();
        
//         vm.startPrank(owner);

//         // Can directly send tokens to the contract as well
//         ERC20(tokens[1]).transfer(address(lrtSquare), 10 ether);

//         // However, it is not considered as an underlying asset unless it is registered
//         vm.expectRevert();
//         lrtSquare.underlyingAssetOf(alice, address(tokens[1]));

//         address[] memory assets;
//         uint256[] memory amounts;
//         (assets, amounts) = lrtSquare.underlyingAssetsOf(alice);
//         assertEq(assets.length, 1);
//         assertEq(assets[0], address(tokens[0]));

//         // Registered, now the token[1] holding is considered as an underlying asset 
//         lrtSquare.registerToken(address(tokens[1]));
//         (assets, amounts) = lrtSquare.underlyingAssetsOf(alice);
//         assertEq(assets.length, 2);
//         assertEq(assets[0], address(tokens[0]));
//         assertEq(assets[1], address(tokens[1]));

//         vm.stopPrank();
//     }

//     function test_redeem_1() public {
//         test_deposit_1();

//         assertEq(lrtSquare.underlyingAssetOf(alice, address(tokens[0])), 20 ether);

//         vm.startPrank(alice);

//         assertEq(lrtSquare.balanceOf(alice), 1 ether);
//         assertEq(lrtSquare.underlyingAssetOf(alice, address(tokens[0])), 20 ether);
//         assertEq(ERC20(tokens[0]).balanceOf(address(lrtSquare)), 20 ether);

//         lrtSquare.redeem(0.5 ether);
//         assertEq(lrtSquare.balanceOf(alice), 0.5 ether);
//         assertEq(lrtSquare.underlyingAssetOf(alice, address(tokens[0])), 20 ether * 1 / 2);
//         assertEq(ERC20(tokens[0]).balanceOf(address(lrtSquare)), 10 ether);

//         lrtSquare.redeem(0.5 ether);

//         vm.expectRevert("ZERO_SUPPLY");
//         lrtSquare.underlyingAssetOf(alice, address(tokens[0]));

//         assertEq(ERC20(tokens[0]).balanceOf(address(lrtSquare)), 0);

//         vm.stopPrank();
//     }

//     function test_avs_rewards_scenario_1() public {
//         address merkleDistributor = vm.addr(1007);

//         vm.startPrank(owner);
//         lrtSquare.registerToken(address(tokens[0]));
//         lrtSquare.registerToken(address(tokens[1]));

//         // 1. At week-0, ether.fi receives an AVS reward 'tokens[0]'
//         // Assume that only alice was holding 1 weETH
//         // 
//         // Perform `depositAndMint`
//         // - ether.fi sends the 'tokens[o]' rewards 100 ether to the LrtSquare vault
//         // - ether.fi mints LRT^2 tokens 1 ether to merkleDistributor. merkleDistributor will distribute the LrtSquare to Alice
//         tokens[0].mint(owner, 100 ether);
//         tokens[0].approve(address(lrtSquare), 100 ether);
//         {
//             address[] memory assets = new address[](1);
//             uint256[] memory amounts = new uint256[](1);
//             assets[0] = address(tokens[0]);
//             amounts[0] = 100 ether;
//             lrtSquare.depositAndMint(assets, amounts, 1 ether, merkleDistributor);
//             // 1 ether LRT^2 == {tokens[0]: 100 ether}
//         }

//         // 2. At week-1, ether.fi receives rewards
//         // Assume that {alice, bob} were holding 1 weETH
//         tokens[0].mint(owner, 200 ether);
//         tokens[0].approve(address(lrtSquare), 200 ether);
//         {
//             address[] memory assets = new address[](1);
//             uint256[] memory amounts = new uint256[](1);
//             assets[0] = address(tokens[0]);
//             amounts[0] = 200 ether;
//             lrtSquare.depositAndMint(assets, amounts, 2 ether, merkleDistributor);
//             // (1 + 2) ether LRT^2 == {tokens[0]: 100 + 200 ether} 
//             // --> 1 ether LRT^2 == {tokens[0]: 100 ether}
//         }

//         // 3. At week-3, ether.fi receives rewards
//         // Assume that {alice, bob} were holding 1 weETH
//         // but AVS rewards amount has decreased to 100 ether
//         tokens[0].mint(owner, 100 ether);
//         tokens[0].approve(address(lrtSquare), 100 ether);
//         {
//             address[] memory assets = new address[](1);
//             uint256[] memory amounts = new uint256[](1);
//             assets[0] = address(tokens[0]);
//             amounts[0] = 100 ether;

//             // lrtSquare.depositAndMint(assets, amounts, 2 ether, merkleDistributor);
//             /// @dev this will be unfair distribution to the existing holders of LRT^2
//             // (1 + 2 + 2) ether LRT^2 == {tokens[0]: 100 + 200 + 100 ether}
//             // After 'depositAndMint'. the value of LRT^2 token has decreased
//             // - from 1 ether LRT^2 == {tokens[0]: 100 ether} 
//             // - to 1 ether LRT^2 == {tokens[0]: 80 ether}

//             // (1 + 2 + x) ether LRT^2 == {tokens[0]: 100 + 200 + 100 ether}
//             // What should be 'x' to make it fair distribution; keep the current LRT^2 token's value the same after 'depositAndMint'
//             // 100 ether = (100 + 200 + 100) ether / (1 + 2 + x)
//             // => x = (100 + 200 + 100) / 100 - (1 + 2) = 1
//             uint256 x = 1 ether;
//             lrtSquare.depositAndMint(assets, amounts, x, merkleDistributor);
//             // (1 + 2 + 1) ether LRT^2 == {tokens[0]: 100 + 200 + 100 ether}
//             // --> 1 ether LRT^2 == {tokens[0]: 100 ether}
//         }

//         // 4. At week-3, ether.fi receives rewards from one more AVS
//         // Assume that {alice, bob} were holding 1 weETH
//         tokens[0].mint(owner, 100 ether);
//         tokens[1].mint(owner, 10 ether);
//         tokens[0].approve(address(lrtSquare), 100 ether);
//         tokens[1].approve(address(lrtSquare), 10 ether);
//         {
//             uint256 total_new_rewards_in_usdc;
//             uint256 total_current_lrtSquare_value_in_usdc;
//             uint256 lrtSquare_token_value_in_usdc;

//             address[] memory assets = new address[](2);
//             uint256[] memory amounts = new uint256[](2);
//             assets[0] = address(tokens[0]);
//             assets[1] = address(tokens[1]);
//             amounts[0] = 100 ether;
//             amounts[1] = 10 ether;

//             {
//                 // Calculate the total USDC value of the new rewards
//                 uint256 token0_rewards_value_in_usdc = queryTokenValue(assets[0]) * amounts[0] / 10 ** tokens[0].decimals();
//                 uint256 token1_rewards_value_in_usdc = queryTokenValue(assets[1]) * amounts[1] / 10 ** tokens[1].decimals();
//                 total_new_rewards_in_usdc = token0_rewards_value_in_usdc + token1_rewards_value_in_usdc; // Total new rewards in USDC

//                 // Calculate the current total USDC value held by LrtSquare before the new deposits
//                 (address[] memory currentAssets, uint256[] memory currentAmounts) = lrtSquare.totalUnderlyingAssets();
//                 for (uint256 i = 0; i < currentAssets.length; i++) {
//                     uint256 tokenAmount = IERC20(currentAssets[i]).balanceOf(address(lrtSquare));
//                     uint256 tokenValueInUSDC = queryTokenValue(currentAssets[i]);
//                     total_current_lrtSquare_value_in_usdc += tokenAmount * tokenValueInUSDC / 10 ** ERC20(currentAssets[i]).decimals();
//                 }
//                 lrtSquare_token_value_in_usdc = total_current_lrtSquare_value_in_usdc * 1 ether / lrtSquare.totalSupply();
//                 console.log("total_current_lrtSquare_value_in_usdc: %d", total_current_lrtSquare_value_in_usdc);
//                 console.log("lrtSquare_token_value_in_usdc: %d", lrtSquare_token_value_in_usdc);
//             }
//             // calculate using the above values:
//             // 1 ether LRT^2 == {tokens[0]: 100 ether} == 100 * 200 = 20000 USDC
//             lrtSquare.underlyingAssetsFor(1 ether);

//             // Calculate the number of new LRT^2 shares to mint based on the added USDC value
//             uint256 new_lrtSquare_tokens_to_mint = (total_new_rewards_in_usdc * lrtSquare.totalSupply()) / total_current_lrtSquare_value_in_usdc;
//             lrtSquare.depositAndMint(assets, amounts, new_lrtSquare_tokens_to_mint, merkleDistributor);

//             lrtSquare.underlyingAssetsFor(1 ether);
//             // 1 ether LRT^2 = {tokens[0]: 100 ether, tokens[1]: 10 ether} == 100 * 200 + 10 * 2000 = 22000 USDC
//         }

//         vm.stopPrank();
//     }

//     // Utility function to get current USD value of a token (per unit)
//     function queryTokenValue(address token) internal view returns (uint256) {
//         if (token == address(tokens[0])) {
//             return 200; // Assume each token is worth 200 USDC
//         } else if (token == address(tokens[1])) {
//             return 2000;  // Assume each token is worth 2000 USDC
//         }
//         return 0;
//     }

// }