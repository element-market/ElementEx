// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import "../../storage/LibStorage.sol";


abstract contract ReentrancyGuard {

    uint256 constant STORAGE_ID_REENTRANCY_GUARD = 7 << 128;

    modifier nonReentrant() {
        assembly {
            if gt(sload(STORAGE_ID_REENTRANCY_GUARD), 1) {
                // revert("ReentrancyGuard: reentrant call.")
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, 0x000000205265656e7472616e637947756172643a207265656e7472616e742063)
                mstore(0x60, 0x616c6c2e00000000000000000000000000000000000000000000000000000000)
                revert(0, 0x64)
            }
            sstore(STORAGE_ID_REENTRANCY_GUARD, 2)
        }

        _;

        assembly {
            sstore(STORAGE_ID_REENTRANCY_GUARD, 1)
        }
    }
}
