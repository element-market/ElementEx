// SPDX-License-Identifier: Apache-2.0
/*

  Modifications Copyright 2022 Element.Market
  Copyright 2021 ZeroEx Intl.

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


interface ITakerCallback {

    /// @dev A taker callback function invoked in ERC721OrdersFeature and
    ///      ERC1155OrdersFeature between the maker -> taker transfer and
    ///      the taker -> maker transfer.
    /// @param orderHash The hash of the order being filled when this
    ///        callback is invoked.
    /// @param data Arbitrary data used by this callback.
    /// @return success The selector of this function,
    ///         indicating that the callback succeeded.
    function zeroExTakerCallback(bytes32 orderHash, bytes calldata data) external returns (bytes4);
}
