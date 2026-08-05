// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMiniV3MintCallback} from "./interface/IMiniV3MintCallback.sol";
import {IMiniV3SwapCallback} from "./interface/IMiniV3SwapCallback.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MiniV3Pool {
    using SafeERC20 for IERC20;

    address public immutable token0;
    address public immutable token1;

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }

    Slot0 public slot0;

    uint128 public liquidity;

    struct TickInfo {
        int128 deltaLiquidity;
        bool initialized;
    }

    struct Position {
        uint128 liquidity;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    mapping(bytes32 => Position) public positions;
    mapping(int24 => TickInfo) public ticks;

    error PoolAlreadyInitialized();
    error AmountMustBeMoreThenZero();
    error TicksMismatch();
    error InsufficientToken0();
    error InsufficientToken1();
    error AmountCantBeZero();
    error PoolNotInitialized();

    event Initialize(uint160 startingSqrtPriceX96, int24 indexed startingTick);

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function initialize(uint160 _startingSqrtPriceX96, int24 _startingTick) external {
        if (slot0.sqrtPriceX96 != 0) revert PoolAlreadyInitialized();
        slot0 = Slot0({sqrtPriceX96: _startingSqrtPriceX96, tick: _startingTick});

        emit Initialize(_startingSqrtPriceX96, _startingTick);
    }

    function _calcAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 _liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        uint256 numerator1 = uint256(_liquidity) << 96;

        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        uint256 step1 = FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96);

        amount0 = step1 / sqrtRatioAX96;
    }

    function _calcAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 _liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        amount1 = FullMath.mulDiv(_liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    function _getNextSqrtPriceFromInput(uint160 sqrtPriceX96, uint128 _liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtRatioNextX96)
    {
        if (amountIn == 0) return sqrtPriceX96;

        uint256 numerator1 = uint256(_liquidity) << 96;

        if (zeroForOne) {
            uint256 product = amountIn * sqrtPriceX96;
            uint256 denominator = product + numerator1;
            sqrtRatioNextX96 = uint160(FullMath.mulDiv(numerator1, sqrtPriceX96, denominator));
        } else {
            uint256 quotient = (amountIn << 96) / _liquidity;
            sqrtRatioNextX96 = sqrtPriceX96 + uint160(quotient);
        }
    }

    function _computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 _liquidity,
        uint256 amountRemaining,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut) {
        uint256 amountInToTarget = zeroForOne
            ? _calcAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, _liquidity)
            : _calcAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, _liquidity);

        // 2. Хватает ли у нас токенов?
        if (amountRemaining >= amountInToTarget) {
            sqrtRatioNextX96 = sqrtRatioTargetX96;
            amountIn = amountInToTarget;
        } else {
            amountIn = amountRemaining;
            sqrtRatioNextX96 = _getNextSqrtPriceFromInput(sqrtRatioCurrentX96, _liquidity, amountIn, zeroForOne);
        }

        amountOut = zeroForOne
            ? _calcAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, _liquidity)
            : _calcAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, _liquidity);
    }

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
    }

    function _getNextInitializedTick(int24 tick, bool zeroForOne)
        internal
        view
        returns (int24 nextTick, bool initialized)
    {
        // TODO: Заглушка. В реальном V3 здесь идет побитовый поиск по маппингу tickBitmap.
    }

    function mint(address owner, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (amount == 0) revert AmountMustBeMoreThenZero();
        if (tickLower >= tickUpper) revert TicksMismatch();

        bytes32 positionKey = keccak256(abi.encode(owner, tickLower, tickUpper));

        Position storage position = positions[positionKey];
        position.liquidity += amount;

        TickInfo storage updateLowerTick = ticks[tickLower];
        updateLowerTick.deltaLiquidity += int128(amount);
        updateLowerTick.initialized = true;

        TickInfo storage updateUpperTick = ticks[tickUpper];
        updateUpperTick.deltaLiquidity -= int128(amount);
        updateUpperTick.initialized = true;

        {
            Slot0 memory _slot0 = slot0;

            uint160 sqrtRatioAX96 = _getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = _getSqrtRatioAtTick(tickUpper);

            if (_slot0.tick < tickLower) {
                amount0 = _calcAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, amount);
            } else if (_slot0.tick >= tickUpper) {
                amount1 = _calcAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, amount);
            } else {
                amount0 = _calcAmount0Delta(_slot0.sqrtPriceX96, sqrtRatioBX96, amount);
                amount1 = _calcAmount1Delta(sqrtRatioAX96, _slot0.sqrtPriceX96, amount);

                liquidity += amount;
            }
        }

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = IERC20(token0).balanceOf(address(this));
        if (amount1 > 0) balance1Before = IERC20(token1).balanceOf(address(this));

        IMiniV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        if (amount0 > 0 && IERC20(token0).balanceOf(address(this)) < balance0Before + amount0) {
            revert InsufficientToken0();
        }
        if (amount1 > 0 && IERC20(token1).balanceOf(address(this)) < balance1Before + amount1) {
            revert InsufficientToken1();
        }
    }

    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert AmountCantBeZero();
        if (slot0.sqrtPriceX96 == 0) revert PoolNotInitialized();

        Slot0 memory _slot0 = slot0;
        uint128 _liquidity = liquidity;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: _slot0.sqrtPriceX96,
            tick: _slot0.tick
        });

        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) = _getNextInitializedTick(state.tick, zeroForOne);
            step.sqrtPriceNextX96 = _getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut) = _computeSwapStep(
                state.sqrtPriceX96, step.sqrtPriceNextX96, _liquidity, state.amountSpecifiedRemaining, zeroForOne
            );

            (state.sqrtPriceX96, step.amountIn, step.amountOut) = _computeSwapStep(
                state.sqrtPriceX96, step.sqrtPriceNextX96, _liquidity, state.amountSpecifiedRemaining, zeroForOne
            );

            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    int128 liquidityDelta = ticks[step.tickNext].deltaLiquidity;

                    if (zeroForOne) liquidityDelta = -liquidityDelta;

                    if (liquidityDelta < 0) {
                        _liquidity -= uint128(-liquidityDelta);
                    } else {
                        _liquidity += uint128(liquidityDelta);
                    }
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
            liquidity = _liquidity;
        }

        slot0 = Slot0({sqrtPriceX96: state.sqrtPriceX96, tick: state.tick});

        if (zeroForOne == true) {
            amount0 = int256(amountSpecified) - int256(state.amountSpecifiedRemaining);
            amount1 = -int256(state.amountCalculated);
        } else {
            amount1 = int256(amountSpecified) - int256(state.amountSpecifiedRemaining);
            amount0 = -int256(state.amountCalculated);
        }

        if (zeroForOne == true) {
            IERC20(token1).safeTransfer(recipient, uint256(-amount1));
        } else {
            IERC20(token0).safeTransfer(recipient, uint256(-amount0));
        }

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = IERC20(token0).balanceOf(address(this));
        if (amount1 > 0) balance1Before = IERC20(token1).balanceOf(address(this));

        IMiniV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);

        if (amount0 > 0 && IERC20(token0).balanceOf(address(this)) < balance0Before + uint256(amount0)) {
            revert InsufficientToken0();
        }
        if (amount1 > 0 && IERC20(token1).balanceOf(address(this)) < balance1Before + uint256(amount1)) {
            revert InsufficientToken1();
        }
    }
}
