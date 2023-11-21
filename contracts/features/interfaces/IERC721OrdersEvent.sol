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

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libs/LibNFTOrder.sol";
import "../libs/LibStructure.sol";


interface IERC721OrdersEvent {

    /// @dev Emitted whenever an `ERC721SellOrder` is filled.
    /// @param orderHash The `ERC721SellOrder` hash.
    /// @param maker The maker of the order.
    /// @param taker The taker of the order.
    /// @param erc20Token The address of the ERC20 token.
    /// @param erc20TokenAmount The amount of ERC20 token to sell.
    /// @param erc721Token The address of the ERC721 token.
    /// @param erc721TokenId The ID of the ERC721 asset.
    event ERC721SellOrderFilled(
        bytes32 orderHash,
        address maker,
        address taker,
        uint256 nonce,
        IERC20 erc20Token,
        uint256 erc20TokenAmount,
        LibStructure.Fee[] fees,
        address erc721Token,
        uint256 erc721TokenId
    );

    /// @dev Emitted whenever an `ERC721BuyOrder` is filled.
    /// @param orderHash The `ERC721BuyOrder` hash.
    /// @param maker The maker of the order.
    /// @param taker The taker of the order.
    /// @param erc20Token The address of the ERC20 token.
    /// @param erc20TokenAmount The amount of ERC20 token to buy.
    /// @param erc721Token The address of the ERC721 token.
    /// @param erc721TokenId The ID of the ERC721 asset.
    event ERC721BuyOrderFilled(
        bytes32 orderHash,
        address maker,
        address taker,
        uint256 nonce,
        IERC20 erc20Token,
        uint256 erc20TokenAmount,
        LibStructure.Fee[] fees,
        address erc721Token,
        uint256 erc721TokenId
    );

    /// @dev Emitted when an `ERC721SellOrder` is pre-signed.
    ///      Contains all the fields of the order.
    event ERC721SellOrderPreSigned(
        address maker,
        address taker,
        uint256 expiry,
        uint256 nonce,
        IERC20 erc20Token,
        uint256 erc20TokenAmount,
        LibNFTOrder.Fee[] fees,
        address erc721Token,
        uint256 erc721TokenId
    );

    /// @dev Emitted when an `ERC721BuyOrder` is pre-signed.
    ///      Contains all the fields of the order.
    event ERC721BuyOrderPreSigned(
        address maker,
        address taker,
        uint256 expiry,
        uint256 nonce,
        IERC20 erc20Token,
        uint256 erc20TokenAmount,
        LibNFTOrder.Fee[] fees,
        address erc721Token,
        uint256 erc721TokenId,
        LibNFTOrder.Property[] nftProperties
    );

    /// @dev Emitted whenever an `ERC721Order` is cancelled.
    /// @param maker The maker of the order.
    /// @param nonce The nonce of the order that was cancelled.
    event ERC721OrderCancelled(address maker, uint256 nonce);

    /// @dev Emitted HashNonceIncremented.
    event HashNonceIncremented(address maker, uint256 newHashNonce);
}
