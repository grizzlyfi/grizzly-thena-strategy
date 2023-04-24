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

	uint256 public maxSlippageIn; // bps
	uint256 public maxSlippageOut; // bps

	bool internal abandonRewards;

	bool internal immutable isStable;
	uint256 internal constant basisOne = 10000;
	uint256 internal constant MAX = type(uint256).max;

	uint256 public minProfit;
	bool internal forceHarvestTriggerOnce;

	address internal constant voterTHE = 0x981B04CBDCEE0C510D331fAdc7D6836a77085030; // We send some extra THE here
	uint256 public keepTHE; // Percentage of THE we re-lock for boost (in basis points)

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

		maxSlippageIn = 1;
		maxSlippageOut = 1;

		maxReportDelay = 30 days;
		minProfit = 1e21;

		keepTHE = 0;

		dust = 1e15;
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

		(uint256 profitInWbnb, ) =
			IThenaRouter(router).getAmountOut(thenaBalance, thenaReward, wbnb);

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
		// Claim THENA rewards
		_claimRewards();
		// Send some THENA to voter
		_sendToVoter();
		// Swap THENA for BUSD
		_sellRewards();
		// Swap BUSD for token0 & token1 and build the LP
		_convertToLpToken();

		uint256 assets = estimatedTotalAssets();
		uint256 wantBalance = balanceOfWant();
		uint256 debt = vault.strategies(address(this)).totalDebt;

		_debtPayment = _debtOutstanding;
		uint256 amountToFree = _debtPayment.add(_profit);

		if (assets >= debt) {
			_debtPayment = _debtOutstanding;
			_profit = assets.sub(debt);

			amountToFree = _profit.add(_debtPayment);

			if (amountToFree > 0 && wantBalance < amountToFree) {
				liquidatePosition(amountToFree);

				uint256 newLoose = balanceOfWant();

				// If we dont have enough money adjust _debtOutstanding and only change profit if needed
				if (newLoose < amountToFree) {
					if (_profit > newLoose) {
						_profit = newLoose;
						_debtPayment = 0;
					} else {
						_debtPayment = Math.min(newLoose.sub(_profit), _debtPayment);
					}
				}
			}
		} else {
			// Serious loss should never happen but if it does lets record it accurately
			_loss = debt.sub(assets);
		}

		// We're done harvesting, so reset our trigger if we used it
		forceHarvestTriggerOnce = false;
	}

	/**
	 * @notice
	 *  In simple autocompounding adjustPosition only deposits the LpTokens in masterChef.
	 */
	function adjustPosition(uint256 _debtOutstanding) internal override {
		// Lp assets before the operation
		uint256 pooledBefore = balanceOfLPInMasterChef();

		uint256 amountIn = balanceOfWant();
		if (amountIn > dust) {
			// Deposit all LpTokens in Thena masterChef
			_depositLpIntoMasterChef();
			_enforceSlippageIn(amountIn, pooledBefore);
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

			_withdrawLpFromMasterChef(toExitAmount);

			_liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
			_loss = _amountNeeded.sub(_liquidatedAmount);

			_enforceSlippageOut(toExitAmount, _liquidatedAmount.sub(looseAmount));
		} else {
			_liquidatedAmount = _amountNeeded;
		}
	}

	function liquidateAllPositions() internal override returns (uint256 _liquidated) {
		uint256 eta = estimatedTotalAssets();

		_withdrawLpFromMasterChef(balanceOfLPInMasterChef());

		_liquidated = balanceOfWant();

		_enforceSlippageOut(eta, _liquidated);
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
	 *  Swaps THENA for BUSD.
	 */
	function _sellRewards() internal {
		route[] memory thenaToBusdRoute = new route[](1);
		thenaToBusdRoute[0] = route(thenaReward, busd, false);

		uint256 thenaRewards = balanceOfReward();

		if (thenaRewards > rewardDust) {
			// THENA to BUSD
			IThenaRouter(router).swapExactTokensForTokens(
				thenaRewards,
				1,
				thenaToBusdRoute,
				address(this),
				block.timestamp
			);
		}
	}

	function _sendToVoter() internal {
		uint256 thenaBalance = balanceOfReward();
		uint256 sendToVoter = thenaBalance.mul(keepTHE).div(basisOne);

		if (sendToVoter > 0) {
			IERC20(thenaReward).safeTransfer(voterTHE, sendToVoter);
		}
	}

	/**
	 * @notice
	 *  Swaps half of the busd for token0 and token1 and adds liquidity.
	 */
	function _convertToLpToken() internal {
		route[] memory busdToToken0Route = new route[](1);
		busdToToken0Route[0] = route(busd, address(token0), true);

		route[] memory busdToToken1Route = new route[](1);
		busdToToken1Route[0] = route(busd, address(token1), true);

		uint256 busdBalance = IERC20(busd).balanceOf(address(this));

		if (busdBalance > 1e18) {
			// If token0 or token1 is busd we skip the swap
			if (address(token0) != busd) {
				// 1/2 busd to token0
				IThenaRouter(router).swapExactTokensForTokens(
					busdBalance.div(2),
					1,
					busdToToken0Route,
					address(this),
					block.timestamp
				);
			}
			if (address(token1) != busd) {
				// 1/2 busd to token1
				IThenaRouter(router).swapExactTokensForTokens(
					busdBalance.div(2),
					1,
					busdToToken1Route,
					address(this),
					block.timestamp
				);
			}
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
	 *  Add liquidity to Thena.
	 */
	function _addLiquidity(uint256 token0Amount, uint256 token1Amount) internal {
		IThenaRouter(router).addLiquidity(
			address(token0),
			address(token1),
			isStable,
			token0Amount,
			token1Amount,
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
	function _depositLpIntoMasterChef() internal {
		uint256 balanceOfLpTokens = balanceOfWant();
		if (balanceOfLpTokens > 0) {
			masterChef.deposit(balanceOfLpTokens);
		}
	}

	/**
	 * @notice
	 *  Withdraws a certain amount from masterChef.
	 */
	function _withdrawLpFromMasterChef(uint256 amount) internal {
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
	 *  Specify where to withdraw to. Migrate function already has safeTransfer of want.
	 */
	function _withdrawFromMasterChefAndTransfer(address _to) internal {
		if (abandonRewards) {
			_withdrawLpFromMasterChef(balanceOfLPInMasterChef());
		} else {
			_claimRewards();
			_withdrawLpFromMasterChef(balanceOfLPInMasterChef());
			IERC20(thenaReward).safeTransfer(_to, balanceOfReward());
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

		IERC20(busd).safeApprove(router, 0);
		IERC20(busd).safeApprove(router, MAX);

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
	function _enforceSlippageOut(uint256 _intended, uint256 _actual) internal view {
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
	function _enforceSlippageIn(uint256 _amountIn, uint256 _pooledBefore) internal view {
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
		external
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

	function setKeep(uint256 _keepTHE) external onlyVaultManagers {
		require(_keepTHE <= 10_000, "Wrong input");
		keepTHE = _keepTHE;
	}

	/**
	 * @notice
	 *  Manually returns lps in masterChef to the strategy. Used in emergencies.
	 */
	function emergencyWithdrawFromMasterChef() external onlyVaultManagers {
		_withdrawLpFromMasterChef(balanceOfLPInMasterChef());
	}

	/**
	 * @notice
	 *  Manually returns lps in masterChef to the strategy when Thena masterchef is in emergency mode.
	 */
	function emergencyWithdrawFromMasterChefInEmergencyMode() external onlyVaultManagers {
		masterChef.emergencyWithdraw();
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

