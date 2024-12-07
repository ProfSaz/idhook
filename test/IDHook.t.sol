// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "forge-std/console.sol";
import {IDHook} from "../src/IDHook.sol";

contract TestIDHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token;

    MockERC20 usdc;
    MockERC20 dai;
    MockERC20 idoToken = new MockERC20("idoT", "idoT", 18);

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;
    Currency daiCurrency;
    Currency usdcCurrency;

    address idoVault = makeAddr("idoVault");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address launcher = makeAddr("launcher");
    bytes32 idoId = keccak256("hello");
    uint256 totalAllocation = 1000 ether;

    IDHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        usdc = new MockERC20("usdc", "usdc", 18);
        dai = new MockERC20("dai", "dai", 18);

        usdcCurrency = Currency.wrap(address(usdc));
        daiCurrency = Currency.wrap(address(dai));

        dai.mint(user2, 1000 ether);
        dai.mint(user1, 1000 ether);
        usdc.mint(user2, 1000 ether);
        usdc.mint(user1, 1000 ether);
        idoToken.mint(launcher, 3000 ether);

        uint160 flags = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG| Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("IDHook.sol", abi.encode(manager, idoVault), address(flags));

        hook = IDHook(address(flags));

        vm.prank(idoVault);
        idoToken.approve(address(hook), type(uint256).max);

        usdc.approve(address(swapRouter), type(uint256).max);
        dai.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        dai.approve(address(modifyLiquidityRouter), type(uint256).max);

        vm.startPrank(user1);
        dai.approve(address(swapRouter), type(uint256).max);
        dai.approve(address(modifyLiquidityRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Initialize a pool
        (key,) = initPool(
            usdcCurrency,
            daiCurrency,
            hook,
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        uint256 totalAllocation = 1000 ether;
        uint256 startTime = 1 + block.timestamp;
        uint256 endTime = 5 + block.timestamp;

        vm.startPrank(launcher);
        idoToken.approve(address(hook), type(uint256).max);
        hook.registerIDO(idoId, address(idoToken), key, totalAllocation, startTime, endTime);
        vm.stopPrank();
    }

    function test_addLiquidity() public {
        // Retrieve IDO details from the hook contract
        (,,, uint256 startTime, uint256 endTime) = hook.idos(idoId);

        // Ensure the IDO is active
        vm.warp(startTime + 1);

        uint160 sqrtPriceX96 = SQRT_PRICE_1_1;
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 daiToAdd = 100 ether;

        uint128 liquidityDelta =
            LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, daiToAdd);

        uint256 usdcToAdd =
            LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceAtTickLower, sqrtPriceAtTickUpper, liquidityDelta);

        // console.log("Liquidity Delta:", liquidityDelta);
        // console.log("DAI to Add:", daiToAdd);
        // console.log("USDC to Add:", usdcToAdd);

        vm.startPrank(user1);

        // Approve the router to spend tokens
        dai.approve(address(modifyLiquidityRouter), daiToAdd);
        usdc.approve(address(modifyLiquidityRouter), usdcToAdd);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            abi.encode(user1, idoId)
        );
        vm.stopPrank();


        vm.startPrank(user2);

        // Approve the router to spend tokens
        dai.approve(address(modifyLiquidityRouter), daiToAdd);
        usdc.approve(address(modifyLiquidityRouter), usdcToAdd);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            abi.encode(user2, idoId)
        );
        vm.stopPrank();
        assertEq(hook.getUserAllocation(user2, idoId) + hook.getUserAllocation(user1, idoId), totalAllocation);
        assertEq(hook.getUserShares(user1) + hook.getUserShares(user2), hook.totalShares());

        console.log("user2 allocation", hook.getUserAllocation(user2, idoId));
        console.log("user1 allocation", hook.getUserAllocation(user1, idoId));
        console.log("total allcoation ", totalAllocation);
        console.log(" total shares ", hook.totalShares());
        console.log("user1 shares", hook.getUserShares(user1));
        console.log("user2 shares", hook.getUserShares(user2));
    }

    function test_swap() public {
        test_addLiquidity();

        vm.startPrank(user1);
        // Debug: Check router address and approvals
        console.log("Swap Router Address:", address(swapRouter));
        console.log("User1 DAI Approval to Router:", dai.allowance(user1, address(swapRouter)));

        int256 swapAmount = -10 ether;
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: swapAmount,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user1, idoId)
        );
        vm.stopPrank();

        assertApproxEqAbs(hook.getUserShares(user1) + hook.getUserShares(user2), hook.totalShares(), 0.001 ether);
        assertApproxEqAbs(
            hook.getUserAllocation(user2, idoId) + hook.getUserAllocation(user1, idoId), totalAllocation, 0.001 ether
        );
        assert(hook.getUserShares(user1) > hook.getUserShares(user2));

        // balances after swap
        // console.log("user2 allocation", hook.getUserAllocation(user2, idoId));
        // console.log("user1 allocation", hook.getUserAllocation(user1, idoId));
        // console.log("total allocation", totalAllocation);
        // console.log("total shares ", hook.totalShares());
        // console.log("user1 shares", hook.getUserShares(user1));
        // console.log("user2 shares", hook.getUserShares(user2));
    }

    function test_claim_allocation() public {
        test_addLiquidity();
        test_swap();

        console.log("balance of user1 before claim: ", idoToken.balanceOf(user1));

        (,,, uint256 startTime, uint256 endTime) = hook.idos(idoId);

        uint256 user1Allocation = hook.getUserAllocation(user1, idoId);

        // vm.prank(idoVault);
        vm.warp(endTime + 1);

        vm.startPrank(user1);
        hook.claimAllocation(idoId);
        vm.stopPrank();

        console.log(user1Allocation);
        console.log("balance of user1 after claim: ", idoToken.balanceOf(user1));
        console.log("allocation of user2:", hook.getUserAllocation(user2, idoId));
        console.log("balance of IdoVault", idoToken.balanceOf(idoVault));
    }
}
