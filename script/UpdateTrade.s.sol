// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import "../src/interfaces/IStore.sol";
import "../src/Trade.sol";

contract UpdateTrade is Script {
    /* ========== FORK CONFIG ========== */
    uint256 arbitrum;

    string ARBITRUM_RPC_URL = vm.envString("ARBITRUM_RPC_URL");

    /* ========== DEPLOYMENT ADDRESSES ========== */
    // Deployment addresses for USDC
    address ARB_USDC = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

    /* ========== CONTRACTS ========== */
    Trade public trade;

    address public pool = address(0x3E4CdcDC5E3F46DCe516adB428d107CE62A6D24a);
    address public store = address(0xf16033d20ADDa47Dc99eA291D0F4C4FeF2fF47af);
    address public clp = address(0xFc4351357748d03CC938807e68A725E445C44995);
    address public chainlink = address(0x4CA8c060EBFBcF82111c5dA3a2619A8C71B12C96);

    /* ========== METHODS ========== */
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
        trade = new Trade{salt: bytes32("TRADE6")}(_gov);

        // Link contracts
        IStore(store).link(address(trade), pool, usdc, clp);
        trade.link(chainlink, pool, store);

        vm.stopBroadcast();
    }
}
