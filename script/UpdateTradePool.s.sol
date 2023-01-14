// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/interfaces/IStore.sol";
import "../src/Trade.sol";
import "../src/Pool.sol";

import "./Config.sol";

contract UpdateTradePool is Config {
    Trade public trade;
    Pool public pool;

    address public store = address(0xf16033d20ADDa47Dc99eA291D0F4C4FeF2fF47af);
    address public clp = address(0xFc4351357748d03CC938807e68A725E445C44995);
    address public chainlink = address(0x4CA8c060EBFBcF82111c5dA3a2619A8C71B12C96);

    function run() public {
        // create fork
        arbitrum = vm.createSelectFork(ARBITRUM_RPC_URL);

        // private key for deployment
        uint256 pk = vm.envUint("PRIVATE_KEY");
        console.log("Deploying contracts with address", vm.addr(pk));

        _deploy(arbitrum, pk, ARB_USDC, vm.addr(pk), vm.addr(pk));
    }

    function _deploy(uint256 fork, uint256 pk, address usdc, address _treasury, address _gov) internal {
        // select fork
        vm.selectFork(fork);

        // start broadcasting
        vm.startBroadcast(pk);

        // deploy contracts
        trade = new Trade{salt: bytes32("TRADE5")}(_gov);
        pool = new Pool{salt: bytes32("POOL5")}(_gov);

        // Link contracts
        IStore(store).link(address(trade), address(pool), usdc, clp);
        pool.link(address(trade), store, _treasury);
        trade.link(chainlink, address(pool), store);

        vm.stopBroadcast();
    }
}
