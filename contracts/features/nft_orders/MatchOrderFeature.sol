// SPDX-License-Identifier: Apache-2.0
/*

  Copyright 2022 Element.Market Intl.

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

import "../../storage/LibCommonNftOrdersStorage.sol";
import "../../storage/LibERC721OrdersStorage.sol";
import "../../vendor/IPropertyValidator.sol";
import "../../vendor/IFeeRecipient.sol";
import "../../vendor/IEtherToken.sol";
import "../../fixins/FixinTokenSpender.sol";
import "../../fixins/FixinERC721Spender.sol";
import "../libs/LibTypeHash.sol";
import "../interfaces/IERC721OrdersEvent.sol";
import "../interfaces/IMatchOrderFeature.sol";

struct SellOrderInfo {
    bytes32 orderHash;
    address maker;
    uint256 listingTime;
    uint256 expiryTime;
    uint256 startNonce;
    address erc20Token;
    address platformFeeRecipient;
    bytes32 basicCollectionsHash;
    bytes32 collectionsHash;
    uint256 hashNonce;
    uint256 erc20TokenAmount;
    uint256 platformFeeAmount;
    address royaltyFeeRecipient;
    uint256 royaltyFeeAmount;
    address erc721Token;
    uint256 erc721TokenID;
    uint256 nonce;
}

/// @dev Feature for interacting with ERC721 orders.
contract MatchOrderFeature is IMatchOrderFeature, IERC721OrdersEvent, FixinTokenSpender, FixinERC721Spender  {

    uint256 internal constant ORDER_NONCE_MASK = (1 << 184) - 1;
    uint256 internal constant MASK_160 = (1 << 160) - 1;
    uint256 internal constant MASK_64 = (1 << 64) - 1;
    uint256 internal constant MASK_48 = (1 << 48) - 1;
    uint256 internal constant MASK_32 = (1 << 32) - 1;
    uint256 internal constant MASK_16 = (1 << 16) - 1;

    uint256 internal constant MASK_SELECTOR = 0xffffffff << 224;
    uint256 constant STORAGE_ID_PROXY = 1 << 128;

    // keccak256("")
    bytes32 internal constant _EMPTY_ARRAY_KECCAK256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    // keccak256(abi.encodePacked(
    //    "BatchSignedERC721Orders(address maker,uint256 listingTime,uint256 expiryTime,uint256 startNonce,address erc20Token,address platformFeeRecipient,BasicCollection[] basicCollections,Collection[] collections,uint256 hashNonce)",
    //    "BasicCollection(address nftAddress,bytes32 fee,bytes32[] items)",
    //    "Collection(address nftAddress,bytes32 fee,OrderItem[] items)",
    //    "OrderItem(uint256 erc20TokenAmount,uint256 nftId)"
    // ))
    bytes32 internal constant _BATCH_SIGNED_ERC721_ORDERS_TYPE_HASH = 0x2d8cbbbc696e7292c3b5beb38e1363d34ff11beb8c3456c14cb938854597b9ed;
    // keccak256("BasicCollection(address nftAddress,bytes32 fee,bytes32[] items)")
    bytes32 internal constant _BASIC_COLLECTION_TYPE_HASH = 0x12ad29288fd70022f26997a9958d9eceb6e840ceaa79b72ea5945ba87e4d33b0;
    // keccak256(abi.encodePacked(
    //    "Collection(address nftAddress,bytes32 fee,OrderItem[] items)",
    //    "OrderItem(uint256 erc20TokenAmount,uint256 nftId)"
    // ))
    bytes32 internal constant _COLLECTION_TYPE_HASH = 0xb9f488d48cec782be9ecdb74330c9c6a33c236a8022d8a91a4e4df4e81b51620;
    // keccak256("OrderItem(uint256 erc20TokenAmount,uint256 nftId)")
    bytes32 internal constant _ORDER_ITEM_TYPE_HASH = 0x5f93394997caa49a9382d44a75e3ce6a460f32b39870464866ac994f8be97afe;

    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant DOMAIN = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    // keccak256("ElementEx")
    bytes32 internal constant NAME = 0x27b14c20196091d9cd90ca9c473d3ad1523b00ddf487a9b7452a8a119a16b98c;
    // keccak256("1.0.0")
    bytes32 internal constant VERSION = 0x06c015bd22b4c69690933c1058878ebdfef31f9aaae40bbe86d8a09fe1b2972c;

    /// @dev The WETH token contract.
    IEtherToken internal immutable WETH;
    /// @dev The implementation address of this feature.
    address internal immutable _IMPL;
    /// @dev The magic return value indicating the success of a `validateProperty`.
    bytes4 internal constant PROPERTY_CALLBACK_MAGIC_BYTES = IPropertyValidator.validateProperty.selector;
    /// @dev The magic return value indicating the success of a `receiveZeroExFeeCallback`.
    bytes4 internal constant FEE_CALLBACK_MAGIC_BYTES = IFeeRecipient.receiveZeroExFeeCallback.selector;
    address internal constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor(IEtherToken weth) {
        require(address(weth) != address(0), "WETH_ADDRESS_ERROR");
        WETH = weth;
        _IMPL = address(this);
    }

    function matchOrders(bytes[] calldata datas, bool revertIfIncomplete) external override {
        address implMatchOrder = _IMPL;
        address implMatchERC721Order;
        address implMatchERC1155Order;
        assembly {
            let someSuccess := 0
            let ptrEnd := add(datas.offset, mul(datas.length, 0x20))
            for { let ptr := datas.offset } lt(ptr, ptrEnd) { ptr := add(ptr, 0x20) } {
                let ptrData := add(datas.offset, calldataload(ptr))

                // Check the data length
                let dataLength := calldataload(ptrData)
                if lt(dataLength, 0x4) {
                    if revertIfIncomplete {
                        _revertDatasError()
                    }
                    continue
                }

                let impl
                let selector := and(calldataload(add(ptrData, 0x20)), MASK_SELECTOR)
                switch selector
                // matchOrder
                case 0xed03aa3c00000000000000000000000000000000000000000000000000000000 {
                    impl := implMatchOrder
                }
                // matchERC721Order
                case 0xe2f5f57200000000000000000000000000000000000000000000000000000000 {
                    if iszero(implMatchERC721Order) {
                        implMatchERC721Order := _getImplementation(selector)
                    }
                    impl := implMatchERC721Order
                }
                // matchERC1155Order
                case 0xd8abf66700000000000000000000000000000000000000000000000000000000 {
                    if iszero(implMatchERC1155Order) {
                        implMatchERC1155Order := _getImplementation(selector)
                    }
                    impl := implMatchERC1155Order
                }

                if impl {
                    calldatacopy(0, add(ptrData, 0x20), dataLength)
                    if delegatecall(gas(), impl, 0, dataLength, 0, 0) {
                        someSuccess := 1
                        continue
                    }
                    if revertIfIncomplete {
                        returndatacopy(0, 0, returndatasize())
                        revert(0, returndatasize())
                    }
                    continue
                }

                if revertIfIncomplete {
                    _revertSelectorMismatch()
                }
            }

            if iszero(someSuccess) {
                _revertNoCallSuccess()
            }

            function _getImplementation(selector) -> impl {
                mstore(0x0, selector)
                mstore(0x20, STORAGE_ID_PROXY)
                impl := sload(keccak256(0x0, 0x40))
            }

            function _revertDatasError() {
                // revert("matchOrders: data error")
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, 0x000000176d617463684f72646572733a2064617461206572726f720000000000)
                mstore(0x60, 0)
                revert(0, 0x64)
            }

            function _revertSelectorMismatch() {
                // revert("matchOrders: selector mismatch")
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, 0x0000001e6d617463684f72646572733a2073656c6563746f72206d69736d6174)
                mstore(0x60, 0x6368000000000000000000000000000000000000000000000000000000000000)
                revert(0, 0x64)
            }

            function _revertNoCallSuccess() {
                // revert("matchOrders: no calls success")
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, 0x0000001d6d617463684f72646572733a206e6f2063616c6c7320737563636573)
                mstore(0x60, 0x7300000000000000000000000000000000000000000000000000000000000000)
                revert(0, 0x64)
            }
        }
    }

    function matchOrder(
        SellOrderParam memory sellOrderParam,
        BuyOrderParam memory buyOrderParam
    )
        external
        override
        returns (uint256 profit)
    {
        SellOrderInfo memory sellOrderInfo = _checkupSellOrder(sellOrderParam);
        bytes32 buyOrderHash = _checkupBuyOrder(buyOrderParam, sellOrderInfo.maker, sellOrderInfo.erc721TokenID);

        LibNFTOrder.NFTBuyOrder memory buyOrder = buyOrderParam.order;
        require(sellOrderInfo.erc721Token == buyOrder.nft, "matchOrder: erc721 token mismatch");
        require(sellOrderInfo.erc20TokenAmount <= buyOrder.erc20TokenAmount, "matchOrder: erc20TokenAmount mismatch");

        uint256 amountToSeller;
        unchecked {
            amountToSeller = sellOrderInfo.erc20TokenAmount - sellOrderInfo.platformFeeAmount - sellOrderInfo.royaltyFeeAmount;
            profit = buyOrder.erc20TokenAmount - sellOrderInfo.erc20TokenAmount;
        }

        // Transfer the ERC721 asset from seller to buyer.
        _transferERC721AssetFrom(sellOrderInfo.erc721Token, sellOrderInfo.maker, buyOrder.maker, sellOrderInfo.erc721TokenID);

        if (sellOrderInfo.erc20Token == NATIVE_TOKEN_ADDRESS && buyOrder.erc20Token == WETH) {
            // Step 1: Transfer WETH from the buyer to element.
            _transferERC20TokensFrom(address(WETH), buyOrder.maker, address(this), buyOrder.erc20TokenAmount);

            // Step 2: Unwrap the WETH into ETH.
            WETH.withdraw(buyOrder.erc20TokenAmount);

            // Step 3: Pay the seller (in ETH).
            _transferEth(payable(sellOrderInfo.maker), amountToSeller);

            // Step 4: Pay fees for the buy order.
            _payFees(buyOrder);

            // Step 5: Pay fees for the sell order.
            _payFees(sellOrderInfo, address(0), true);

            // Step 6: Transfer the profit to msg.sender.
            _transferEth(payable(msg.sender), profit);
        } else {
            // Check ERC20 tokens
            require(sellOrderInfo.erc20Token == address(buyOrder.erc20Token), "matchOrder: erc20 token mismatch");

            // Step 1: Transfer the ERC20 token from the buyer to the seller.
            _transferERC20TokensFrom(sellOrderInfo.erc20Token, buyOrder.maker, sellOrderInfo.maker, amountToSeller);

            // Step 2: Pay fees for the buy order.
            _payFees(buyOrder);

            // Step 3: Pay fees for the sell order.
            _payFees(sellOrderInfo, buyOrder.maker, false);

            // Step 4: Transfer the profit to msg.sender.
            _transferERC20TokensFrom(sellOrderInfo.erc20Token, buyOrder.maker, msg.sender, profit);
        }

        _emitEventSellOrderFilled(sellOrderInfo, buyOrder.maker);
        _emitEventBuyOrderFilled(buyOrder, sellOrderInfo.maker, sellOrderInfo.erc721TokenID, buyOrderHash);
    }

    function _checkupBuyOrder(
        BuyOrderParam memory param, address taker, uint256 tokenId
    ) internal returns (bytes32) {
        LibNFTOrder.NFTBuyOrder memory order = param.order;
        uint256 expiry = order.expiry;

        // Check maker.
        require(order.maker != address(0), "checkupBuyOrder: invalid maker");

        // Check erc20Token.
        require(address(order.erc20Token) != NATIVE_TOKEN_ADDRESS, "checkupBuyOrder: invalid erc20Token");

        // Check taker.
        require(order.taker == address(0) || order.taker == taker, "checkupBuyOrder: invalid taker");

        // Check listingTime.
        require(block.timestamp >= ((expiry >> 32) & MASK_32), "checkupBuyOrder: check listingTime failed");

        // Check expiryTime.
        require(block.timestamp < (expiry & MASK_32), "checkupBuyOrder: check expiryTime failed");

        // Check orderStatus.
        if (_isOrderFilledOrCancelled(order.maker, order.nonce)) {
            revert("checkupBuyOrder: order is filled");
        }

        bytes32 leaf = LibNFTOrder.getNFTBuyOrderStructHash(order, _getHashNonce(order.maker));
        bytes32 orderHash = _getEIP712Hash(leaf);

        // Check batch offer order.
        uint128 orderAmount = 1;
        if (expiry >> 252 == LibStructure.ORDER_KIND_BATCH_OFFER_ERC721S) {
            orderAmount = uint128((expiry >> 64) & MASK_32);
            uint128 filledAmount = LibERC721OrdersStorage.getStorage().filledAmount[orderHash];
            require(filledAmount < orderAmount, "checkupBuyOrder: order is filled");

            // Update order status.
            unchecked {
                LibERC721OrdersStorage.getStorage().filledAmount[orderHash] = (filledAmount + 1);
            }

            // Requires `nftProperties.length` > 0.
            require(order.nftProperties.length > 0, "checkupBuyOrder: invalid order kind");
        } else {
            // Update order status.
            _setOrderStatusBit(order.maker, order.nonce);
        }

        bytes32 validateHash = orderHash;
        bytes memory extraData = param.extraData;
        LibSignature.Signature memory signature = param.signature;

        // Bulk signature.
        if (
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK ||
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK_1271
        ) {
            (validateHash, extraData) = _getBulkValidateHashAndExtraData(leaf, param.extraData);
        }

        // Validate properties.
        _validateOrderProperties(order, orderHash, tokenId, extraData);

        // Check the signature.
        _validateOrderSignature(
            validateHash,
            order.maker,
            signature.signatureType,
            signature.v,
            signature.r,
            signature.s
        );

        if (orderAmount > 1) {
            unchecked {
                order.erc20TokenAmount /= orderAmount;
                for (uint256 i; i < order.fees.length; i++) {
                    order.fees[i].amount /= orderAmount;
                }
            }
        }
        return orderHash;
    }

    /// data1 [48 bits(nonce) + 48 bits(startNonce) + 160 bits(maker)]
    /// data2 [32 bits(listingTime) + 32 bits(expiryTime) + 32 bits(reserved) + 160 bits(erc20Token)]
    /// data3 [8 bits(signatureType) + 8 bits(v) + 80 bits(reserved) + 160 bits(platformFeeRecipient)]
    function _checkupSellOrder(SellOrderParam memory param) internal returns (SellOrderInfo memory info) {
        uint256 data1 = param.data1;
        uint256 data2 = param.data2;
        uint256 data3 = param.data3;

        info.nonce = data1 >> 208;
        info.startNonce = (data1 >> 160) & MASK_48;
        info.maker = address(uint160(data1 & MASK_160));
        info.listingTime = data2 >> 224;
        info.expiryTime = (data2 >> 192) & MASK_32;
        info.erc20Token = address(uint160(data2 & MASK_160));
        info.platformFeeRecipient = address(uint160(data3 & MASK_160));
        info.hashNonce = _getHashNonce(info.maker);

        // Check nonce.
        require(info.startNonce <= info.nonce, "checkupSellOrder: invalid nonce");

        // Check maker.
        require(info.maker != address(0), "checkupSellOrder: invalid maker");

        // Check listingTime.
        require(block.timestamp >= info.listingTime, "checkupSellOrder: check listingTime failed");

        // Check expiryTime.
        require(block.timestamp < info.expiryTime, "checkupSellOrder: check expiryTime failed");

        // Check orderStatus.
        if (_isOrderFilledOrCancelled(info.maker, info.nonce)) {
            revert("checkupSellOrder: order is filled");
        }

        // Update order status.
        _setOrderStatusBit(info.maker, info.nonce);

        // Get collectionsHash.
        _storeCollectionsHashToOrderInfo(param.basicCollections, param.collections, info);

        // structHash = keccak256(abi.encode(
        //     _BATCH_SIGNED_ERC721_ORDERS_TYPE_HASH,
        //     maker,
        //     listingTime,
        //     expiryTime,
        //     startNonce,
        //     erc20Token,
        //     platformFeeRecipient,
        //     basicCollectionsHash,
        //     collectionsHash,
        //     hashNonce
        // ));
        bytes32 structHash;
        assembly {
            mstore(info, _BATCH_SIGNED_ERC721_ORDERS_TYPE_HASH)
            structHash := keccak256(info, 0x140 /* 10 * 32 */)
        }
        info.orderHash = _getEIP712Hash(structHash);

        LibSignature.SignatureType signatureType;
        uint8 v;
        assembly {
            signatureType := byte(0, data3)
            v := byte(1, data3)
        }
        require(
            signatureType == LibSignature.SignatureType.EIP712 ||
            signatureType == LibSignature.SignatureType.EIP712_1271,
            "checkupSellOrder: invalid signatureType"
        );

        _validateOrderSignature(
            info.orderHash,
            info.maker,
            signatureType,
            v,
            param.r,
            param.s
        );
    }

    function _decodeSellOrderFee(SellOrderInfo memory outInfo, bytes32 fee) internal pure {
        uint256 platformFeePercentage;
        uint256 royaltyFeePercentage;
        address royaltyFeeRecipient;
        assembly {
            // fee [16 bits(platformFeePercentage) + 16 bits(royaltyFeePercentage) + 160 bits(royaltyFeeRecipient)]
            platformFeePercentage := and(shr(176, fee), MASK_16)
            royaltyFeePercentage := and(shr(160, fee), MASK_16)
            royaltyFeeRecipient := and(fee, MASK_160)
        }
        outInfo.royaltyFeeRecipient = royaltyFeeRecipient;

        if (royaltyFeeRecipient == address(0)) {
            royaltyFeePercentage = 0;
        }
        if (outInfo.platformFeeRecipient == address(0)) {
            platformFeePercentage = 0;
        }

        unchecked {
            require(platformFeePercentage + royaltyFeePercentage <= 10000, "checkupSellOrder: fees percentage exceeds the limit");
            outInfo.platformFeeAmount = outInfo.erc20TokenAmount * platformFeePercentage / 10000;
            if (royaltyFeePercentage != 0) {
                outInfo.royaltyFeeAmount = outInfo.erc20TokenAmount * royaltyFeePercentage / 10000;
            }
        }
    }

    function _storeCollectionsHashToOrderInfo(
        BasicCollection[] memory basicCollections,
        Collection[] memory collections,
        SellOrderInfo memory outInfo
    ) internal pure {
        uint256 current;
        bool isTargetFind;
        uint256 targetIndex;
        unchecked {
            targetIndex = outInfo.nonce - outInfo.startNonce;
        }

        if (basicCollections.length == 0) {
            outInfo.basicCollectionsHash = _EMPTY_ARRAY_KECCAK256;
        } else {
            bytes32 ptr;
            bytes32 ptrHashArray;
            assembly {
                ptr := mload(0x40) // free memory pointer
                ptrHashArray := add(ptr, 0x80)
                mstore(ptr, _BASIC_COLLECTION_TYPE_HASH)
            }

            uint256 collectionsLength = basicCollections.length;
            for (uint256 i; i < collectionsLength; ) {
                BasicCollection memory collection = basicCollections[i];
                address nftAddress = collection.nftAddress;
                bytes32 fee = collection.fee;
                bytes32[] memory items = collection.items;
                uint256 itemsLength = items.length;

                if (!isTargetFind) {
                    unchecked {
                        uint256 next = current + itemsLength;
                        if (targetIndex >= current && targetIndex < next) {
                            isTargetFind = true;
                            outInfo.erc721Token = nftAddress;

                            uint256 item = uint256(items[targetIndex - current]);
                            outInfo.erc721TokenID = item & MASK_160;
                            outInfo.erc20TokenAmount = item >> 160;
                            _decodeSellOrderFee(outInfo, fee);
                        } else {
                            current = next;
                        }
                    }
                }

                assembly {
                    mstore(add(ptr, 0x20), nftAddress)
                    mstore(add(ptr, 0x40), fee)
                    mstore(add(ptr, 0x60), keccak256(add(items, 0x20), mul(itemsLength, 0x20)))
                    mstore(ptrHashArray, keccak256(ptr, 0x80))

                    ptrHashArray := add(ptrHashArray, 0x20)
                    i := add(i, 1)
                }
            }

            assembly {
                // store basicCollectionsHash
                mstore(add(outInfo, 0xe0), keccak256(add(ptr, 0x80), mul(collectionsLength, 0x20)))
            }
        }

        if (collections.length == 0) {
            outInfo.collectionsHash = _EMPTY_ARRAY_KECCAK256;
        } else {
            bytes32 ptr;
            bytes32 ptrHashArray;
            assembly {
                ptr := mload(0x40) // free memory pointer
                ptrHashArray := add(ptr, 0x80)
            }

            uint256 collectionsLength = collections.length;
            for (uint256 i; i < collectionsLength; ) {
                Collection memory collection = collections[i];
                address nftAddress = collection.nftAddress;
                bytes32 fee = collection.fee;
                OrderItem[] memory items = collection.items;
                uint256 itemsLength = items.length;

                if (!isTargetFind) {
                    unchecked {
                        uint256 next = current + itemsLength;
                        if (targetIndex >= current && targetIndex < next) {
                            isTargetFind = true;
                            outInfo.erc721Token = nftAddress;

                            OrderItem memory item = items[targetIndex - current];
                            outInfo.erc721TokenID = item.nftId;
                            outInfo.erc20TokenAmount = item.erc20TokenAmount;
                            _decodeSellOrderFee(outInfo, fee);
                        } else {
                            current = next;
                        }
                    }
                }

                bytes32 ptrItemHashArray = ptrHashArray;
                assembly {
                    mstore(ptr, _ORDER_ITEM_TYPE_HASH)
                }

                for (uint256 j; j < itemsLength; ) {
                    uint256 erc20TokenAmount = items[j].erc20TokenAmount;
                    uint256 nftId = items[j].nftId;
                    assembly {
                        mstore(add(ptr, 0x20), erc20TokenAmount)
                        mstore(add(ptr, 0x40), nftId)
                        mstore(ptrItemHashArray, keccak256(ptr, 0x60))

                        ptrItemHashArray := add(ptrItemHashArray, 0x20)
                        j := add(j, 1)
                    }
                }

                assembly {
                    mstore(ptr, _COLLECTION_TYPE_HASH)
                    mstore(add(ptr, 0x20), nftAddress)
                    mstore(add(ptr, 0x40), fee)
                    mstore(add(ptr, 0x60), keccak256(ptrHashArray, mul(itemsLength, 0x20)))
                    mstore(ptrHashArray, keccak256(ptr, 0x80))

                    ptrHashArray := add(ptrHashArray, 0x20)
                    i := add(i, 1)
                }
            }

            assembly {
                // store collectionsHash
                mstore(add(outInfo, 0x100), keccak256(add(ptr, 0x80), mul(collectionsLength, 0x20)))
            }
        }
        require(isTargetFind, "checkupSellOrder: invalid nonce");
    }

    function _getEIP712Hash(bytes32 structHash) internal view returns (bytes32 eip712Hash) {
        assembly {
            let ptr := mload(0x40) // free memory pointer

            mstore(ptr, DOMAIN)
            mstore(add(ptr, 0x20), NAME)
            mstore(add(ptr, 0x40), VERSION)
            mstore(add(ptr, 0x60), chainid())
            mstore(add(ptr, 0x80), address())

            mstore(add(ptr, 0x20), keccak256(ptr, 0xa0))
            mstore(add(ptr, 0x40), structHash)
            mstore(ptr, 0x1901)
            eip712Hash := keccak256(add(ptr, 0x1e), 0x42)
        }
    }

    function _getHashNonce(address maker) internal view returns (uint256) {
        return LibCommonNftOrdersStorage.getStorage().hashNonces[maker];
    }

    function _isOrderFilledOrCancelled(address maker, uint256 nonce) internal view returns(bool) {
        // Order status bit vectors are indexed by maker address and the
        // upper 248 bits of the order nonce. We define `nonceRange` to be
        // these 248 bits.
        uint248 nonceRange = uint248((nonce >> 8) & ORDER_NONCE_MASK);

        // `orderStatusByMaker` is indexed by maker and nonce.
        uint256 orderStatusBitVector =
            LibERC721OrdersStorage.getStorage().orderStatusByMaker[maker][nonceRange];

        // The bitvector is indexed by the lower 8 bits of the nonce.
        uint256 flag = 1 << (nonce & 255);

        // If the designated bit is set, the order has been cancelled or
        // previously filled.
        return orderStatusBitVector & flag != 0;
    }

    function _setOrderStatusBit(address maker, uint256 nonce) internal {
        // Order status bit vectors are indexed by maker address and the
        // upper 248 bits of the order nonce. We define `nonceRange` to be
        // these 248 bits.
        uint248 nonceRange = uint248((nonce >> 8) & ORDER_NONCE_MASK);

        // The bitvector is indexed by the lower 8 bits of the nonce.
        uint256 flag = 1 << (nonce & 255);

        // Update order status bit vector to indicate that the given order
        // has been cancelled/filled by setting the designated bit to 1.
        LibERC721OrdersStorage.getStorage().orderStatusByMaker[maker][nonceRange] |= flag;
    }

    function _validateOrderSignature(
        bytes32 hash,
        address maker,
        LibSignature.SignatureType signatureType,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        if (
            signatureType == LibSignature.SignatureType.EIP712 ||
            signatureType == LibSignature.SignatureType.EIP712_BULK
        ) {
            require(maker == ecrecover(hash, v, r, s), "INVALID_SIGNATURE");
        } else if (
            signatureType == LibSignature.SignatureType.EIP712_1271 ||
            signatureType == LibSignature.SignatureType.EIP712_BULK_1271
        ) {
            assembly {
                let ptr := mload(0x40) // free memory pointer

                // selector for `isValidSignature(bytes32,bytes)`
                mstore(ptr, 0x1626ba7e)
                mstore(add(ptr, 0x20), hash)
                mstore(add(ptr, 0x40), 0x40)
                mstore(add(ptr, 0x60), 0x41)
                mstore(add(ptr, 0x80), r)
                mstore(add(ptr, 0xa0), s)
                mstore(add(ptr, 0xc0), shl(248, v))

                if iszero(extcodesize(maker)) {
                    _revertInvalidSigner()
                }

                // Call signer with `isValidSignature` to validate signature.
                if iszero(staticcall(gas(), maker, add(ptr, 0x1c), 0xa5, ptr, 0x20)) {
                    _revertInvalidSignature()
                }

                // Check for returnData.
                if iszero(eq(mload(ptr), 0x1626ba7e00000000000000000000000000000000000000000000000000000000)) {
                    _revertInvalidSignature()
                }

                function _revertInvalidSigner() {
                    // revert("INVALID_SIGNER")
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                    mstore(0x40, 0x0000000e494e56414c49445f5349474e45520000000000000000000000000000)
                    mstore(0x60, 0)
                    revert(0, 0x64)
                }

                function _revertInvalidSignature() {
                    // revert("INVALID_SIGNATURE")
                    mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                    mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                    mstore(0x40, 0x00000011494e56414c49445f5349474e41545552450000000000000000000000)
                    mstore(0x60, 0)
                    revert(0, 0x64)
                }
            }
        } else if (signatureType == LibSignature.SignatureType.PRESIGNED) {
            if (
                LibERC721OrdersStorage.getStorage().preSigned[hash] !=
                LibCommonNftOrdersStorage.getStorage().hashNonces[maker] + 1
            ) {
                revert("PRESIGNED_INVALID_SIGNER");
            }
        } else {
            revert("INVALID_SIGNATURE_TYPE");
        }
    }

    function _validateOrderProperties(
        LibNFTOrder.NFTBuyOrder memory order,
        bytes32 orderHash,
        uint256 tokenId,
        bytes memory data
    ) internal view {
        if (order.nftProperties.length == 0) {
            require(order.nftId == tokenId, "_validateProperties/TOKEN_ID_ERROR");
        } else {
            require(order.nftId == 0, "_validateProperties/TOKEN_ID_ERROR");
            for (uint256 i; i < order.nftProperties.length; ) {
                LibNFTOrder.Property memory property = order.nftProperties[i];
                if (address(property.propertyValidator) != address(0)) {
                    require(address(property.propertyValidator).code.length != 0, "INVALID_PROPERTY_VALIDATOR");

                    // Call the property validator and throw a descriptive error
                    // if the call reverts.
                    bytes4 result = property.propertyValidator.validateProperty(
                        order.nft, tokenId, orderHash, property.propertyData, data
                    );

                    // Check for the magic success bytes
                    require(result == PROPERTY_CALLBACK_MAGIC_BYTES, "PROPERTY_VALIDATION_FAILED");
                }
                unchecked { i++; }
            }
        }
    }

    function _getBulkValidateHashAndExtraData(
        bytes32 leaf, bytes memory takerData
    ) internal view returns(
        bytes32 validateHash, bytes memory data
    ) {
        uint256 proofsLength;
        bytes32 root = leaf;
        assembly {
            // takerData = 32bytes[length] + 32bytes[head] + [proofsData] + [data]
            let ptrHead := add(takerData, 0x20)

            // head = 4bytes[dataLength] + 1bytes[proofsLength] + 24bytes[unused] + 3bytes[proofsKey]
            let head := mload(ptrHead)
            let dataLength := shr(224, head)
            proofsLength := byte(4, head)
            let proofsKey := and(head, 0xffffff)

            // require(proofsLength != 0)
            if iszero(proofsLength) {
                _revertTakerDataError()
            }

            // require(32 + proofsLength * 32 + dataLength == takerData.length)
            if iszero(eq(add(0x20, add(shl(5, proofsLength), dataLength)), mload(takerData))) {
                _revertTakerDataError()
            }

            // Compute remaining proofs.
            let ptrAfterHead := add(ptrHead, 0x20)
            let ptrProofNode := ptrAfterHead

            for { let i } lt(i, proofsLength) { i := add(i, 1) } {
                // Check if the current bit of the key is set.
                switch and(shr(i, proofsKey), 0x1)
                case 0 {
                    mstore(ptrHead, root)
                    mstore(ptrAfterHead, mload(ptrProofNode))
                }
                case 1 {
                    mstore(ptrHead, mload(ptrProofNode))
                    mstore(ptrAfterHead, root)
                }

                root := keccak256(ptrHead, 0x40)
                ptrProofNode := add(ptrProofNode, 0x20)
            }

            data := sub(ptrProofNode, 0x20)
            mstore(data, dataLength)

            function _revertTakerDataError() {
                // revert("TakerData error")
                mstore(0, 0x08c379a000000000000000000000000000000000000000000000000000000000)
                mstore(0x20, 0x0000002000000000000000000000000000000000000000000000000000000000)
                mstore(0x40, 0x0000000f54616b657244617461206572726f7200000000000000000000000000)
                mstore(0x60, 0)
                revert(0, 0x64)
            }
        }

        bytes32 typeHash = LibTypeHash.getBulkERC721BuyOrderTypeHash(proofsLength);
        validateHash = _getEIP712Hash(keccak256(abi.encode(typeHash, root)));
        return (validateHash, data);
    }

    function _payFees(SellOrderInfo memory info, address payer, bool useNativeToken) internal {
        if (useNativeToken) {
            if (info.platformFeeAmount != 0) {
                _transferEth(payable(info.platformFeeRecipient), info.platformFeeAmount);
            }
            if (info.royaltyFeeAmount != 0) {
                _transferEth(payable(info.royaltyFeeRecipient), info.royaltyFeeAmount);
            }
        } else {
            if (info.platformFeeAmount != 0) {
                _transferERC20TokensFrom(info.erc20Token, payer, info.platformFeeRecipient, info.platformFeeAmount);
            }
            if (info.royaltyFeeAmount != 0) {
                _transferERC20TokensFrom(info.erc20Token, payer, info.royaltyFeeRecipient, info.royaltyFeeAmount);
            }
        }
    }

    function _payFees(LibNFTOrder.NFTBuyOrder memory order) internal {
        for (uint256 i; i < order.fees.length; ) {
            LibNFTOrder.Fee memory fee = order.fees[i];

            // Transfer ERC20 token from payer to recipient.
            _transferERC20TokensFrom(address(order.erc20Token), order.maker, fee.recipient, fee.amount);

            if (fee.feeData.length > 0) {
                require(fee.recipient.code.length != 0, "_payFees/INVALID_FEE_RECIPIENT");

                // Invoke the callback
                bytes4 callbackResult = IFeeRecipient(fee.recipient).receiveZeroExFeeCallback(
                    address(order.erc20Token),
                    fee.amount,
                    fee.feeData
                );

                // Check for the magic success bytes
                require(callbackResult == FEE_CALLBACK_MAGIC_BYTES, "_payFees/CALLBACK_FAILED");
            }

            unchecked { i++; }
        }
    }

    function _emitEventSellOrderFilled(SellOrderInfo memory info, address taker) internal {
        emit ERC721SellOrderFilled(
            info.orderHash,
            info.maker,
            taker,
            info.nonce,
            IERC20(info.erc20Token),
            info.erc20TokenAmount,
            _getFees(info),
            info.erc721Token,
            info.erc721TokenID
        );
    }

    function _getFees(SellOrderInfo memory info) internal pure returns(LibStructure.Fee[] memory fees) {
        if (info.platformFeeRecipient != address(0)) {
            if (info.royaltyFeeRecipient != address(0)) {
                fees = new LibStructure.Fee[](2);
                fees[1].recipient = info.royaltyFeeRecipient;
                fees[1].amount = info.royaltyFeeAmount;
            } else {
                fees = new LibStructure.Fee[](1);
            }
            fees[0].recipient = info.platformFeeRecipient;
            fees[0].amount = info.platformFeeAmount;
        } else {
            if (info.royaltyFeeRecipient != address(0)) {
                fees = new LibStructure.Fee[](1);
                fees[0].recipient = info.royaltyFeeRecipient;
                fees[0].amount = info.royaltyFeeAmount;
            } else {
                fees = new LibStructure.Fee[](0);
            }
        }
    }

    function _emitEventBuyOrderFilled(
        LibNFTOrder.NFTBuyOrder memory order,
        address taker,
        uint256 nftId,
        bytes32 orderHash
    ) internal {
        LibNFTOrder.Fee[] memory list = order.fees;
        LibStructure.Fee[] memory fees = new LibStructure.Fee[](list.length);
        for (uint256 i; i < fees.length; ) {
            fees[i].recipient = list[i].recipient;
            fees[i].amount = list[i].amount;
            order.erc20TokenAmount += list[i].amount;
            unchecked { ++i; }
        }

        emit ERC721BuyOrderFilled(
            orderHash,
            order.maker,
            taker,
            order.nonce,
            order.erc20Token,
            order.erc20TokenAmount,
            fees,
            order.nft,
            nftId
        );
    }
}
