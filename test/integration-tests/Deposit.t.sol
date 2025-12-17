// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../TestSetup.sol";
import "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/draft-IERC20PermitUpgradeable.sol";

import "../../src/DepositAdapter.sol";

contract DepositIntegrationTest is TestSetup {
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // DepositAdapter internal depositAdapterInstance;
    IWETH internal weth = IWETH(MAINNET_WETH);
    IwstETH internal wstEthToken = IwstETH(MAINNET_WSTETH);

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);
    }

    function test_Deposit_LiquidityPool_deposit() public {
        vm.deal(alice, 10 ether);

        uint256 beforeShares = eETHInstance.shares(alice);

        vm.prank(alice);
        uint256 mintedShares = liquidityPoolInstance.deposit{value: 1 ether}();

        assertGt(mintedShares, 0);
        assertEq(eETHInstance.shares(alice), beforeShares + mintedShares);
    }

    function test_Deposit_Liquifier_depositWithERC20_stETH() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        stEth.submit{value: 1 ether}(address(0));

        uint256 stEthAmount = stEth.balanceOf(alice);
        uint256 beforeShares = eETHInstance.shares(alice);

        vm.startPrank(alice);
        stEth.approve(address(liquifierInstance), stEthAmount);
        uint256 mintedShares = liquifierInstance.depositWithERC20(address(stEth), stEthAmount, address(0));
        vm.stopPrank();

        assertGt(mintedShares, 0);
        assertEq(eETHInstance.shares(alice), beforeShares + mintedShares);
    }

    function test_Deposit_Liquifier_depositWithERC20WithPermit_stETH() public {
        if (liquifierInstance.isDepositCapReached(address(stEth), 1 ether)) {
            vm.startPrank(liquifierInstance.owner());
            liquifierInstance.updateDepositCap(address(stEth), type(uint32).max, type(uint32).max);
            vm.stopPrank();
        }
        vm.deal(tom, 10 ether);
        vm.prank(tom);
        stEth.submit{value: 1 ether}(address(0));

        uint256 stEthAmount = stEth.balanceOf(tom);
        uint256 beforeShares = eETHInstance.shares(tom);

        ILiquifier.PermitInput memory permitInput = _permitInputForStEth(
            1202, address(liquifierInstance), stEthAmount, stEth.nonces(tom), 2**256 - 1, stEth.DOMAIN_SEPARATOR() // tom = vm.addr(1202)
        );

        vm.prank(tom);
        uint256 mintedShares = liquifierInstance.depositWithERC20WithPermit(address(stEth), stEthAmount, address(0), permitInput);

        assertGt(mintedShares, 0);
        assertEq(eETHInstance.shares(tom), beforeShares + mintedShares);
    }

    function test_Deposit_DepositAdapter_depositETHForWeETH() public {
        vm.deal(alice, 10 ether);

        uint256 beforeWeETH = weEthInstance.balanceOf(alice);
        uint256 beforeEETHShares = eETHInstance.shares(alice);
        uint256 beforeEETHAmount = eETHInstance.balanceOf(address(weEthInstance));
        uint256 liquidityPoolBalanceBeforeDeposit = address(liquidityPoolInstance).balance;
        uint256 ETHAmount = 1 ether;

        uint256 eETHSharesForAmount = liquidityPoolInstance.sharesForAmount(ETHAmount); // shares for the ETH amount
        uint256 eETHAmountForShares = liquidityPoolInstance.amountForShare(eETHSharesForAmount); // weETH amount for the shares
        uint256 weETHAmountForEETHAmount = liquidityPoolInstance.sharesForAmount(eETHAmountForShares); // weETH amount for the eETH amount

        vm.prank(alice);
        uint256 weEthOut = depositAdapterInstance.depositETHForWeETH{value: ETHAmount}(address(0));

        assertApproxEqAbs(weEthOut, weETHAmountForEETHAmount, 1e1);
        assertEq(weEthInstance.balanceOf(alice), beforeWeETH + weEthOut); // weETH is transferred to the alice
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), beforeEETHAmount + eETHAmountForShares); // eETH is transferred to the weETH contract
        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalanceBeforeDeposit + ETHAmount); // ETH is transferred to the liquidity pool
    }

    function test_Deposit_DepositAdapter_depositWETHForWeETH() public {
        vm.deal(alice, 10 ether);

        // Get wETH to deposit adapter
        uint256 wETHAmount = 1 ether;
        uint256 beforeWETHContractBalance = weth.balanceOf(address(weth));
        vm.startPrank(alice);
        weth.deposit{value: wETHAmount}();
        weth.approve(address(depositAdapterInstance), wETHAmount);
        vm.stopPrank();

        uint256 beforeWeETH = weEthInstance.balanceOf(alice);
        uint256 beforeWETHBalance = weth.balanceOf(alice);
        uint256 beforeDepositAdapterWETHBalance = weth.balanceOf(address(depositAdapterInstance));
        uint256 beforeEETHAmount = eETHInstance.balanceOf(address(weEthInstance));
        uint256 liquidityPoolBalanceBeforeDeposit = address(liquidityPoolInstance).balance;

        uint256 eETHSharesForAmount = liquidityPoolInstance.sharesForAmount(wETHAmount); // shares for the WETH amount
        uint256 eETHAmountForShares = liquidityPoolInstance.amountForShare(eETHSharesForAmount); // weETH amount for the shares
        uint256 weETHAmountForEETHAmount = liquidityPoolInstance.sharesForAmount(eETHAmountForShares); // weETH amount for the eETH amount

        vm.prank(alice);
        uint256 weEthOut = depositAdapterInstance.depositWETHForWeETH(wETHAmount, address(0));

        assertApproxEqAbs(weEthOut, weETHAmountForEETHAmount, 1e1);
        assertEq(weEthInstance.balanceOf(alice), beforeWeETH + weEthOut); // weETH is transferred to the alice
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), beforeEETHAmount + eETHAmountForShares); // eETH is transferred to the weETH contract
        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalanceBeforeDeposit + wETHAmount); // ETH is transferred to the liquidity pool
        assertEq(weth.balanceOf(alice), beforeWETHBalance - wETHAmount); // WETH is consumed from alice
        assertEq(weth.balanceOf(address(weth)), beforeWETHContractBalance); // WETH is taken from the weth contract and sent back to the weth contract
        assertEq(weth.balanceOf(address(depositAdapterInstance)), beforeDepositAdapterWETHBalance); // WETH balance of the deposit adapter is unchanged
    }

    function test_Deposit_DepositAdapter_depositStETHForWeETHWithPermit() public {
        vm.deal(tom, 10 ether);
        vm.prank(tom);
        stEth.submit{value: 1 ether}(address(0));

        uint256 stEthAmount = stEth.balanceOf(tom);
        uint256 beforeWeETH = weEthInstance.balanceOf(tom);
        uint256 beforeEETHAmount = eETHInstance.balanceOf(address(weEthInstance));
        uint256 liquidityPoolBalanceBeforeDeposit = address(liquidityPoolInstance).balance;
        uint256 beforeStETHBalance = stEth.balanceOf(address(etherFiRestakerInstance));

        (uint256 weETHAmountForEETHAmount, uint256 eETHAmountForShares) = _expectedWeETHOutAndEETHAmountForStEth(stEthAmount);

        ILiquifier.PermitInput memory permitInput = _permitInputForStEth(1202, address(depositAdapterInstance), stEthAmount, stEth.nonces(tom), 2**256 - 1, stEth.DOMAIN_SEPARATOR()); // tom = vm.addr(1202)

        vm.prank(tom);
        uint256 weEthOut = depositAdapterInstance.depositStETHForWeETHWithPermit(stEthAmount, address(0), permitInput);

        assertApproxEqAbs(weEthOut, weETHAmountForEETHAmount, 1e1);
        assertEq(weEthInstance.balanceOf(tom), beforeWeETH + weEthOut); // weETH is transferred to the tom
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), beforeEETHAmount + eETHAmountForShares); // eETH is transferred to the weETH contract
        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalanceBeforeDeposit); // stETH path should not move ETH in the pool
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), beforeStETHBalance + stEthAmount, 1e3); // stETH is transferred to the etherFiRestakerInstance
    }

    function _permitInputForStEth(uint256 privateKey, address spender, uint256 value, uint256 nonce, uint256 deadline, bytes32 domainSeparator)
        internal
        view
        returns (ILiquifier.PermitInput memory permitInput)
    {
        address _owner = vm.addr(privateKey);
        bytes32 digest = calculatePermitDigest(_owner, spender, value, nonce, deadline, domainSeparator);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        permitInput = ILiquifier.PermitInput({value: value, deadline: deadline, v: v, r: r, s: s});
        return permitInput;
    }

    function _expectedWeETHOutAndEETHAmountForStEth(uint256 stEthAmount)
        internal
        view
        returns (uint256 expectedWeETHOut, uint256 expectedEETHAmount)
    {
        uint256 eETHAmountForStEthAmount = liquifierInstance.quoteByDiscountedValue(address(stEth), stEthAmount);
        uint256 eETHSharesForAmount = liquidityPoolInstance.sharesForAmount(eETHAmountForStEthAmount);
        expectedEETHAmount = liquidityPoolInstance.amountForShare(eETHSharesForAmount);
        expectedWeETHOut = liquidityPoolInstance.sharesForAmount(expectedEETHAmount);
    }

    function test_Deposit_DepositAdapter_depositWstETHForWeETHWithPermit() public {
        vm.deal(tom, 10 ether);
        vm.prank(tom);
        stEth.submit{value: 1 ether}(address(0));

        // Wrap stETH -> wstETH
        vm.startPrank(tom);
        stEth.approve(MAINNET_WSTETH, stEth.balanceOf(tom));
        uint256 wstEthAmount = wstEthToken.wrap(stEth.balanceOf(tom));
        vm.stopPrank();

        uint256 beforeWeETH = weEthInstance.balanceOf(tom);
        uint256 beforeEETHAmount = eETHInstance.balanceOf(address(weEthInstance));
        uint256 liquidityPoolBalanceBeforeDeposit = address(liquidityPoolInstance).balance;
        uint256 beforeStETHBalance = stEth.balanceOf(address(etherFiRestakerInstance));

        uint256 stEthAmountForWstEthAmount = _stEthForWstEth(wstEthAmount);
        (uint256 weETHAmountForEETHAmount, uint256 eETHAmountForShares) =
            _expectedWeETHOutAndEETHAmountForStEth(stEthAmountForWstEthAmount);

        ILiquifier.PermitInput memory permitInput = _permitInputForStEth(
            1202, // tom = vm.addr(1202)
            address(depositAdapterInstance),
            wstEthAmount,
            IERC20PermitUpgradeable(MAINNET_WSTETH).nonces(tom),
            2**256 - 1,
            IERC20PermitUpgradeable(MAINNET_WSTETH).DOMAIN_SEPARATOR()
        );

        vm.prank(tom);
        uint256 weEthOut = depositAdapterInstance.depositWstETHForWeETHWithPermit(wstEthAmount, address(0), permitInput);

        assertApproxEqAbs(weEthOut, weETHAmountForEETHAmount, 1e1);
        assertEq(weEthInstance.balanceOf(tom), beforeWeETH + weEthOut); // weETH is transferred to the tom
        assertEq(eETHInstance.balanceOf(address(weEthInstance)), beforeEETHAmount + eETHAmountForShares); // eETH is transferred to the weETH contract
        assertEq(address(liquidityPoolInstance).balance, liquidityPoolBalanceBeforeDeposit); // wstETH path should not move ETH in the pool
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), beforeStETHBalance + stEthAmountForWstEthAmount, 1e3); // stETH is transferred to the etherFiRestakerInstance
    }

    function _stEthForWstEth(uint256 wstEthAmount) internal view returns (uint256 stEthAmount) {
        // Prefer canonical Lido view helpers; fall back to stEthPerToken().
        (bool ok, bytes memory data) = MAINNET_WSTETH.staticcall(
            abi.encodeWithSignature("getStETHByWstETH(uint256)", wstEthAmount)
        );
        if (ok && data.length == 32) return abi.decode(data, (uint256));

        (ok, data) = MAINNET_WSTETH.staticcall(abi.encodeWithSignature("stEthPerToken()"));
        require(ok && data.length == 32, "WSTETH_CONVERSION_UNAVAILABLE");
        uint256 stEthPerToken = abi.decode(data, (uint256));
        return (wstEthAmount * stEthPerToken) / 1e18;
    }

// No role of EETH in this flow.
    function test_Deposit_EtherFiRestaker_depositIntoStrategy() public {
        vm.deal(alice, 10 ether);

        vm.prank(alice);
        stEth.submit{value: 1 ether}(address(0));

        uint256 stEthAmount = stEth.balanceOf(alice);

        address eigenLayerRestakingStrategy = address(etherFiRestakerInstance.getEigenLayerRestakingStrategy(address(stEth)));
        uint256 stETHBalanceOfStrategyBeforeDeposit = stEth.balanceOf(eigenLayerRestakingStrategy);
        console.log("eigenLayerRestakingStrategy", eigenLayerRestakingStrategy);

        // transfer stETH from alice to the restaker
        vm.prank(alice);
        stEth.transfer(address(etherFiRestakerInstance), stEthAmount);

        uint256 stETHAmountOfRestakerBeforeDeposit = stEth.balanceOf(address(etherFiRestakerInstance));
        vm.prank(etherFiRestakerInstance.owner());
        uint256 shares = etherFiRestakerInstance.depositIntoStrategy(address(stEth), stEthAmount);

        assertGt(shares, 0);
        assertApproxEqAbs(stEth.balanceOf(eigenLayerRestakingStrategy), stETHBalanceOfStrategyBeforeDeposit + stEthAmount, 1e3);
        assertApproxEqAbs(stEth.balanceOf(address(etherFiRestakerInstance)), stETHAmountOfRestakerBeforeDeposit - stEthAmount, 1e3);
        assertApproxEqAbs(stEth.balanceOf(alice), 0, 1e3);
    }
}