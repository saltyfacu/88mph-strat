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
import "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IRewards.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    bool internal isOriginal = true;
    
    // Path for swaps
    address[] private path;

    // 88MPH contracts
    IRewards public mph88Rewards = IRewards(0x98df8D9E56b51e4Ea8AA9b57F8A5Df7A044234e1);
    
    // Tokens
    IERC20 internal constant weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 internal constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    IUniswapV2Router public constant uniswapRouter = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;

        // Approve rewards contract to spend infinite tokens
        want.safeApprove(address(mph88Rewards), type(uint256).max);

        // Approve uniswap to spend infinite DAI
        dai.safeApprove(address(uniswapRouter), type(uint256).max);

        // Path from DAI to want (MPH)
        path = new address[](3);
        path[0] = address(dai);
        path[1] = address(weth);
        path[2] = address(want);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        return "Strategy88MPHStake";
    }

    function balanceStaked() public view returns (uint256) {
        return mph88Rewards.balanceOf(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function pendingRewards() public view returns (uint256) {
        return mph88Rewards.earned(address(this)); // In DAI
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceStaked());
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
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        // Let's get the rewards in DAI and swap them for MPH
        mph88Rewards.getReward();
        sellDai();

        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (assets > debt) {
            _profit = balanceOfWant();
        } else {
            _loss = debt.sub(assets);
        }

        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }

    }

    function sellDai() internal {
        uint256 daiBalance = dai.balanceOf(address(this));

        if (daiBalance == 0 ) {
            return;
        }

        uniswapRouter.swapExactTokensForTokens(
            daiBalance,
            uint256(0),
            path,
            address(this),
            now
        );
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        if (_debtOutstanding >= balanceOfWant()) {
            return;
        }
        
        uint256 toStake = balanceOfWant().sub(_debtOutstanding);

        if (toStake > 0) {
            mph88Rewards.stake(toStake);
        }

    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 balanceStakedNow = balanceStaked();

        if (_amountNeeded > balanceOfWant()) {
            mph88Rewards.withdraw((Math.min(balanceStakedNow, _amountNeeded - balanceOfWant())));
        }

        uint256 totalAssets = estimatedTotalAssets();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 balanceStakedNow = balanceStaked();
        
        if ( balanceStakedNow > 0) {
            liquidatePosition(balanceStakedNow);
        }

        return balanceOfWant();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        uint256 balanceOfDai = dai.balanceOf(address(this));

        // claim rewards and withdraw staked balance
        mph88Rewards.exit();

        // if there's some DAI left here for some reason, transfer to new strat
        if (balanceOfDai > 0 ) {
            dai.transfer(_newStrategy, balanceOfDai);
        }

    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }
}
