// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";

import "./interfaces/IStore.sol";
import "./interfaces/ICLP.sol";

contract Store is IStore {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // constants
    uint256 public constant BPS_DIVIDER = 10000;
    uint256 public constant MAX_FEE = 500; // in bps = 5%
    uint256 public constant MAX_KEEPER_FEE_SHARE = 2000; // in bps = 20%
    uint256 public constant MAX_POOL_WITHDRAWAL_FEE = 500; // in bps = 5%
    uint256 public constant FUNDING_INTERVAL = 1 hours; // In seconds.

    // contracts
    address public gov;
    address public currency;
    address public clp;

    address public swapRouter;
    address public quoter;
    address public weth;

    address public trade;
    address public pool;

    // Variables
    uint256 public poolFeeShare = 5000; // in bps
    uint256 public keeperFeeShare = 1000; // in bps
    uint256 public poolWithdrawalFee = 10; // in bps
    uint256 public minimumMarginLevel = 2000; // 20% in bps, at which account is liquidated

    uint256 public bufferBalance;
    uint256 public poolBalance;
    uint256 public poolLastPaid;

    uint256 public bufferPayoutPeriod = 7 days;

    uint256 internal orderId;

    mapping(uint256 => Order) private orders;
    mapping(address => EnumerableSet.UintSet) private userOrderIds; // user => [order ids..]
    EnumerableSet.UintSet private orderIds; // [order ids..]

    string[] public marketList; // "ETH-USD", "BTC-USD", etc
    mapping(string => Market) private markets;

    mapping(bytes32 => Position) private positions; // key = user,market
    EnumerableSet.Bytes32Set private positionKeys; // [position keys..]
    mapping(address => EnumerableSet.Bytes32Set) private positionKeysForUser; // user => [position keys..]

    mapping(string => uint256) private OILong;
    mapping(string => uint256) private OIShort;

    mapping(address => uint256) private balances; // user => amount
    mapping(address => uint256) private lockedMargins; // user => amount
    EnumerableSet.AddressSet private usersWithLockedMargin; // [users...]

    // Funding
    mapping(string => int256) private fundingTrackers; // market => funding tracker (long) (short is opposite) // in UNIT * bps
    mapping(string => uint256) private fundingLastUpdated; // market => last time fundingTracker was updated. In seconds.

    // Modifiers

    modifier onlyContract() {
        require(msg.sender == trade || msg.sender == pool, "!contract");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "!governance");
        _;
    }

    constructor(address _gov) {
        gov = _gov;
    }

    // Gov methods

    function updateGov(address _gov) external onlyGov {
        require(_gov != address(0), "!address");

        address oldGov = gov;
        gov = _gov;

        emit GovernanceUpdated(oldGov, _gov);
    }

    function link(address _trade, address _pool, address _currency, address _clp) external onlyGov {
        trade = _trade;
        pool = _pool;
        currency = _currency;
        clp = _clp;
    }

    function linkUniswap(address _swapRouter, address _quoter, address _weth) external onlyGov {
        swapRouter = _swapRouter;
        quoter = _quoter;
        weth = _weth; // _weth = WMATIC on Polygon
    }

    function setPoolFeeShare(uint256 amount) external onlyGov {
        poolFeeShare = amount;
    }

    function setKeeperFeeShare(uint256 amount) external onlyGov {
        require(amount <= MAX_KEEPER_FEE_SHARE, "!max-keeper-fee-share");
        keeperFeeShare = amount;
    }

    function setPoolWithdrawalFee(uint256 amount) external onlyGov {
        require(amount <= MAX_POOL_WITHDRAWAL_FEE, "!max-pool-withdrawal-fee");
        poolWithdrawalFee = amount;
    }

    function setMinimumMarginLevel(uint256 amount) external onlyGov {
        minimumMarginLevel = amount;
    }

    function setBufferPayoutPeriod(uint256 amount) external onlyGov {
        bufferPayoutPeriod = amount;
    }

    function setMarket(string calldata market, Market calldata marketInfo) external onlyGov {
        require(marketInfo.fee <= MAX_FEE, "!max-fee");
        markets[market] = marketInfo;
        for (uint256 i = 0; i < marketList.length; i++) {
            if (keccak256(abi.encodePacked(marketList[i])) == keccak256(abi.encodePacked(market))) return;
        }
        marketList.push(market);
    }

    // Methods

    function transferIn(address user, uint256 amount) external onlyContract {
        IERC20(currency).safeTransferFrom(user, address(this), amount);
    }

    function transferOut(address user, uint256 amount) external onlyContract {
        IERC20(currency).safeTransfer(user, amount);
    }

    // CLP methods
    function mintCLP(address user, uint256 amount) external onlyContract {
        ICLP(clp).mint(user, amount);
    }

    function burnCLP(address user, uint256 amount) external onlyContract {
        ICLP(clp).burn(user, amount);
    }

    function getCLPSupply() external view returns (uint256) {
        return IERC20(clp).totalSupply();
    }

    // Uniswap methods
    function swapExactInputSingle(address user, uint256 amountIn, uint256 amountOutMin, address tokenIn, uint24 poolFee)
        external
        payable
        onlyContract
        returns (uint256 amountOut)
    {
        require(address(swapRouter) != address(0), "!swapRouter");

        if (msg.value != 0) {
            // there are no direct ETH pairs in Uniswapv3, so router converts ETH to WETH before swap
            tokenIn = weth;
            amountIn = msg.value;
        } else {
            // transfer token to be swapped
            IERC20(tokenIn).safeTransferFrom(user, address(this), amountIn);
            IERC20(tokenIn).safeApprove(address(swapRouter), amountIn);
        }

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: currency, // store supported currency
            fee: poolFee,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: amountIn,
            amountOutMinimum: amountOutMin, // swap reverts if amountOut < amountOutMin
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        amountOut = ISwapRouter(swapRouter).exactInputSingle{value: msg.value}(params);
    }

    // Function is not marked as view because it relies on calling non-view functions
    // Not gas efficient so shouldnt be called on-chain
    function getEstimatedOutputTokens(uint256 amountIn, address tokenIn, uint24 poolFee)
        external
        returns (uint256 amountOut)
    {
        return IQuoter(quoter).quoteExactInputSingle(tokenIn, currency, poolFee, amountIn, 0);
    }

    // User balance
    function incrementBalance(address user, uint256 amount) external onlyContract {
        balances[user] += amount;
    }

    function decrementBalance(address user, uint256 amount) external onlyContract {
        require(amount <= balances[user], "!balance");
        balances[user] -= amount;
    }

    function getBalance(address user) external view returns (uint256) {
        return balances[user];
    }

    // Pool
    function incrementPoolBalance(uint256 amount) external onlyContract {
        poolBalance += amount;
    }

    function decrementPoolBalance(uint256 amount) external onlyContract {
        poolBalance -= amount;
    }

    function setPoolLastPaid(uint256 timestamp) external onlyContract {
        poolLastPaid = timestamp;
    }

    function getUserPoolBalance(address user) external view returns (uint256) {
        uint256 clpSupply = IERC20(clp).totalSupply();
        if (clpSupply == 0) return 0;
        return IERC20(clp).balanceOf(user) * poolBalance / clpSupply;
    }

    // Buffer
    function incrementBufferBalance(uint256 amount) external onlyContract {
        bufferBalance += amount;
    }

    function decrementBufferBalance(uint256 amount) external onlyContract {
        bufferBalance -= amount;
    }

    // Margin
    function lockMargin(address user, uint256 amount) external onlyContract {
        lockedMargins[user] += amount;
        usersWithLockedMargin.add(user);
    }

    function unlockMargin(address user, uint256 amount) external onlyContract {
        if (amount > lockedMargins[user]) {
            lockedMargins[user] = 0;
        } else {
            lockedMargins[user] -= amount;
        }
        if (lockedMargins[user] == 0) {
            usersWithLockedMargin.remove(user);
        }
    }

    function getLockedMargin(address user) external view returns (uint256) {
        return lockedMargins[user];
    }

    function getUsersWithLockedMarginLength() external view returns (uint256) {
        return usersWithLockedMargin.length();
    }

    function getUserWithLockedMargin(uint256 i) external view returns (address) {
        return usersWithLockedMargin.at(i);
    }

    // Open interest
    function incrementOI(string calldata market, uint256 size, bool isLong) external onlyContract {
        if (isLong) {
            OILong[market] += size;
            require(markets[market].maxOI >= OILong[market], "!max-oi");
        } else {
            OIShort[market] += size;
            require(markets[market].maxOI >= OIShort[market], "!max-oi");
        }
    }

    function decrementOI(string calldata market, uint256 size, bool isLong) external onlyContract {
        if (isLong) {
            if (size > OILong[market]) {
                OILong[market] = 0;
            } else {
                OILong[market] -= size;
            }
        } else {
            if (size > OIShort[market]) {
                OIShort[market] = 0;
            } else {
                OIShort[market] -= size;
            }
        }
    }

    function getOILong(string calldata market) external view returns (uint256) {
        return OILong[market];
    }

    function getOIShort(string calldata market) external view returns (uint256) {
        return OIShort[market];
    }

    // Orders
    function addOrder(Order memory order) external onlyContract returns (uint256) {
        uint256 nextOrderId = ++orderId;
        order.orderId = uint72(nextOrderId);
        orders[nextOrderId] = order;
        userOrderIds[order.user].add(nextOrderId);
        orderIds.add(nextOrderId);
        return nextOrderId;
    }

    function updateOrder(Order calldata order) external onlyContract {
        orders[order.orderId] = order;
    }

    function removeOrder(uint256 _orderId) external onlyContract {
        Order memory order = orders[_orderId];
        if (order.size == 0) return;
        userOrderIds[order.user].remove(_orderId);
        orderIds.remove(_orderId);
        delete orders[_orderId];
    }

    function getOrder(uint256 id) external view returns (Order memory _order) {
        return orders[id];
    }

    function getOrders() external view returns (Order[] memory _orders) {
        uint256 length = orderIds.length();
        _orders = new Order[](length);
        for (uint256 i = 0; i < length; i++) {
            _orders[i] = orders[orderIds.at(i)];
        }
        return _orders;
    }

    function getUserOrders(address user) external view returns (Order[] memory _orders) {
        uint256 length = userOrderIds[user].length();
        _orders = new Order[](length);
        for (uint256 i = 0; i < length; i++) {
            _orders[i] = orders[userOrderIds[user].at(i)];
        }
        return _orders;
    }

    // Positions
    function addOrUpdatePosition(Position calldata position) external onlyContract {
        bytes32 key = _getPositionKey(position.user, position.market);
        positions[key] = position;
        positionKeysForUser[position.user].add(key);
        positionKeys.add(key);
    }

    function removePosition(address user, string calldata market) external onlyContract {
        bytes32 key = _getPositionKey(user, market);
        positionKeysForUser[user].remove(key);
        positionKeys.remove(key);
        delete positions[key];
    }

    function getUserPositions(address user) external view returns (Position[] memory _positions) {
        uint256 length = positionKeysForUser[user].length();
        _positions = new Position[](length);
        for (uint256 i = 0; i < length; i++) {
            _positions[i] = positions[positionKeysForUser[user].at(i)];
        }
        return _positions;
    }

    function getPosition(address user, string calldata market) public view returns (Position memory position) {
        bytes32 key = _getPositionKey(user, market);
        return positions[key];
    }

    function _getPositionKey(address user, string calldata market) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, market));
    }

    // Markets
    function getMarket(string calldata market) external view returns (Market memory _market) {
        return markets[market];
    }

    function getMarketList() external view returns (string[] memory) {
        return marketList;
    }

    // Funding
    function setFundingLastUpdated(string calldata market, uint256 timestamp) external onlyContract {
        fundingLastUpdated[market] = timestamp;
    }

    function updateFundingTracker(string calldata market, int256 fundingIncrement) external onlyContract {
        fundingTrackers[market] += fundingIncrement;
    }

    function getFundingLastUpdated(string calldata market) external view returns (uint256) {
        return fundingLastUpdated[market];
    }

    function getFundingFactor(string calldata market) external view returns (uint256) {
        return markets[market].fundingFactor;
    }

    function getFundingTracker(string calldata market) external view returns (int256) {
        return fundingTrackers[market];
    }
}
