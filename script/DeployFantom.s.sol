// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/interfaces/IStore.sol";
import "../src/Trade.sol";
import "../src/Pool.sol";
import "../src/Store.sol";
import "../src/CLP.sol";
import "../src/Chainlink.sol";

import "./Config.sol";

contract DeployFantom is Config {
    Trade public trade;
    Pool public pool;
    Store public store;
    CLP public clp;

    Chainlink public chainlink;

    function run() public {
        // create fork
        fantom = vm.createFork(FANTOM_RPC_URL);

        // private key for deployment
        uint256 pk = vm.envUint("PRIVATE_KEY");
        console.log("Deploying contracts with address", vm.addr(pk));

        // deploy DEX with USDC as base currency
        // for WETH (or any other token with 18 decimals) as base currency, use _deployBaseWETH
        // and replace fourth function argument, e.g. ARB_USDC -> ARB_WETH
        _deployBaseUSDC(
            fantom,
            pk,
            address(0), // no sequencer needed
            FTM_USDC,
            FTM_ETHUSD,
            FTM_BTCUSD,
            address(0), // no uniswap support
            address(0), // no uniswap support
            address(0), // no uniswap support
            vm.addr(pk),
            vm.addr(pk)
        );

        console.log("Contracts deployed");
    }

    function _deployBaseUSDC(
        uint256 fork,
        uint256 pk,
        address sequencer,
        address currency,
        address ethFeed,
        address btcFeed,
        address _swapRouter,
        address _quoter,
        address _weth,
        address _treasury,
        address _gov
    ) internal {
        // select fork
        vm.selectFork(fork);

        // start broadcasting
        vm.startBroadcast(pk);

        // deploy contracts
        chainlink = new Chainlink{salt: bytes32("CHAINLINK10")}(sequencer);
        store = new Store{salt: bytes32("STORE10")}(_gov);
        trade = new Trade{salt: bytes32("TRADE10")}(_gov);
        pool = new Pool{salt: bytes32("POOL10")}(_gov);
        clp = new CLP{salt: bytes32("CLP10")}(address(store));

        // Link contracts
        store.link(address(trade), address(pool), currency, address(clp));
        store.linkUniswap(_swapRouter, _quoter, _weth);
        trade.link(address(chainlink), address(pool), address(store));
        pool.link(address(trade), address(store), _treasury);

        // Setup markets
        store.setMarket(
            "ETH-USD",
            IStore.Market({
                symbol: "ETH-USD",
                feed: ethFeed,
                maxLeverage: 50,
                maxOI: 5000000 * CURRENCY_UNIT,
                fee: 10,
                fundingFactor: 5000,
                minSize: 20 * CURRENCY_UNIT,
                minSettlementTime: 1 minutes
            })
        );
        store.setMarket(
            "BTC-USD",
            IStore.Market({
                symbol: "BTC-USD",
                feed: btcFeed,
                maxLeverage: 50,
                maxOI: 5000000 * CURRENCY_UNIT,
                fee: 10,
                fundingFactor: 5000,
                minSize: 20 * CURRENCY_UNIT,
                minSettlementTime: 1 minutes
            })
        );

        vm.stopBroadcast();
    }

    function _deployBaseWETH(
        uint256 fork,
        uint256 pk,
        address sequencer,
        address usdc,
        address ethFeed,
        address btcFeed,
        address _swapRouter,
        address _quoter,
        address _weth,
        address _treasury,
        address _gov
    ) internal {
        // select fork
        vm.selectFork(fork);

        // start broadcasting
        vm.startBroadcast(pk);

        // deploy contracts
        chainlink = new Chainlink{salt: bytes32("CHAINLINK10")}(sequencer);
        store = new Store{salt: bytes32("STORE10")}(_gov);
        trade = new Trade{salt: bytes32("TRADE10")}(_gov);
        pool = new Pool{salt: bytes32("POOL10")}(_gov);
        clp = new CLP{salt: bytes32("CLP10")}(address(store));

        // Link contracts
        store.link(address(trade), address(pool), usdc, address(clp));
        store.linkUniswap(_swapRouter, _quoter, _weth);
        trade.link(address(chainlink), address(pool), address(store));
        pool.link(address(trade), address(store), _treasury);

        // Setup markets
        store.setMarket(
            "ETH-USD",
            IStore.Market({
                symbol: "ETH-USD",
                feed: ethFeed,
                maxLeverage: 50,
                maxOI: 5000 ether, // ether == 10 ** 18
                fee: 10,
                fundingFactor: 5000,
                minSize: 0.01 ether,
                minSettlementTime: 1 minutes
            })
        );
        store.setMarket(
            "BTC-USD",
            IStore.Market({
                symbol: "BTC-USD",
                feed: btcFeed,
                maxLeverage: 50,
                maxOI: 5000 ether, // ether == 10 ** 18
                fee: 10,
                fundingFactor: 5000,
                minSize: 0.01 ether,
                minSettlementTime: 1 minutes
            })
        );

        vm.stopBroadcast();
    }
}
