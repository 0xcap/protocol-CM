// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

interface ICLP {
    function burn(address from, uint256 amount) external;

    function mint(address to, uint256 amount) external;
}
