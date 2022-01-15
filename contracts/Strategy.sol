// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/fei/ITribeChief.sol";
import "../interfaces/curve/IStableSwap.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/uniswap/IUniswapV2Pair.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    event Log();

    uint8 public immutable TRIBE_CHIEF_PID = 1;
    address public immutable TRIBE_ADDRESS =
        address(0xc7283b66Eb1EB5FB86327f08e1B5816b0720212B);
    address public immutable FEI_ADDRESS =
        address(0x956F47F50A910163D8BF957Cf5846D573E7f87CA);
    address public immutable WETH_ADDRESS =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public immutable TRIBE_CHIEF_ADDRESS =
        address(0x9e1076cC0d19F9B0b8019F384B0a29E48Ee46f7f);
    address public immutable UNISWAP_V2_ROUTER_ADDRESS =
        address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(address _vault) public BaseStrategy(_vault) {
        // approve uniswap v2 router to use tribe held by the strategy
        IERC20(address(0xc7283b66Eb1EB5FB86327f08e1B5816b0720212B)).approve(
            address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D),
            uint256(-1)
        );
        // approve tribe chief to use want held by the strategy
        want.approve(
            address(0x9e1076cC0d19F9B0b8019F384B0a29E48Ee46f7f),
            uint256(-1)
        );
        // approve curve pool to use fei held by the strategy
        IERC20(0x956F47F50A910163D8BF957Cf5846D573E7f87CA).approve(
            address(want),
            uint256(-1)
        );
    }

    function name() external view override returns (string memory) {
        return "StrategyCurveFEI3CRV";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // liquid want balance
        uint256 _wantBalance = want.balanceOf(address(this));

        // staked want balance
        uint256 _stakedWant =
            ITribeChief(TRIBE_CHIEF_ADDRESS).getTotalStakedInPool(
                TRIBE_CHIEF_PID,
                address(this)
            );

        // getting pending and held tribe
        uint256 _pendingTribe =
            ITribeChief(TRIBE_CHIEF_ADDRESS).pendingRewards(
                TRIBE_CHIEF_PID,
                address(this)
            );
        uint256 _heldTribe = IERC20(TRIBE_ADDRESS).balanceOf(address(this));
        uint256 _totalTribe = _heldTribe.add(_pendingTribe);

        uint256 _gainedWant = 0;
        if (_totalTribe > 0) {
            // getting fei acquired from selling tribe
            address[] memory _path = new address[](2);
            _path[0] = TRIBE_ADDRESS;
            _path[1] = FEI_ADDRESS;
            uint256[] memory _amountsOut =
                IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS).getAmountsOut(
                    _totalTribe,
                    _path
                );
            uint256 _feiAmount = _amountsOut[_amountsOut.length - 1];

            // getting the amount of lp tokens from lping on curve with the pending fei
            uint256[] memory _amounts = new uint256[](2);
            _amounts[0] = _feiAmount;
            _amounts[1] = 0;
            _gainedWant = IStableSwap(address(want)).calc_token_amount(
                _amounts,
                true
            );
        }

        return _wantBalance.add(_stakedWant).add(_gainedWant);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 _wantBalance = IERC20(want).balanceOf(address(this));

        // harvest tribe rewards
        ITribeChief(TRIBE_CHIEF_ADDRESS).harvest(
            TRIBE_CHIEF_PID,
            address(this)
        );

        // if any rewards were harvested, sell them for fei and deposit them
        // on curve, getting back more want in the process
        uint256 _sellableTribe = IERC20(TRIBE_ADDRESS).balanceOf(address(this));
        if (_sellableTribe > 0) {
            // selling tribe
            address[] memory _path = new address[](2);
            _path[0] = TRIBE_ADDRESS;
            _path[1] = FEI_ADDRESS;
            uint256[] memory _swappedAmounts =
                IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS)
                    .swapExactTokensForTokens(
                    _sellableTribe,
                    0,
                    _path,
                    address(this),
                    block.timestamp
                );

            // lping fei on curve to get back more want
            uint256[] memory _amounts = new uint256[](2);
            _amounts[0] = _swappedAmounts[_swappedAmounts.length - 1];
            _amounts[1] = 0;
            IStableSwap(address(want)).add_liquidity(_amounts, 0);
        }

        // calculate gross profit from rewards selling
        _profit = want.balanceOf(address(this)) - _wantBalance;

        // if the outstanding debt is not covered by the profit
        if (_debtOutstanding > _profit) {
            // liquidate part of the position to cover it
            uint256 _toLiquidate = _debtOutstanding.sub(_profit);
            (, uint256 _notLiquidated) = liquidatePosition(_toLiquidate);

            // if the liquidation incurred a loss, report it (in both cases when
            // the loss simply eats part of profit, or when it makes the overall
            // position a loss)
            if (_notLiquidated < _profit) _profit = _profit.sub(_notLiquidated);
            else {
                _loss = _notLiquidated.sub(_profit);
                _profit = 0;
            }
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            want.safeTransfer(address(vault), _debtOutstanding);
            return;
        }
        ITribeChief(TRIBE_CHIEF_ADDRESS).deposit(
            TRIBE_CHIEF_PID,
            _debtOutstanding,
            0
        );
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // require(false, "YOOOOOOOOOO");
        uint256 _wantBalance = want.balanceOf(address(this));

        // if the needed amount is more than the currently available one
        if (_amountNeeded > _wantBalance) {
            // check how much is currently staked
            uint256 _staked =
                ITribeChief(TRIBE_CHIEF_ADDRESS).getTotalStakedInPool(
                    TRIBE_CHIEF_PID,
                    address(this)
                );

            // unstake only the strictly necessary want (withdraw all is
            // used for convenience, then restaking everything extra)
            uint256 _netAmountNeeded = _amountNeeded.sub(_wantBalance);
            ITribeChief(TRIBE_CHIEF_ADDRESS).withdrawAllAndHarvest(
                TRIBE_CHIEF_PID,
                address(this)
            );
            uint256 _wantBalanceAfterUnstaking = want.balanceOf(address(this));
            uint256 _wantToRestake =
                _wantBalanceAfterUnstaking <= _amountNeeded
                    ? 0
                    : _wantBalanceAfterUnstaking.sub(_amountNeeded);
            if (_wantToRestake > 0)
                ITribeChief(TRIBE_CHIEF_ADDRESS).deposit(
                    TRIBE_CHIEF_PID,
                    _wantToRestake,
                    0
                );

            // update the want balance after having freed up what could have been freed up
            _wantBalance = want.balanceOf(address(this));
            _loss = _amountNeeded > _wantBalance
                ? _amountNeeded.sub(_wantBalance)
                : 0;
            _liquidatedAmount = _amountNeeded.sub(_loss);
        } else _liquidatedAmount = _amountNeeded;
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        uint256 _wantBalance = want.balanceOf(address(this));
        ITribeChief(TRIBE_CHIEF_ADDRESS).emergencyWithdraw(
            TRIBE_CHIEF_PID,
            address(this)
        );
        _amountFreed = want.balanceOf(address(this)).sub(_wantBalance);
    }

    function prepareMigration(address _newStrategy) internal override {
        // harvesting tribe and withdrawing all want
        ITribeChief(TRIBE_CHIEF_ADDRESS).withdrawAllAndHarvest(
            TRIBE_CHIEF_PID,
            address(this)
        );

        // transferring all tribe to the new strategy (if any)
        uint256 _tribeBalance = IERC20(TRIBE_ADDRESS).balanceOf(address(this));
        if (_tribeBalance > 0)
            IERC20(TRIBE_ADDRESS).transfer(_newStrategy, _tribeBalance);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory _protectedTokens = new address[](2);
        _protectedTokens[0] = TRIBE_ADDRESS;
        _protectedTokens[1] = FEI_ADDRESS;
        return _protectedTokens;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        address[] memory _path = new address[](2);
        _path[0] = WETH_ADDRESS;
        _path[1] = FEI_ADDRESS;
        uint256[] memory _amounts =
            IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS).getAmountsOut(
                1 ether,
                _path
            );
        uint256 _ethUsdPrice = _amounts[_amounts.length - 1];
        return
            _amtInWei
                .mul(_ethUsdPrice)
                .mul(IStableSwap(address(want)).get_virtual_price())
                .div(1e18);
    }

    function updateTribeUniswapV2RouterAllowance() external {
        IERC20(TRIBE_ADDRESS).approve(UNISWAP_V2_ROUTER_ADDRESS, uint256(-1));
    }

    function updateWantTribeChiefAllowance() external {
        want.approve(TRIBE_CHIEF_ADDRESS, uint256(-1));
    }

    function updateFeiCurvePoolAllowance() external {
        IERC20(FEI_ADDRESS).approve(address(want), uint256(-1));
    }
}
