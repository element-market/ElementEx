// SPDX-License-Identifier: Apache-2.0
/*

  Copyright 2023 Element.Market Intl.

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

import "../libs/LibSignature.sol";
import "../libs/LibNFTOrder.sol";
import "../libs/LibStructure.sol";

interface IMatchOrderFeature {

    /// @param fee [16 bits(platformFeePercentage) + 16 bits(royaltyFeePercentage) + 160 bits(royaltyFeeRecipient)].
    /// @param items [96 bits(erc20TokenAmount) + 160 bits(nftId)].
    struct BasicCollection {
        address nftAddress;
        bytes32 fee;
        bytes32[] items;
    }

    struct OrderItem {
        uint256 erc20TokenAmount;
        uint256 nftId;
    }

    /// @param fee [16 bits(platformFeePercentage) + 16 bits(royaltyFeePercentage) + 160 bits(royaltyFeeRecipient)].
    struct Collection {
        address nftAddress;
        bytes32 fee;
        OrderItem[] items;
    }

    /// @param data1 [48 bits(nonce) + 48 bits(startNonce) + 160 bits(maker)]
    /// @param data2 [32 bits(listingTime) + 32 bits(expiryTime) + 32 bits(reserved) + 160 bits(erc20Token)]
    /// @param data3 [8 bits(signatureType) + 8 bits(v) + 80 bits(reserved) + 160 bits(platformFeeRecipient)]
    struct SellOrderParam {
        uint256 data1;
        uint256 data2;
        uint256 data3;
        bytes32 r;
        bytes32 s;
        BasicCollection[] basicCollections;
        Collection[] collections;
    }

    struct BuyOrderParam {
        LibNFTOrder.NFTBuyOrder order;
        LibSignature.Signature signature;
        bytes extraData;
    }

    function matchOrder(
        SellOrderParam calldata sellOrderParam,
        BuyOrderParam calldata buyOrderParam
    ) external returns (uint256 profit);

    function matchOrders(bytes[] calldata datas, bool revertIfIncomplete) external;
}
