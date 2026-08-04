// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IMiniV3MintCallback} from "./interface/IMiniV3MintCallback.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MiniV3Pool {
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

    mapping(bytes32 => Position) public positions;
    mapping(int24 => TickInfo) public ticks;

    error PoolAlreadyInitialized();
    error AmountMustBeMoreThenZero();
    error TicksMismatch();
    error InsufficientToken0();
    error InsufficientToken1();

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

        amount1 = FullMath.mulDiv(
            _liquidity,
            sqrtRatioBX96 - sqrtRatioAX96,
            1 << 96
        );
    }

    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
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
}
