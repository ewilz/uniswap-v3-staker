// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Staker.sol';
import './libraries/IncentiveHelper.sol';

import '@uniswap/v3-core/contracts/libraries/FixedPoint96.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-core/contracts/libraries/FullMath.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

import '@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

/**
@title Uniswap V3 canonical staking interface
*/
contract UniswapV3Staker is IUniswapV3Staker, IERC721Receiver, Multicall {
    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @dev bytes32 refers to the return value of IncentiveHelper.getIncentiveId
    mapping(bytes32 => Incentive) public incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public deposits;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) public stakes;

    /// @dev rewards[rewardToken][msg.sender] => uint256
    mapping(address => mapping(address => uint256)) public rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    constructor(address _factory, address _nonfungiblePositionManager) {
        factory = IUniswapV3Factory(_factory);
        nonfungiblePositionManager = INonfungiblePositionManager(
            _nonfungiblePositionManager
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function createIncentive(CreateIncentiveParams memory params)
        external
        override
    {
        require(
            params.startTime < params.endTime &&
                params.endTime < params.claimDeadline &&
                block.timestamp < params.startTime,
            'timestamps invalid'
        );

        require(
            params.rewardToken != address(0) && params.totalReward > 0,
            'reward invalid'
        );

        bytes32 key =
            IncentiveHelper.getIncentiveId(
                msg.sender,
                params.rewardToken,
                params.pool,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        require(incentives[key].rewardToken == address(0), 'incentive exists');

        TransferHelper.safeTransferFrom(
            params.rewardToken,
            msg.sender,
            address(this),
            params.totalReward
        );

        incentives[key] = Incentive(params.totalReward, 0, params.rewardToken);

        emit IncentiveCreated(
            msg.sender,
            params.rewardToken,
            params.pool,
            params.startTime,
            params.endTime,
            params.claimDeadline,
            params.totalReward
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function endIncentive(EndIncentiveParams memory params) external override {
        require(
            params.claimDeadline <= block.timestamp,
            'before claim deadline'
        );
        bytes32 key =
            IncentiveHelper.getIncentiveId(
                params.creator,
                params.rewardToken,
                params.pool,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        Incentive memory incentive = incentives[key];
        require(incentive.rewardToken != address(0), 'invalid incentive');
        delete incentives[key];

        TransferHelper.safeTransfer(
            params.rewardToken,
            params.creator,
            incentive.totalRewardUnclaimed
        );

        emit IncentiveEnded(
            params.creator,
            params.rewardToken,
            params.pool,
            params.startTime,
            params.endTime,
            params.claimDeadline
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function depositToken(uint256 tokenId) external override {
        nonfungiblePositionManager.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId
        );
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'not a univ3 nft'
        );

        deposits[tokenId] = Deposit(from, 0);
        emit TokenDeposited(tokenId, from);

        if (data.length > 0) {
            _stakeToken(abi.decode(data, (UpdateStakeParams)));
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(uint256 tokenId, address to) external override {
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'nonzero num of stakes');
        require(deposit.owner == msg.sender, 'sender is not nft owner');

        delete deposits[tokenId];
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId);
        emit TokenWithdrawn(tokenId, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(UpdateStakeParams memory params) external override {
        require(
            deposits[params.tokenId].owner == msg.sender,
            'sender is not nft owner'
        );

        _stakeToken(params);
    }

    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(UpdateStakeParams memory params) external override {
        require(
            deposits[params.tokenId].owner == msg.sender,
            'sender is not nft owner'
        );

        deposits[params.tokenId].numberOfStakes -= 1;
        (address poolAddress, int24 tickLower, int24 tickUpper, ) =
            _getPositionDetails(params.tokenId);

        bytes32 incentiveId =
            IncentiveHelper.getIncentiveId(
                params.creator,
                params.rewardToken,
                poolAddress,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        Incentive memory incentive = incentives[incentiveId];
        Stake memory stake = stakes[params.tokenId][incentiveId];

        require(stake.exists == true, 'nonexistent stake');

        // if incentive still exists
        if (incentive.totalRewardUnclaimed > 0) {
            (uint128 reward, uint160 secondsInPeriodX128, ) =
                _getRewardAmount(
                    stake,
                    incentive,
                    params,
                    poolAddress,
                    tickLower,
                    tickUpper
                );

            incentives[incentiveId]
                .totalSecondsClaimedX128 += secondsInPeriodX128;

            // TODO: is SafeMath necessary here? Could we do just a subtraction?
            incentives[incentiveId].totalRewardUnclaimed = uint128(
                SafeMath.sub(incentive.totalRewardUnclaimed, reward)
            );

            // Makes rewards available to claimReward
            rewards[incentive.rewardToken][msg.sender] = SafeMath.add(
                rewards[incentive.rewardToken][msg.sender],
                reward
            );
        }

        delete stakes[params.tokenId][incentiveId];
        emit TokenUnstaked(params.tokenId, incentiveId);
    }

    function getRewardAmount(UpdateStakeParams memory params)
        public
        view
        returns (uint128 reward)
    {
        (address poolAddress, int24 tickLower, int24 tickUpper, ) =
            _getPositionDetails(params.tokenId);

        bytes32 incentiveId =
            IncentiveHelper.getIncentiveId(
                params.creator,
                params.rewardToken,
                poolAddress,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        Incentive memory incentive = incentives[incentiveId];
        Stake memory stake = stakes[params.tokenId][incentiveId];
        (reward, , ) = _getRewardAmount(
            stake,
            incentive,
            params,
            poolAddress,
            tickLower,
            tickUpper
        );
    }

    function updateStake(
        UpdateStakeParams memory params
    ) external {
        require(
            deposits[params.tokenId].owner == msg.sender,
            'sender is not nft owner'
        );
        require(
            block.timestamp < params.endTime,
            'incentive has ended'
        );

        (address poolAddress, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            _getPositionDetails(params.tokenId);

        bytes32 incentiveId =
            IncentiveHelper.getIncentiveId(
                params.creator,
                params.rewardToken,
                poolAddress,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        Incentive memory incentive = incentives[incentiveId];
        Stake memory stake = stakes[params.tokenId][incentiveId];

        require(stake.exists == true, 'nonexistent stake');

        (
            uint128 reward,
            uint160 secondsInPeriodX128,
            uint160 secondsPerLiquidityInsideX128
        ) =
            _getRewardAmount(
                stake,
                incentive,
                params,
                poolAddress,
                tickLower,
                tickUpper
            );

        incentives[incentiveId].totalSecondsClaimedX128 += secondsInPeriodX128;

        // TODO: is SafeMath necessary here? Could we do just a subtraction?
        incentives[incentiveId].totalRewardUnclaimed = uint128(
            SafeMath.sub(incentive.totalRewardUnclaimed, reward)
        );
        stakes[params.tokenId][incentiveId].secondsPerLiquidityInitialX128 =
            secondsPerLiquidityInsideX128 +
            1;
        stakes[params.tokenId][incentiveId].liquidity = liquidity;
        rewards[incentive.rewardToken][msg.sender] = uint128(
            SafeMath.add(rewards[incentive.rewardToken][msg.sender], reward)
        );
        emit StakeUpdated(reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(address rewardToken, address to) external override {
        uint256 reward = rewards[rewardToken][msg.sender];
        rewards[rewardToken][msg.sender] = 0;

        TransferHelper.safeTransfer(rewardToken, to, reward);

        emit RewardClaimed(to, reward);
    }

    function _stakeToken(UpdateStakeParams memory params) internal {
        require(params.startTime <= block.timestamp, 'incentive not started');
        require(block.timestamp < params.endTime, 'incentive ended');

        (
            address poolAddress,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity
        ) = _getPositionDetails(params.tokenId);

        bytes32 incentiveId =
            IncentiveHelper.getIncentiveId(
                params.creator,
                params.rewardToken,
                poolAddress,
                params.startTime,
                params.endTime,
                params.claimDeadline
            );

        require(
            incentives[incentiveId].rewardToken != address(0),
            'non-existent incentive'
        );
        require(
            stakes[params.tokenId][incentiveId].exists != true,
            'incentive already staked'
        );

        (, uint160 secondsPerLiquidityInsideX128, ) =
            IUniswapV3Pool(poolAddress).snapshotCumulativesInside(
                tickLower,
                tickUpper
            );

        stakes[params.tokenId][incentiveId] = Stake(
            secondsPerLiquidityInsideX128,
            liquidity,
            true
        );

        deposits[params.tokenId].numberOfStakes += 1;
        emit TokenStaked(params.tokenId, liquidity, incentiveId);
    }

    function _getRewardAmount(
        Stake memory stake,
        Incentive memory incentive,
        UpdateStakeParams memory params,
        address poolAddress,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (
            uint128 reward,
            uint160 secondsInPeriodX128,
            uint160 secondsPerLiquidityInsideX128
        )
    {
        (, secondsPerLiquidityInsideX128, ) = IUniswapV3Pool(poolAddress)
            .snapshotCumulativesInside(tickLower, tickUpper);

        secondsInPeriodX128 = uint160(
            SafeMath.mul(
                secondsPerLiquidityInsideX128 -
                    stake.secondsPerLiquidityInitialX128,
                stake.liquidity
            )
        );

        // TODO: double-check for overflow risk here
        uint160 totalSecondsUnclaimedX128 =
            uint160(
                SafeMath.mul(
                    Math.max(params.endTime, block.timestamp) -
                        params.startTime,
                    FixedPoint128.Q128
                ) - incentive.totalSecondsClaimedX128
            );

        // TODO: Make sure this truncates and not rounds up
        uint256 rewardRate =
            FullMath.mulDiv(
                incentive.totalRewardUnclaimed,
                FixedPoint128.Q128,
                totalSecondsUnclaimedX128
            );

        // TODO: make sure casting is ok here
        reward = uint128(
            FullMath.mulDiv(secondsInPeriodX128, rewardRate, FixedPoint128.Q128)
        );
    }

    /// @param tokenId The unique identifier of an Uniswap V3 LP token
    /// @return pool The address of the Uniswap V3 pool
    /// @return tickLower The lower tick of the Uniswap V3 position
    /// @return tickUpper The upper tick of the Uniswap V3 position
    /// @return liquidity The amount of liquidity staked
    function _getPositionDetails(uint256 tokenId)
        internal
        view
        returns (
            address,
            int24,
            int24,
            uint128
        )
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(tokenId);

        PoolAddress.PoolKey memory poolKey =
            PoolAddress.getPoolKey(token0, token1, fee);

        // Could do this via factory.getPool or locally via PoolAddress.
        // TODO: what happens if this is null
        return (
            PoolAddress.computeAddress(address(factory), poolKey),
            tickLower,
            tickUpper,
            liquidity
        );
    }
}
