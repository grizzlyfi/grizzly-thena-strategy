// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import { BaseStrategy, StrategyParams } from "./BaseStrategy.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { SafeMath } from "./library/SafeMath.sol";
import { SafeERC20 } from "./library/SafeERC20.sol";
import { Address } from "./library/Address.sol";
import { ERC20 } from "./library/ERC20.sol";
import { Math } from "./library/Math.sol";

import { ILpDepositor } from "../interfaces/ILpDepositor.sol";
import { IThenaRouter, route } from "../interfaces/IThenaRouter.sol";
import { IUniRouter } from "../interfaces/IUniswapV2Router02.sol";
import { IV1Pair } from "../interfaces/IThenaV1Pair.sol";

contract Strategy is BaseStrategy {
	using SafeERC20 for IERC20;
	using Address for address;
	using SafeMath for uint256;

	/**
	 * @dev Tokens Used:
	 * {wbnb} - Required for liquidity routing when doing swaps.
	 * {thenaReward} - Token generated by staking our funds.
	 * {thenaLp} - LP Token for Thena exchange.
	 * {want} - Tokens that the strategy maximizes. IUniswapV2Pair tokens.
	 */
	address internal constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); // WBNB
	address public constant thenaReward = address(0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11); // THENA
	address internal constant busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); // BUSD

	address public constant router = address(0x20a304a7d126758dfe6B243D0fc515F83bCA8431); // Thena Router
	ILpDepositor public masterChef; // {masterChef} - Depositor contract for Thena

	IV1Pair public thenaLp;
	IERC20 public token0;
	IERC20 public token1;

	uint256 public dust;
	uint256 public rewardDust;
	bool public collectFeesEnabled = false;

	uint256 public maxSlippageIn; // bps
	uint256 public maxSlippageOut; // bps

	bool internal abandonRewards;

	bool internal immutable isStable;
	uint256 internal constant basisOne = 10000;
	uint256 internal constant MAX = type(uint256).max;

	uint256 public minProfit;
	bool internal forceHarvestTriggerOnce;

	constructor(
		address _vault,
		address _masterChef,
		address _thenaLp
	) public BaseStrategy(_vault) {
		require(_thenaLp == address(want), "Wrong lpToken");

		thenaLp = IV1Pair(_thenaLp);
		isStable = thenaLp.isStable();

		token0 = IERC20(thenaLp.token0());
		token1 = IERC20(thenaLp.token1());

		maxSlippageIn = 9999;
		maxSlippageOut = 9999;

		maxReportDelay = 30 days;
		minProfit = 1e21;

		dust = 10**uint256((ERC20(address(want)).decimals()));
		rewardDust = 10**uint256((ERC20(address(thenaReward)).decimals()));

		masterChef = ILpDepositor(_masterChef);
		require(masterChef.TOKEN() == address(want), "Wrong masterChef");

		assert(masterChef.rewardToken() == thenaReward);

		_giveAllowances();
	}

	//-------------------------------//
	//       Public View func        //
	//-------------------------------//

	function name() external view override returns (string memory) {
		return string(abi.encodePacked("ThenaStrategy ", "Pool ", ERC20(address(want)).symbol()));
	}

	function estimatedTotalAssets() public view override returns (uint256) {
		return balanceOfWant().add(balanceOfLPInMasterChef());
	}

	function balanceOfWant() public view returns (uint256) {
		return want.balanceOf(address(this));
	}

	function balanceOfLPInMasterChef() public view returns (uint256 _amount) {
		_amount = masterChef.balanceOf(address(this));
	}

	function balanceOfReward() public view returns (uint256 _thenaRewards) {
		_thenaRewards = IERC20(thenaReward).balanceOf(address(this));
	}

	function pendingRewards() public view returns (uint256 _thenaBalance) {
		_thenaBalance = masterChef.earned(address(this));
	}

	function estimatedHarvest() public view returns (uint256 profitInBusd) {
		uint256 thenaBalance = pendingRewards().add(balanceOfReward());

		(uint256 profitInWbnb, ) = IThenaRouter(router).getAmountOut(
			thenaBalance,
			thenaReward,
			wbnb
		);

		(profitInBusd, ) = IThenaRouter(router).getAmountOut(profitInWbnb, wbnb, busd);
	}

	//-------------------------------//
	//      Internal Core func       //
	//-------------------------------//

	function prepareReturn(uint256 _debtOutstanding)
		internal
		override
		returns (
			uint256 _profit,
			uint256 _loss,
			uint256 _debtPayment
		)
	{
		if (_debtOutstanding > 0) {
			(_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
		}

		uint256 initialWantBalance = balanceOfWant();

		if (collectFeesEnabled) {
			_collectTradingFees();
		}

		// Claim rewards
		_claimRewards();
		// Sell rewards
		_sellRewards();
		// Convert to want
		_convertToLpToken();

		uint256 debt = vault.strategies(address(this)).totalDebt;
		uint256 currentBalance = estimatedTotalAssets();
		uint256 wantBalance = balanceOfWant();

		if (currentBalance > debt) {
			if (wantBalance > initialWantBalance) {
				_profit = wantBalance.sub(initialWantBalance);
			}
			_loss = 0;
			if (wantBalance < _profit) {
				// All reserve is profit
				_profit = wantBalance;
				_debtPayment = 0;
			} else if (wantBalance > _profit.add(_debtOutstanding)) {
				_debtPayment = _debtOutstanding;
			} else {
				_debtPayment = wantBalance.sub(_profit);
			}
		} else {
			_loss = debt.sub(currentBalance);
			_debtPayment = Math.min(wantBalance, _debtOutstanding);
		}

		// We're done harvesting, so reset our trigger if we used it
		forceHarvestTriggerOnce = false;
	}

	function adjustPosition(uint256 _debtOutstanding) internal override {
		// LP assets before the operation
		uint256 pooledBefore = balanceOfLPInMasterChef();

		// Claim THENA rewards
		_claimRewards();
		// Swap THENA for wBNB
		_sellRewards();
		// Swap wBNB for token0 & token1 and invest the LP
		_convertToLpToken();

		uint256 amountIn = balanceOfWant();

		if (amountIn > dust) {
			// Deposit all LP tokens in Thena masterChef
			depositLpIntoMasterChef();
			enforceSlippageIn(amountIn, pooledBefore);
		}
	}

	function liquidatePosition(uint256 _amountNeeded)
		internal
		override
		returns (uint256 _liquidatedAmount, uint256 _loss)
	{
		if (estimatedTotalAssets() <= _amountNeeded) {
			_liquidatedAmount = liquidateAllPositions();
			return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
		}

		uint256 looseAmount = balanceOfWant();
		if (_amountNeeded > looseAmount) {
			uint256 toExitAmount = _amountNeeded.sub(looseAmount);

			masterChef.withdraw(toExitAmount);

			_liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
			_loss = _amountNeeded.sub(_liquidatedAmount);

			enforceSlippageOut(toExitAmount, _liquidatedAmount.sub(looseAmount));
		} else {
			_liquidatedAmount = _amountNeeded;
		}
	}

	function liquidateAllPositions() internal override returns (uint256 _liquidated) {
		uint256 eta = estimatedTotalAssets();

		withdrawLpFromMasterChef(balanceOfLPInMasterChef());

		_liquidated = balanceOfWant();

		enforceSlippageOut(eta, _liquidated);
	}

	/**
	 * @notice
	 *  This withdraws Lp tokens and transfers them into newStrategy.
	 */
	function prepareMigration(address _newStrategy) internal override {
		_withdrawFromMasterChefAndTransfer(_newStrategy);
	}

	//-------------------------------//
	//      Internal Swap func       //
	//-------------------------------//

	/**
	 * @notice
	 *  Swaps THENA for BNB.
	 */
	function _sellRewards() internal {
		route[] memory thenaToWbnbRoute = new route[](1);
		thenaToWbnbRoute[0] = route(thenaReward, wbnb, false);

		uint256 thenaRewards = balanceOfReward();

		if (thenaRewards > rewardDust) {
			// THENA to BNB
			IThenaRouter(router).swapExactTokensForTokens(
				thenaRewards,
				1,
				thenaToWbnbRoute,
				address(this),
				block.timestamp
			);
		}
	}

	/**
	 * @notice
	 *  Swaps half of the BNB for token0 and token1 and adds liquidity.
	 */
	function _convertToLpToken() internal {
		route[] memory wbnbToToken0Route = new route[](1);
		wbnbToToken0Route[0] = route(wbnb, address(token0), false);

		route[] memory wbnbToToken1Route = new route[](1);
		wbnbToToken1Route[0] = route(wbnb, address(token1), false);

		uint256 wbnbBalance = IERC20(wbnb).balanceOf(address(this));

		if (wbnbBalance > 1e15) {
			// 1/2 BNB to token0
			IThenaRouter(router).swapExactTokensForTokens(
				wbnbBalance.div(2),
				1,
				wbnbToToken0Route,
				address(this),
				block.timestamp
			);

			// 1/2 BNB to token1
			IThenaRouter(router).swapExactTokensForTokens(
				wbnbBalance.div(2),
				1,
				wbnbToToken1Route,
				address(this),
				block.timestamp
			);
		}

		// Add liquidity to build the LpToken
		uint256 token0Balance = IERC20(token0).balanceOf(address(this));
		uint256 token1Balance = IERC20(token1).balanceOf(address(this));

		if (token0Balance > 0 && token1Balance > 0) {
			_addLiquidity(token0Balance, token1Balance);
		}
	}

	//-------------------------------//
	//    Internal Liquidity func    //
	//-------------------------------//

	/**
	 * @notice
	 *  Add liquidity to Thena
	 */
	function _addLiquidity(uint256 lp0Amount, uint256 lp1Amount) internal {
		IThenaRouter(router).addLiquidity(
			address(token0),
			address(token1),
			isStable,
			lp0Amount,
			lp1Amount,
			0,
			0,
			address(this),
			block.timestamp
		);
	}

	//--------------------------------//
	//    Internal MasterChef func    //
	//--------------------------------//

	/**
	 * @notice
	 *  Deposits all the LpTokens in masterChef.
	 */
	function depositLpIntoMasterChef() internal {
		uint256 balanceOfLpTokens = balanceOfWant();
		if (balanceOfLpTokens > 0) {
			masterChef.deposit(balanceOfLpTokens);
		}
	}

	/**
	 * @notice
	 *  Withdraws a certain amount from masterChef.
	 */
	function withdrawLpFromMasterChef(uint256 amount) internal {
		uint256 toWithdraw = Math.min(amount, balanceOfLPInMasterChef());
		if (toWithdraw > 0) {
			masterChef.withdraw(toWithdraw);
		}
	}

	/**
	 * @notice
	 *  Claim all THENA rewards from masterChef.
	 */
	function _claimRewards() internal {
		masterChef.getReward();
	}

	/**
	 * @notice
	 *  AbandonRewards withdraws lp without rewards.
	 * @dev
	 *  Specify where to withdraw to.
	 */
	function _withdrawFromMasterChefAndTransfer(address _to) internal {
		if (abandonRewards) {
			withdrawLpFromMasterChef(balanceOfLPInMasterChef());
		} else {
			_claimRewards();
			withdrawLpFromMasterChef(balanceOfLPInMasterChef());
			uint256 _thenaRewards = balanceOfReward();
			IERC20(thenaReward).safeTransfer(_to, _thenaRewards);
		}
		uint256 lpTokensBalance = balanceOfWant();
		if (lpTokensBalance > 0) {
			IERC20(address(thenaLp)).safeTransfer(_to, lpTokensBalance);
		}
	}

	/**
	 * @notice
	 *  Collects all the profit generated by the strategy since the last harvest.
	 *  This is used when we use tend to compound but we don't inform the vault of the profits.
	 */
	function _collectTradingFees() internal {
		uint256 total = estimatedTotalAssets();
		uint256 debt = vault.strategies(address(this)).totalDebt;

		if (total > debt) {
			uint256 profit = total.sub(debt);

			// Withdraw profit from masterChef
			withdrawLpFromMasterChef(profit);
		}
	}

	//-------------------------------//
	//     Internal Helpers func     //
	//-------------------------------//

	function _giveAllowances() internal {
		IERC20(address(thenaLp)).safeApprove(address(masterChef), 0);
		IERC20(address(thenaLp)).safeApprove(address(masterChef), MAX);

		IERC20(address(thenaLp)).safeApprove(router, 0);
		IERC20(address(thenaLp)).safeApprove(router, MAX);

		IERC20(thenaReward).safeApprove(router, 0);
		IERC20(thenaReward).safeApprove(router, MAX);

		IERC20(token0).safeApprove(router, 0);
		IERC20(token0).safeApprove(router, MAX);

		IERC20(token1).safeApprove(router, 0);
		IERC20(token1).safeApprove(router, MAX);
	}

	/**
	 * @notice
	 *  Revert if slippage out exceeds our requirement.
	 * @dev
	 *  Enforce that amount exited didn't slip beyond our tolerance.
	 *  Check for positive slippage, just in case.
	 */
	function enforceSlippageOut(uint256 _intended, uint256 _actual) internal view {
		uint256 exitSlipped = _intended > _actual ? _intended.sub(_actual) : 0;
		uint256 maxLoss = _intended.mul(maxSlippageOut).div(basisOne);
		require(exitSlipped <= maxLoss, "Slipped Out!");
	}

	/**
	 * @notice
	 *  Revert if slippage in exceeds our requirement.
	 * @dev
	 *  Enforce that amount exchange from want to LP tokens didn't slip beyond our tolerance.
	 *  Check for positive slippage, just in case.
	 */
	function enforceSlippageIn(uint256 _amountIn, uint256 _pooledBefore) internal view {
		uint256 pooledDelta = balanceOfLPInMasterChef().sub(_pooledBefore);
		uint256 joinSlipped = _amountIn > pooledDelta ? _amountIn.sub(pooledDelta) : 0;
		uint256 maxLoss = _amountIn.mul(maxSlippageIn).div(basisOne);
		require(joinSlipped <= maxLoss, "Slipped in!");
	}

	function protectedTokens() internal view override returns (address[] memory) {}

	//-----------------------------//
	//    Public Triggers func     //
	//-----------------------------//

	/**
	 * @notice
	 *  Use this to determine when to harvest.
	 */
	function harvestTrigger(uint256 callCostInWei) public view override returns (bool) {
		StrategyParams memory params = vault.strategies(address(this));

		// Should not trigger if strategy is not active (no assets and no debtRatio)
		if (!isActive()) return false;

		// Trigger if profit generated is higher than minProfit
		if (estimatedHarvest() > minProfit) return true;

		// Harvest no matter what once we reach our maxDelay
		if (block.timestamp.sub(params.lastReport) > maxReportDelay) return true;

		// Trigger if we want to manually harvest, but only if our gas price is acceptable
		if (forceHarvestTriggerOnce) return true;

		// Otherwise, we don't harvest
		return false;
	}

	function ethToWant(uint256 _amtInWei) public view override returns (uint256) {}

	function tendTrigger(uint256 callCostInWei) public view override returns (bool) {
		return balanceOfWant() > 0;
	}

	//-------------------------------//
	//    Protected Setters func     //
	//-------------------------------//

	function setMinProfit(uint256 _minAcceptableProfit) external onlyKeepers {
		minProfit = _minAcceptableProfit;
	}

	/**
	 * @notice
	 *  This allows us to manually harvest with our keeper as needed.
	 */
	function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyKeepers {
		forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
	}

	function setParams(uint256 _maxSlippageIn, uint256 _maxSlippageOut)
		public
		onlyVaultManagers
	{
		require(_maxSlippageIn <= basisOne);
		maxSlippageIn = _maxSlippageIn;

		require(_maxSlippageOut <= basisOne);
		maxSlippageOut = _maxSlippageOut;
	}

	function setDust(uint256 _dust, uint256 _rewardDust) external onlyVaultManagers {
		dust = _dust;
		rewardDust = _rewardDust;
	}

	function setCollectFeesEnabled(bool _collectFeesEnabled) external onlyVaultManagers {
		collectFeesEnabled = _collectFeesEnabled;
	}

	/**
	 * @notice
	 *  Manually returns lps in masterChef to the strategy. Used in emergencies.
	 */
	function emergencyWithdrawFromMasterChef() external onlyVaultManagers {
		withdrawLpFromMasterChef(balanceOfLPInMasterChef());
	}

	/**
	 * @notice
	 *  Toggle for whether to abandon rewards or not on emergency withdraws from masterChef.
	 */
	function setAbandonRewards(bool abandon) external onlyVaultManagers {
		abandonRewards = abandon;
	}

	receive() external payable {}
}
