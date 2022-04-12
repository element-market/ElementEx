// SPDX-License-Identifier: Apache-2.0
/*

  Modifications Copyright 2022 Element.Market
  Copyright 2020 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.8.13;


/// @dev EIP712 helpers for features.
abstract contract FixinEIP712 {

    bytes32 private constant DOMAIN = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME = keccak256("ElementEx");
    bytes32 private constant VERSION = keccak256("1.0.0");
    uint256 private immutable CHAIN_ID;

    constructor() {
        uint256 chainId;
        assembly { chainId := chainid() }
        CHAIN_ID = chainId;
    }

    function _getEIP712Hash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", keccak256(abi.encode(DOMAIN, NAME, VERSION, CHAIN_ID, address(this))), structHash));
    }
}
