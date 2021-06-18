// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/curve/IRewardsGauge.sol";
import "../../interfaces/curve/IStableSwapAave.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";

contract StrategyCurveAave is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address constant public wmatic = address(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    address constant public usdc = address(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    address constant public want = address(0xE7a24EF0C5e95Ffb0f6684b813A78F2a3AD7D171);
    address constant public swapToken = address(0x445FE580eF8d70FF569aB36e80c647af338db351);

    // Third party contracts
    address constant public rewards = address(0xe381C25de995d62b453aF8B931aAc84fcCaa7A62);

    // Routes
    address[] public wmaticToUsdcRoute = [wmatic, usdc];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    constructor(
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient
    ) StratManager(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) public {
        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            IRewardsGauge(rewards).deposit(wantBal);
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IRewardsGauge(rewards).withdraw(_amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin == owner() || paused()) {
            IERC20(want).safeTransfer(vault, wantBal);
        } else {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
        }
    }

    // compounds earnings and charges performance fee
    function harvest() external whenNotPaused onlyEOA {
        IRewardsGauge(rewards).claim_rewards(address(this));
        chargeFees();
        addLiquidity();
        deposit();

        emit StratHarvest(msg.sender);
    }

    // performance fees
    function chargeFees() internal {
        uint256 wmaticFeeBal = IERC20(wmatic).balanceOf(address(this)).mul(45).div(1000);

        uint256 callFeeAmount = wmaticFeeBal.mul(callFee).div(MAX_FEE);
        IERC20(wmatic).safeTransfer(msg.sender, callFeeAmount);

        uint256 beefyFeeAmount = wmaticFeeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(wmatic).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFee = wmaticFeeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wmatic).safeTransfer(strategist, strategistFee);
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 wmaticBal = IERC20(wmatic).balanceOf(address(this));
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(wmaticBal, 0, wmaticToUsdcRoute, address(this), now);

        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        uint256[3] memory amounts = [0, usdcBal, 0];
        IStableSwapAave(swapToken).add_liquidity(amounts, 0, true);
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        return IRewardsGauge(rewards).balanceOf(address(this));
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IRewardsGauge(rewards).withdraw(balanceOfPool());

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        IRewardsGauge(rewards).withdraw(balanceOfPool());
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(want).safeApprove(rewards, uint(-1));
        IERC20(wmatic).safeApprove(unirouter, uint(-1));
        IERC20(usdc).safeApprove(swapToken, uint(-1));
    }

    function _removeAllowances() internal {
        IERC20(want).safeApprove(rewards, 0);
        IERC20(wmatic).safeApprove(unirouter, 0);
        IERC20(usdc).safeApprove(swapToken, 0);
    }
}