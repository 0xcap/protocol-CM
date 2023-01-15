//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./utils/TestUtils.sol";

contract TradeTest is TestUtils {
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(user);
    }

    function testSubmitOrderMaxSize() public {
        IStore.Market memory market = store.getMarket("ETH-USD");

        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit ETH long with size = amount
        ethLong.size = INITIAL_TRADE_DEPOSIT * market.maxLeverage;
        trade.submitOrder(ethLong, 0, 0);

        IStore.Order[] memory _orders = store.getOrders();

        assertEq(_orders.length, 1, "!orderLength");

        // taking order fees into account, equity is now below lockedMargin
        // submitting new orders shouldnt be possible
        vm.expectRevert("!equity");
        trade.submitOrder(btcLong, 0, 0);
    }

    function testOrderAndPositionStorage() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit ETH long with stop loss 2% below entry
        trade.submitOrder(ethLong, 0, ETH_PRICE * 98 / 100);

        // console.log orders and positions? true = yes, false = no
        bool flag = false;

        // should be two orders: ETH long and SL
        assertEq(_printOrders(flag), 2, "!orderCount");
        assertEq(_printUserPositions(user, flag), 0, "!positionCount");

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // should be one SL order and one long position
        assertEq(_printOrders(flag), 1, "!orderCount");
        assertEq(_printUserPositions(user, flag), 1, "!positionCount");

        // set ETH price to SL price and execute SL order
        chainlink.setPrice(ethFeed, ETH_PRICE * 98 / 100);
        trade.executeOrders();

        // should be zero orders, zero positions
        assertEq(_printOrders(flag), 0, "!orderCount");
        assertEq(_printUserPositions(user, flag), 0, "!positionCount");
    }

    function testExceedFreeMargin() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit first order, order.size = 100k, leverage = 50 -> margin 2k
        trade.submitOrder(ethLong, 0, 0);
        assertEq(2000 * CURRENCY_UNIT, store.getLockedMargin(user), "!lockedMargin");

        // submit second order, order.size = 100k, leverage = 50 -> margin 2k
        trade.submitOrder(btcLong, 0, 0);
        assertEq(4000 * CURRENCY_UNIT, store.getLockedMargin(user), "!lockedMargin");

        // balance should be initial deposit - fee (4800 USDC)
        uint256 fee = _getOrderFee("ETH-USD", ethLong.size) + _getOrderFee("BTC-USD", btcLong.size);
        assertEq(INITIAL_TRADE_DEPOSIT - fee, store.getBalance(user), "!balance");

        // at this point, lockedMargin = 4000 USDC and balance = 4800 USDC
        // freeMargin = balance - lockedMargin = 800 USDC

        // submit third order, order.size = 100k, leverage = 50 -> margin 2k
        trade.submitOrder(ethLong, 0, 0);

        Store.Order[] memory _orders = store.getUserOrders(user);

        // since freeMargin = 800, contract should have set margin of newest position to 800 USDC
        assertEq(_orders[2].margin, 800 * CURRENCY_UNIT, "!orderMargin");

        // order.size should be order.margin * market.maxLeverage
        IStore.Market memory _market = store.getMarket("ETH-USD");
        assertEq(_orders[2].size, _orders[2].margin * _market.maxLeverage, "!orderSize");

        // taking order fees into account, equity is now below lockedMargin
        // submitting new orders shouldnt be possible
        vm.expectRevert("!equity");
        trade.submitOrder(ethLong, 0, 0);
    }

    function testWithdraw() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // withdraw half
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, INITIAL_TRADE_DEPOSIT / 2);
        trade.withdraw(INITIAL_TRADE_DEPOSIT / 2);

        // trade balance should be half of initial balance
        assertEq(store.getBalance(user), INITIAL_TRADE_DEPOSIT / 2);
    }

    function testWithdrawOverMaxBalance() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // user withdraws more than deposited -> should receive deposited amount
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, INITIAL_TRADE_DEPOSIT);
        trade.withdraw(MAX_UINT256);

        // balance should be zero
        assertEq(store.getBalance(user), 0);
    }

    function testWithdrawOverMaxBalancePositiveUPL() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit order, order.size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        vm.stopPrank();
        skip(2 minutes);
        trade.executeOrders();
        vm.startPrank(user);

        // balance is now initial deposit - orderFee
        uint256 fee = _getOrderFee("ETH-USD", ethLong.size);

        // set ETH price to ETH_TP_PRICE -> trade is 2k in profit (same as locked margin)
        // if condition (int256(balance - amount) + upl < int256(lockedMargin)) returns zero
        chainlink.setPrice(ethFeed, ETH_TP_PRICE);

        // user should receive initial balance - fee
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, INITIAL_TRADE_DEPOSIT - fee);
        trade.withdraw(MAX_UINT256);

        // balance should be zero
        assertEq(store.getBalance(user), 0);
    }

    function testWithdrawOverMaxBalanceNegativeUPL() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit order, order.size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        vm.stopPrank();
        skip(2 minutes);
        trade.executeOrders();
        vm.startPrank(user);

        // set ETH price to ETH_SL_PRICE -> trade is 2k in loss
        // if condition (int256(balance - amount) + upl < int256(lockedMargin)) returns true
        chainlink.setPrice(ethFeed, ETH_SL_PRICE);

        // user should receive initial balance - lockedMargin - UPL - fee = 5k - 2k - 2k - 100 = 900 USDC
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, 900 * CURRENCY_UNIT);
        trade.withdraw(MAX_UINT256);

        // balance should be initial deposit - withdrawn amount - fee = 4000 USDC
        assertEq(store.getBalance(user), 4000 * CURRENCY_UNIT);
    }

    function testRevertWithdraw() public {
        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit order, order.size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        vm.stopPrank();
        skip(2 minutes);
        trade.executeOrders();
        vm.startPrank(user);

        // upl ~ -100k
        chainlink.setPrice(ethFeed, 1);

        // user shouldnt be able to withdraw (withdrawable amount is zero)
        vm.expectRevert("!amount > 0");
        trade.withdraw(MAX_UINT256);
    }

    function testRevertOrderType() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        ethLongLimit.price = 6000 * UNIT;

        // orderType == 1 && isLong == true && chainLinkPrice <= order.price, should revert
        vm.expectRevert("!orderType");
        trade.submitOrder(ethLongLimit, 0, 0);
    }

    function testUpdateOrder() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        trade.submitOrder(ethLongLimit, 0, 0);

        // update order
        trade.updateOrder(1, 6000 * UNIT);
        IStore.Order[] memory _orders = store.getOrders();

        // order type from 1 => 2
        assertEq(_orders[0].orderType, 2);
        // price should be 6000
        assertEq(_orders[0].price, 6000 * UNIT);
    }

    function testRevertUpdateOrder() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit ETH market long
        trade.submitOrder(ethLong, 0, 0);
        vm.expectRevert("!market-order");
        trade.updateOrder(1, 5000);
    }

    function testCancelOrder() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        trade.submitOrder(ethLongLimit, 0, 0);
        trade.cancelOrder(1);

        assertEq(store.getLockedMargin(user), 0);

        // fee should be credited back to user
        assertEq(store.getBalance(user), INITIAL_TRADE_DEPOSIT);
    }

    function testExecutableOrderIds() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit three orders:
        // 1. eth long, is executable
        // 2. take profit 2% above entry
        // 3. stop loss at 2% below entry
        trade.submitOrder(ethLong, ETH_PRICE * 102 / 100, ETH_PRICE * 98 / 100);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);

        uint256[] memory orderIdsToExecute = trade.getExecutableOrderIds();
        assertEq(orderIdsToExecute[0], 1);
        assertEq(orderIdsToExecute.length, 1);

        // set chainlinkprice above TP price
        chainlink.setPrice(ethFeed, ETH_PRICE * 102 / 100 + 1 * UNIT);
        orderIdsToExecute = trade.getExecutableOrderIds();

        // initial long order and TP order should be executable
        assertEq(orderIdsToExecute[0], 1);
        assertEq(orderIdsToExecute[1], 2);
        assertEq(orderIdsToExecute.length, 2);

        // set chainlinkprice below SL price
        chainlink.setPrice(ethFeed, ETH_PRICE * 98 / 100 - 1 * UNIT);
        orderIdsToExecute = trade.getExecutableOrderIds();

        // initial long order and SL order should be executable
        assertEq(orderIdsToExecute[0], 1);
        assertEq(orderIdsToExecute[1], 3);
        assertEq(orderIdsToExecute.length, 2);
    }

    function testClosePositionWithoutProfit() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit long
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        trade.closePositionWithoutProfit("ETH-USD");

        // users margin should be zero
        assertEq(store.getLockedMargin(user), 0);
    }

    function testRevertClosePositionWithoutProfit() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit order with TP 2% above current price and stop loss 2% below current price
        trade.submitOrder(ethLong, ETH_PRICE * 102 / 100, ETH_PRICE * 98 / 100);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // set ETH price below position price
        chainlink.setPrice(ethFeed, ETH_PRICE - 1 * UNIT);

        // call should revert since position is not in profit
        vm.expectRevert("pnl < 0");
        trade.closePositionWithoutProfit("ETH-USD");
    }

    function testDecreasePosition() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market long: size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);
        vm.stopPrank();

        uint256 orderFee = _getOrderFee("ETH-USD", ethLong.size);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // ETH falls 2% below entry price (5000 * 98/100 = 4900)
        chainlink.setPrice(ethFeed, ETH_PRICE * 98 / 100);

        // upl = positionSize * (price - positionPrice) / positionPrice
        // upl = 100k * (4.9k - 5k) / 5k = -2k
        uint256 upl = 2000 * CURRENCY_UNIT;
        assertEq(uint256(-1 * trade.getUpl(user)), upl, "!upl");

        // close position
        vm.prank(user);
        trade.submitOrder(ethCloseLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // locked margin should be zero
        assertEq(store.getLockedMargin(user), 0, "!margin");
        // user balance should be initial deposit - order fees (1x eth long, 1x close eth long) - upl (2k)
        assertEq(store.getBalance(user), INITIAL_TRADE_DEPOSIT - 2 * orderFee - upl, "!balance");
        // First call to Pool.creditTraderLoss, so trader loss goes to buffer
        assertEq(store.bufferBalance(), upl, "!bufferBalance");
    }

    function testDecreasePositionHalf() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market long: size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);
        vm.stopPrank();

        uint256 orderFee = _getOrderFee("ETH-USD", ethLong.size);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // ETH falls 2% below entry price (5000 * 98/100 = 4900)
        chainlink.setPrice(ethFeed, ETH_PRICE * 98 / 100);

        // upl = positionSize * (price - positionPrice) / positionPrice
        // upl = 100k * (4.9k - 5k) / 5k = -2k
        uint256 upl = 2000 * CURRENCY_UNIT;
        assertEq(uint256(-1 * trade.getUpl(user)), upl, "!upl");

        // close 50% of position
        vm.prank(user);
        ethCloseLong.size = ethLong.size / 2;
        trade.submitOrder(ethCloseLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        IStore.Market memory market = store.getMarket("ETH-USD");
        uint256 orderFeeClose = _getOrderFee("ETH-USD", ethLong.size / 2);

        // locked margin should be half of initial margin
        assertEq(store.getLockedMargin(user), (ethLong.size / 2) / market.maxLeverage, "!margin");
        // user balance should be initial deposit - order fees (1x eth long, 1x close eth long) - upl/2 (1k)
        assertEq(store.getBalance(user), INITIAL_TRADE_DEPOSIT - orderFee - orderFeeClose - upl / 2, "!balance");
        // First call to Pool.creditTraderLoss, so realized trader loss goes to buffer
        assertEq(store.bufferBalance(), upl / 2, "!bufferBalance");
    }

    function testDecreaseHalfAndClosePosition() public {
        testDecreasePositionHalf();

        // trade is now in profit
        chainlink.setPrice(ethFeed, ETH_PRICE * 102 / 100);

        // half of position is still open
        vm.prank(user);
        trade.closePositionWithoutProfit("ETH-USD");

        // locked margin should be zero
        assertEq(store.getLockedMargin(user), 0, "!margin");
    }

    function testDecreasePositionDouble() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market long: size 50k
        ethLong.size = 50_000 * CURRENCY_UNIT;
        trade.submitOrder(ethLong, 0, 0);
        vm.stopPrank();

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // open another position double the size in opposite direction (-> 100k short)
        vm.prank(user);
        ethShort.size = ethLong.size * 2;
        trade.submitOrder(ethShort, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        IStore.Order[] memory _orders = store.getOrders();
        IStore.Position[] memory _positions = store.getUserPositions(user);

        // initial long position should be removed, 50k short position should remain
        assertEq(_orders.length, 0, "!orderLength");
        assertEq(_positions.length, 1, "!positionLength");

        assertEq(_positions[0].isLong, false, "!position.isLong");
        assertEq(_positions[0].size, ethShort.size - ethLong.size, "!position.size");

        //_printOrders(true);
        //_printUserPositions(user, true);
    }

    function testLiquidateUsers() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit eth long, size 100k, margin 2k
        trade.submitOrder(ethLong, 0, 0);
        // submit btc long, size 100k, margin 2k
        trade.submitOrder(btcLong, 0, 0);
        vm.stopPrank();

        uint256 orderFee = _getOrderFee("ETH-USD", ethLong.size) + _getOrderFee("BTC-USD", btcLong.size);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // liquidation when marginLevel < 20%
        // marginLevel = (INITIAL_TRADE_DEPOSIT - fee + P/L) / lockedMargin
        // lockedMargin = 4k; INITIAL_TRADE_DEPOSIT - fee = 4800 USDC
        // -> liquidation when unrealized P/L = -4000 USD -> ETH has to fall below 4800 USD
        chainlink.setPrice(ethFeed, 4800 * UNIT);

        // ETH price is right at liquidation level, user shouldnt get liquidated yet
        address[] memory usersToLiquidate = trade.getLiquidatableUsers();
        assertEq(usersToLiquidate.length, 0);

        // set ETH price right below liquidation level
        chainlink.setPrice(ethFeed, 4799 * UNIT);
        usersToLiquidate = trade.getLiquidatableUsers();
        assertEq(usersToLiquidate[0], user);

        // liquidate user
        vm.prank(user2);
        trade.liquidateUsers();

        // liquidation fee should have been credited to user2
        uint256 liquidatorFee = orderFee * store.keeperFeeShare() / BPS_DIVIDER;
        assertEq(store.getBalance(user2), liquidatorFee);

        // buffer balance should be INITIAL_TRADE_DEPOSIT - fees
        assertEq(store.bufferBalance(), INITIAL_TRADE_DEPOSIT - 2 * orderFee); // orderfee on open and close (liquidation)
        // lockedMargin of user should be set to zero
        assertEq(store.getLockedMargin(user), 0);
        // and balance should be zero
        assertEq(store.getBalance(user), 0);
    }

    function testOpenInterestLong() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market long: size 10k, margin 2.5k
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        assertEq(store.getOILong("ETH-USD"), ethLong.size);

        // open short of same size, closing previous position
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        trade.submitOrder(ethShort, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        assertEq(store.getOILong("ETH-USD"), 0);
    }

    function testOpenInterestShort() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market short: size 10k, margin 2.5k
        trade.submitOrder(ethShort, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        assertEq(store.getOIShort("ETH-USD"), ethShort.size);
    }

    function testAccruedFunding() public {
        trade.deposit(INITIAL_TRADE_DEPOSIT);
        // submit market long: size 10k, margin 2.5k
        trade.submitOrder(ethLong, 0, 0);

        // minSettlementTime is 1 minutes -> fast forward 2 minutes
        skip(2 minutes);
        trade.executeOrders();

        // should be zero since no time passed
        assertEq(trade.getAccruedFunding("ETH-USD", 0), 0);

        // fast forward one day -> intervals = 24
        skip(1 days);

        // OI Long should be 10k * 10**18
        assertEq(store.getOILong("ETH-USD"), ethLong.size);

        // accruedFunding = UNIT * yearlyFundingFactor * OIDiff * intervals / (24 * 365 * (OILong + OIShort))
        // accruedFunding = UNIT * 5000 * 10k * CURRENCY_UNIT * 24 / (24 * 365 * 10k * CURRENCY_UNIT)
        // accruedFunding = UNIT * 5000 / 365 = 13698630136986301369 (or 0xbe1b4f87f88773b9 in hex)
        assertEq(trade.getAccruedFunding("ETH-USD", 0), 13698630136986301369);
    }

    // Fuzz tests
    /// @param amount deposit amount
    function testFuzzDepositAndWithdraw(uint256 amount) public {
        vm.assume(amount > 1 && amount <= INITIAL_BALANCE);

        // expect Deposit event
        vm.expectEmit(true, true, true, true);
        emit Deposit(user, amount);
        trade.deposit(amount);

        // balance should be equal to amount
        assertEq(store.getBalance(user), amount, "!userBalance");
        assertEq(IERC20(usdc).balanceOf(address(store)), amount, "!storeBalance");

        // expect withdraw event
        vm.expectEmit(true, true, true, true);
        emit Withdraw(user, amount);
        trade.withdraw(amount);
    }

    function testFuzzSubmitOrder(uint256 amount) public {
        IStore.Market memory market = store.getMarket("ETH-USD");
        vm.assume(amount > market.minSize && amount <= INITIAL_TRADE_DEPOSIT * market.maxLeverage);

        // deposit 5000 USDC for trading
        trade.deposit(INITIAL_TRADE_DEPOSIT);

        // submit ETH long with size = amount
        ethLong.size = amount;
        trade.submitOrder(ethLong, 0, 0);

        IStore.Order[] memory _orders = store.getOrders();

        assertEq(_orders.length, 1, "!orderLength");
        assertEq(_orders[0].size, amount, "!orderAmount");
    }
}
