// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract IDHook is BaseHook {
    event IDORegistered(
        bytes32 indexed idoId, address idoToken, uint256 totalAllocation, uint256 startTime, uint256 endTime
    );

    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    struct IDOMetadata {
        address idoToken;
        PoolKey key;
        uint256 totalAllocation;
        uint256 startTime;
        uint256 endTime;
    }

    mapping(address => mapping(bytes32 => uint256)) public liquidityStartTime; // Track when user started providing liquidity
    mapping(address => mapping(bytes32 => uint256)) public accruedShares; // Track accumulated shares

    mapping(bytes32 => IDOMetadata) public idos;
    address public idoVault;
    uint256 public totalShares;
    mapping(address => uint256) public userShares;
    uint128 constant WEIGHT = 1e18;

    constructor(IPoolManager _manager, address idoVault_) BaseHook(_manager) {
        idoVault = idoVault_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        (address user, bytes32 idoId) = abi.decode(hookData, (address, bytes32));
        require(_matchesPoolKey(key, idos[idoId].key), "Invalid PoolKey for this IDO");

        uint256 rawShares;

        if (swapParams.zeroForOne) {
            rawShares = uint256(int256(-delta.amount0()));
        } else {
            rawShares = uint256(int256(-delta.amount1()));
        }

        _assignShares(user, rawShares, WEIGHT);

        return (this.afterSwap.selector, 0);
    }

   function afterAddLiquidity(
    address,
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata,
    BalanceDelta delta,
    BalanceDelta,
    bytes calldata hookData
) external override onlyPoolManager returns (bytes4, BalanceDelta) {
    (address user, bytes32 idoId) = abi.decode(hookData, (address, bytes32));

    require(_matchesPoolKey(key, idos[idoId].key), "Invalid PoolKey for this IDO");
    IDOMetadata storage ido = idos[idoId];
    require(block.timestamp >= ido.startTime && block.timestamp <= ido.endTime, "Outside IDO period");

    uint256 rawShares = uint256(int256(-delta.amount0()) + int256(-delta.amount1()));
    
    // Calculate the proportion of the IDO period remaining
    uint256 timeRemaining = ido.endTime - block.timestamp;
    uint256 totalIdoPeriod = ido.endTime - ido.startTime;
    uint256 timeRatio = (timeRemaining * 1e18) / totalIdoPeriod;

    // Calculate time-weighted shares
    uint256 weightedShares = _calculateShares(rawShares, timeRatio);

    if (liquidityStartTime[user][idoId] == 0) {
        liquidityStartTime[user][idoId] = block.timestamp;
        accruedShares[user][idoId] = weightedShares;
        totalShares += weightedShares;
    } else {
        // Update accrued shares with time-weighted calculation
        accruedShares[user][idoId] += weightedShares;
        totalShares += weightedShares;
        liquidityStartTime[user][idoId] = block.timestamp;
    }

    return (this.afterAddLiquidity.selector, delta);
}

function afterRemoveLiquidity(
    address,
    PoolKey calldata key,
    IPoolManager.ModifyLiquidityParams calldata,
    BalanceDelta delta,
    BalanceDelta,
    bytes calldata hookData
) external override onlyPoolManager returns (bytes4, BalanceDelta) {
    (address user, bytes32 idoId) = abi.decode(hookData, (address, bytes32));
    require(_matchesPoolKey(key, idos[idoId].key), "Invalid PoolKey for this IDO");

    IDOMetadata storage ido = idos[idoId];

    // Check if user had active liquidity for this IDO
    if (liquidityStartTime[user][idoId] != 0) {
        uint256 rawShares = uint256(int256(-delta.amount0()) + int256(-delta.amount1()));
        
        // Determine the end time for calculation (either current time or IDO end time)
        uint256 calculationEndTime = block.timestamp > ido.endTime ? ido.endTime : block.timestamp;
        
        // Calculate actual time liquidity was provided
        uint256 timeProvided = calculationEndTime - liquidityStartTime[user][idoId];
        uint256 totalIdoPeriod = ido.endTime - ido.startTime;

        // Ensure time provided doesn't exceed total IDO period
        timeProvided = timeProvided > totalIdoPeriod ? totalIdoPeriod : timeProvided;

        // Calculate time-weighted shares
        uint256 timeRatio = (timeProvided * 1e18) / totalIdoPeriod;
        uint256 weightedShares = _calculateShares(rawShares, timeRatio);
        
        // Update accrued shares
        accruedShares[user][idoId] += weightedShares;

        // If removing before IDO end, stop tracking liquidity
        if (block.timestamp <= ido.endTime) {
            liquidityStartTime[user][idoId] = 0;
        }
    }

    return (this.afterRemoveLiquidity.selector, delta);
}

function claimAllocation(bytes32 idoId) external {
    IDOMetadata storage ido = idos[idoId];
    require(block.timestamp > ido.endTime, "IDO still in progress");

    // Finalize shares if liquidity was still active at IDO end
    if (liquidityStartTime[msg.sender][idoId] != 0) {
        uint256 timeProvided = ido.endTime - liquidityStartTime[msg.sender][idoId];
        uint256 totalIdoPeriod = ido.endTime - ido.startTime;
        uint256 timeRatio = (timeProvided * 1e18) / totalIdoPeriod;
        
        uint256 remainingLiquidityShares = _calculateShares(userShares[msg.sender], timeRatio);
        accruedShares[msg.sender][idoId] += remainingLiquidityShares;
        
        liquidityStartTime[msg.sender][idoId] = 0; // Reset tracking
    }

    uint256 allocation = getUserAllocation(msg.sender, idoId);
    require(allocation > 0, "No allocation available");

    // Reduce total allocation and user shares
    ido.totalAllocation -= allocation;
    userShares[msg.sender] = 0;
    accruedShares[msg.sender][idoId] = 0;

    // Transfer allocation
    IERC20(ido.idoToken).transferFrom(idoVault, msg.sender, allocation);
}

function getUserAllocation(address user, bytes32 idoId) public view returns (uint256) {
    IDOMetadata storage ido = idos[idoId];
    uint256 userShares_ = accruedShares[user][idoId];

    if (userShares_ == 0 || totalShares == 0) {
        return 0;
    }

    return (userShares_ * ido.totalAllocation) / totalShares;
}

    function getAccruedShare(address user, bytes32 idoId) public view returns(uint256) {
        return accruedShares[user][idoId];
    }

    function _calculateTimeWeightedShares(address user, bytes32 idoId, uint256 currentTime, uint256 weightedShares)
        internal
        view
        returns (uint256)
    {
        IDOMetadata storage ido = idos[idoId];

        uint256 timeHeld = currentTime - liquidityStartTime[user][idoId];
        uint256 idoDuration = ido.endTime - ido.startTime;

        // Proportion of IDO duration the liquidity was held for
        return (weightedShares * timeHeld) / idoDuration;
    }

    //probably use keccak to get byteId
    function registerIDO(
        bytes32 idoId,
        address idoToken,
        PoolKey calldata key,
        uint256 totalAllocation,
        uint256 startTime,
        uint256 endTime
    ) external {
        require(idos[idoId].idoToken == address(0), "IDO already registered");
        require(startTime >= block.timestamp, " Invalid startTime");
        require(endTime > startTime, "Invalid timeline");

        require(idoToken != address(0), "idoToken cannot be address(0)");

        IDOMetadata storage ido = idos[idoId];
        ido.idoToken = idoToken;
        ido.key = key;
        ido.totalAllocation = totalAllocation;
        ido.startTime = startTime;
        ido.endTime = endTime;

        IERC20(idoToken).transferFrom(msg.sender, idoVault, totalAllocation);

        emit IDORegistered(idoId, idoToken, totalAllocation, startTime, endTime);
    }

    function _matchesPoolKey(PoolKey calldata key, PoolKey storage idoKey) internal view returns (bool) {
        return (key.currency0 == idoKey.currency0 && key.currency1 == idoKey.currency1)
            || (key.currency0 == idoKey.currency1 && key.currency1 == idoKey.currency0);
    }

    function _assignShares(address user, uint256 rawShares, uint256 weight) internal {
        uint256 weightedShares = _calculateShares(rawShares, weight);
        userShares[user] += weightedShares;
        totalShares += weightedShares;
    }

    function _calculateShares(uint256 amount, uint256 weight) internal pure returns (uint256) {
        return (amount * weight) / 1e18;
    }

    function getUserShares(address user) public view returns (uint256) {
        return userShares[user];
    }

    // function getUserAllocation(address user, bytes32 idoId) public view returns (uint256) {
    //     IDOMetadata storage ido = idos[idoId];
    //     uint256 userShares_ = accruedShares[user][idoId];

    //     if (userShares_ == 0 || totalShares == 0) {
    //         return 0;
    //     }

    //     return (userShares_ * ido.totalAllocation) / totalShares;
    // }

    // function claimAllocation(bytes32 idoId) external {
    //     require(block.timestamp > idos[idoId].endTime, "IDO still in progress");

    //     // Finalize shares if not already
    //     if (liquidityStartTime[msg.sender][idoId] != 0) {
    //         uint256 currentWeightedShares = _calculateShares(userShares[msg.sender], WEIGHT);
    //         accruedShares[msg.sender][idoId] +=
    //             _calculateTimeWeightedShares(msg.sender, idoId, idos[idoId].endTime, currentWeightedShares);
    //         liquidityStartTime[msg.sender][idoId] = 0; // Reset tracking
    //     }

    //     uint256 allocation = (accruedShares[msg.sender][idoId] * idos[idoId].totalAllocation) / totalShares;
    //     require(allocation > 0, "No allocation available");

    //     IDOMetadata storage ido = idos[idoId];
    //     idos[idoId].totalAllocation -= allocation;
    //     userShares[msg.sender] = 0;

    //     IERC20(ido.idoToken).transferFrom(idoVault, msg.sender, allocation);
    // }
}
