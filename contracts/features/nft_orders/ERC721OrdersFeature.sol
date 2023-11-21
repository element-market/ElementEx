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

import "../../fixins/FixinERC721Spender.sol";
import "../../storage/LibCommonNftOrdersStorage.sol";
import "../../storage/LibERC721OrdersStorage.sol";
import "../interfaces/IERC721OrdersFeature.sol";
import "../libs/LibTypeHash.sol";
import "../libs/LibMultiCall.sol";
import "./NFTOrders.sol";


/// @dev Feature for interacting with ERC721 orders.
contract ERC721OrdersFeature is IERC721OrdersFeature, FixinERC721Spender, NFTOrders {

    using LibNFTOrder for LibNFTOrder.NFTBuyOrder;

    /// @dev The magic return value indicating the success of a `onERC721Received`.
    bytes4 private constant ERC721_RECEIVED_MAGIC_BYTES = this.onERC721Received.selector;
    bytes4 private constant SELL_ERC721_SELECTOR = this.sellERC721.selector;

    uint256 private constant ORDER_NONCE_MASK = (1 << 184) - 1;

    constructor(IEtherToken weth) NFTOrders(weth) {
    }

    /// @dev Sells an ERC721 asset to fill the given order.
    /// @param buyOrder The ERC721 buy order.
    /// @param signature The order signature from the maker.
    /// @param erc721TokenId The ID of the ERC721 asset being
    ///        sold. If the given order specifies properties,
    ///        the asset must satisfy those properties. Otherwise,
    ///        it must equal the tokenId in the order.
    /// @param unwrapNativeToken If this parameter is true and the
    ///        ERC20 token of the order is e.g. WETH, unwraps the
    ///        token before transferring it to the taker.
    function sellERC721(
        LibNFTOrder.NFTBuyOrder memory buyOrder,
        LibSignature.Signature memory signature,
        uint256 erc721TokenId,
        bool unwrapNativeToken,
        bytes memory takerData
    ) external override {
        _sellERC721(buyOrder, signature, erc721TokenId, unwrapNativeToken, msg.sender, msg.sender, takerData);
    }

    function batchSellERC721s(bytes[] calldata datas, bool revertIfIncomplete) external override {
        LibMultiCall._multiCall(_implementation, SELL_ERC721_SELECTOR, datas, revertIfIncomplete);
    }

    function buyERC721Ex(
        LibNFTOrder.NFTSellOrder memory sellOrder,
        LibSignature.Signature memory signature,
        address taker,
        bytes memory takerData
    ) external override payable {
        uint256 ethBalanceBefore = address(this).balance - msg.value;

        _buyERC721(sellOrder, signature, taker, takerData);

        if (address(this).balance != ethBalanceBefore) {
            // Refund
            _transferEth(payable(msg.sender), address(this).balance - ethBalanceBefore);
        }
    }

    /// @dev Cancel a single ERC721 order by its nonce. The caller
    ///      should be the maker of the order. Silently succeeds if
    ///      an order with the same nonce has already been filled or
    ///      cancelled.
    /// @param orderNonce The order nonce.
    function cancelERC721Order(uint256 orderNonce) public override {
        // Mark order as cancelled
        _setOrderStatusBit(msg.sender, orderNonce);
        emit ERC721OrderCancelled(msg.sender, orderNonce);
    }

    /// @dev Cancel multiple ERC721 orders by their nonces. The caller
    ///      should be the maker of the orders. Silently succeeds if
    ///      an order with the same nonce has already been filled or
    ///      cancelled.
    /// @param orderNonces The order nonces.
    function batchCancelERC721Orders(uint256[] calldata orderNonces) external override {
        for (uint256 i = 0; i < orderNonces.length; i++) {
            cancelERC721Order(orderNonces[i]);
        }
    }

    function batchBuyERC721sEx(
        LibNFTOrder.NFTSellOrder[] memory sellOrders,
        LibSignature.Signature[] memory signatures,
        address[] calldata takers,
        bytes[] memory takerDatas,
        bool revertIfIncomplete
    ) external override payable returns (bool[] memory successes) {
        // All array length must match.
        uint256 length = sellOrders.length;
        require(
            length == signatures.length &&
            length == takers.length &&
            length == takerDatas.length,
            "ARRAY_LENGTH_MISMATCH"
        );

        successes = new bool[](length);
        uint256 ethBalanceBefore = address(this).balance - msg.value;

        bool someSuccess = false;
        if (revertIfIncomplete) {
            for (uint256 i; i < length; ) {
                // Will revert if _buyERC721 reverts.
                _buyERC721(sellOrders[i], signatures[i], takers[i], takerDatas[i]);
                successes[i] = true;
                someSuccess = true;
                unchecked { i++; }
            }
        } else {
            for (uint256 i; i < length; ) {
                // Delegatecall `buyERC721FromProxy` to swallow reverts while
                // preserving execution context.
                (successes[i], ) = _implementation.delegatecall(
                    abi.encodeWithSelector(
                        this.buyERC721FromProxy.selector,
                        sellOrders[i],
                        signatures[i],
                        takers[i],
                        takerDatas[i]
                    )
                );
                if (successes[i]) {
                    someSuccess = true;
                }
                unchecked { i++; }
            }
        }
        require(someSuccess, "batchBuyERC721sEx/NO_ORDER_FILLED");

        // Refund
        _transferEth(payable(msg.sender), address(this).balance - ethBalanceBefore);
    }

    // @Note `buyERC721FromProxy` is a external function, must call from an external Exchange Proxy,
    //        but should not be registered in the Exchange Proxy.
    function buyERC721FromProxy(
        LibNFTOrder.NFTSellOrder memory sellOrder,
        LibSignature.Signature memory signature,
        address taker,
        bytes memory takerData
    ) external payable {
        require(_implementation != address(this), "MUST_CALL_FROM_PROXY");
        _buyERC721(sellOrder, signature, taker, takerData);
    }

    /// @dev Matches a pair of complementary orders that have
    ///      a non-negative spread. Each order is filled at
    ///      their respective price, and the matcher receives
    ///      a profit denominated in the ERC20 token.
    /// @param sellOrder Order selling an ERC721 asset.
    /// @param buyOrder Order buying an ERC721 asset.
    /// @param sellOrderSignature Signature for the sell order.
    /// @param buyOrderSignature Signature for the buy order.
    /// @return profit The amount of profit earned by the caller
    ///         of this function (denominated in the ERC20 token
    ///         of the matched orders).
    function matchERC721Order(
        LibNFTOrder.NFTSellOrder memory sellOrder,
        LibNFTOrder.NFTBuyOrder memory buyOrder,
        LibSignature.Signature memory sellOrderSignature,
        LibSignature.Signature memory buyOrderSignature,
        bytes memory sellTakerData,
        bytes memory buyTakerData
    ) external override returns (uint256 profit) {
        // The ERC721 tokens must match
        require(sellOrder.nft == buyOrder.nft, "ERC721_TOKEN_MISMATCH_ERROR");

        LibNFTOrder.OrderInfoV2 memory sellOrderInfo = _getOrderInfo(sellOrder);
        LibNFTOrder.OrderInfoV2 memory buyOrderInfo = _getOrderInfo(buyOrder);

        _validateSellOrder(sellOrder, sellOrderSignature, sellOrderInfo, buyOrder.maker, 1, sellTakerData);
        _validateBuyOrder(buyOrder, buyOrderSignature, buyOrderInfo, sellOrder.maker, sellOrder.nftId, 1, buyTakerData);

        // Reset buyOrder.erc20TokenAmount
        buyOrder.erc20TokenAmount = buyOrder.erc20TokenAmount / buyOrderInfo.orderAmount;

        // English Auction
        if (sellOrder.expiry >> 252 == LibStructure.ORDER_KIND_ENGLISH_AUCTION) {
            _resetEnglishAuctionERC20AmountAndFees(sellOrder, buyOrder.erc20TokenAmount, 1, 1);
        }

        // The difference in ERC20 token amounts is the spread.
        uint256 spread = buyOrder.erc20TokenAmount - sellOrder.erc20TokenAmount;

        // Transfer the ERC721 asset from seller to buyer.
        _transferERC721AssetFrom(sellOrder.nft, sellOrder.maker, buyOrder.maker, sellOrder.nftId);

        // Handle the ERC20 side of the order:
        if (address(sellOrder.erc20Token) == NATIVE_TOKEN_ADDRESS && buyOrder.erc20Token == WETH) {
            // The sell order specifies ETH, while the buy order specifies WETH.
            // The orders are still compatible with one another, but we'll have
            // to unwrap the WETH on behalf of the buyer.

            // Step 1: Transfer WETH from the buyer to the EP.
            //         Note that we transfer `buyOrder.erc20TokenAmount`, which
            //         is the amount the buyer signaled they are willing to pay
            //         for the ERC721 asset, which may be more than the seller's
            //         ask.
            _transferERC20TokensFrom(address(WETH), buyOrder.maker, address(this), buyOrder.erc20TokenAmount);

            // Step 2: Unwrap the WETH into ETH. We unwrap the entire
            //         `buyOrder.erc20TokenAmount`.
            //         The ETH will be used for three purposes:
            //         - To pay the seller
            //         - To pay fees for the sell order
            //         - Any remaining ETH will be sent to
            //           `msg.sender` as profit.
            WETH.withdraw(buyOrder.erc20TokenAmount);

            // Step 3: Pay the seller (in ETH).
            _transferEth(payable(sellOrder.maker), sellOrder.erc20TokenAmount);

            // Step 4: Pay fees for the buy order. Note that these are paid
            //         in _WETH_ by the _buyer_. By signing the buy order, the
            //         buyer signals that they are willing to spend a total
            //         of `erc20TokenAmount` _plus_ fees, all denominated in
            //         the `erc20Token`, which in this case is WETH.
            _payFees(buyOrder.asNFTSellOrder(), buyOrder.maker, 1, buyOrderInfo.orderAmount, false);

            // Step 5: Pay fees for the sell order. The `erc20Token` of the
            //         sell order is ETH, so the fees are paid out in ETH.
            //         There should be `spread` wei of ETH remaining in the
            //         EP at this point, which we will use ETH to pay the
            //         sell order fees.
            uint256 sellOrderFees = _payFees(sellOrder, address(this), 1, 1, true);

            // Step 6: The spread less the sell order fees is the amount of ETH
            //         remaining in the EP that can be sent to `msg.sender` as
            //         the profit from matching these two orders.
            profit = spread - sellOrderFees;
            if (profit > 0) {
                _transferEth(payable(msg.sender), profit);
            }
        } else {
            // ERC20 tokens must match
            require(sellOrder.erc20Token == buyOrder.erc20Token, "ERC20_TOKEN_MISMATCH_ERROR");

            // Step 1: Transfer the ERC20 token from the buyer to the seller.
            //         Note that we transfer `sellOrder.erc20TokenAmount`, which
            //         is at most `buyOrder.erc20TokenAmount`.
            _transferERC20TokensFrom(address(buyOrder.erc20Token), buyOrder.maker, sellOrder.maker, sellOrder.erc20TokenAmount);

            // Step 2: Pay fees for the buy order. Note that these are paid
            //         by the buyer. By signing the buy order, the buyer signals
            //         that they are willing to spend a total of
            //         `buyOrder.erc20TokenAmount` _plus_ `buyOrder.fees`.
            _payFees(buyOrder.asNFTSellOrder(), buyOrder.maker, 1, buyOrderInfo.orderAmount, false);

            // Step 3: Pay fees for the sell order. These are paid by the buyer
            //         as well. After paying these fees, we may have taken more
            //         from the buyer than they agreed to in the buy order. If
            //         so, we revert in the following step.
            uint256 sellOrderFees = _payFees(sellOrder, buyOrder.maker, 1, 1, false);

            // Step 4: We calculate the profit as:
            //         profit = buyOrder.erc20TokenAmount - sellOrder.erc20TokenAmount - sellOrderFees
            //                = spread - sellOrderFees
            //         I.e. the buyer would've been willing to pay up to `profit`
            //         more to buy the asset, so instead that amount is sent to
            //         `msg.sender` as the profit from matching these two orders.
            profit = spread - sellOrderFees;
            if (profit > 0) {
                _transferERC20TokensFrom(address(buyOrder.erc20Token), buyOrder.maker, msg.sender, profit);
            }
        }

        _emitEventSellOrderFilled(
            sellOrder,
            buyOrder.maker,
            sellOrderInfo.orderHash
        );

        _emitEventBuyOrderFilled(
            buyOrder,
            sellOrder.maker,
            sellOrder.nftId,
            buyOrderInfo.orderHash
        );
    }

    /// @dev Callback for the ERC721 `safeTransferFrom` function.
    ///      This callback can be used to sell an ERC721 asset if
    ///      a valid ERC721 order, signature and `unwrapNativeToken`
    ///      are encoded in `data`. This allows takers to sell their
    ///      ERC721 asset without first calling `setApprovalForAll`.
    /// @param operator The address which called `safeTransferFrom`.
    /// @param tokenId The ID of the asset being transferred.
    /// @param data Additional data with no specified format. If a
    ///        valid ERC721 order, signature and `unwrapNativeToken`
    ///        are encoded in `data`, this function will try to fill
    ///        the order using the received asset.
    /// @return success The selector of this function (0x150b7a02),
    ///         indicating that the callback succeeded.
    function onERC721Received(address operator, address /* from */, uint256 tokenId, bytes calldata data) external override returns (bytes4 success) {
        // Decode the order, signature, and `unwrapNativeToken` from
        // `data`. If `data` does not encode such parameters, this
        // will throw.
        (
            LibNFTOrder.NFTBuyOrder memory buyOrder,
            LibSignature.Signature memory signature,
            bool unwrapNativeToken,
            bytes memory takerData
        ) = abi.decode(data, (LibNFTOrder.NFTBuyOrder, LibSignature.Signature, bool, bytes));

        // `onERC721Received` is called by the ERC721 token contract.
        // Check that it matches the ERC721 token in the order.
        require(msg.sender == buyOrder.nft, "ERC721_TOKEN_MISMATCH_ERROR");

        // operator taker
        // address(this) owner (we hold the NFT currently)
        _sellERC721(buyOrder, signature, tokenId, unwrapNativeToken, operator, address(this), takerData);

        return ERC721_RECEIVED_MAGIC_BYTES;
    }

    /// @dev Approves an ERC721 sell order on-chain. After pre-signing
    ///      the order, the `PRESIGNED` signature type will become
    ///      valid for that order and signer.
    /// @param order An ERC721 sell order.
    function preSignERC721SellOrder(LibNFTOrder.NFTSellOrder memory order) external override {
        require(order.maker == msg.sender, "ONLY_MAKER");

        uint256 hashNonce = LibCommonNftOrdersStorage.getStorage().hashNonces[order.maker];
        bytes32 orderHash = getERC721SellOrderHash(order);
        LibERC721OrdersStorage.getStorage().preSigned[orderHash] = (hashNonce + 1);

        emit ERC721SellOrderPreSigned(order.maker, order.taker, order.expiry, order.nonce,
            order.erc20Token, order.erc20TokenAmount, order.fees, order.nft, order.nftId);
    }

    /// @dev Approves an ERC721 buy order on-chain. After pre-signing
    ///      the order, the `PRESIGNED` signature type will become
    ///      valid for that order and signer.
    /// @param order An ERC721 buy order.
    function preSignERC721BuyOrder(LibNFTOrder.NFTBuyOrder memory order) external override {
        require(order.maker == msg.sender, "ONLY_MAKER");

        uint256 hashNonce = LibCommonNftOrdersStorage.getStorage().hashNonces[order.maker];
        bytes32 orderHash = getERC721BuyOrderHash(order);
        LibERC721OrdersStorage.getStorage().preSigned[orderHash] = (hashNonce + 1);

        emit ERC721BuyOrderPreSigned(order.maker, order.taker, order.expiry, order.nonce,
            order.erc20Token, order.erc20TokenAmount, order.fees, order.nft, order.nftId, order.nftProperties);
    }

    // Core settlement logic for selling an ERC721 asset.
    // Used by `sellERC721` and `onERC721Received`.
    function _sellERC721(
        LibNFTOrder.NFTBuyOrder memory buyOrder,
        LibSignature.Signature memory signature,
        uint256 erc721TokenId,
        bool unwrapNativeToken,
        address taker,
        address currentNftOwner,
        bytes memory takerData
    ) internal {
        bytes32 orderHash;
        (buyOrder.erc20TokenAmount, orderHash) = _sellNFT(
            buyOrder,
            signature,
            SellParams(1, erc721TokenId, unwrapNativeToken, taker, currentNftOwner, takerData)
        );

        _emitEventBuyOrderFilled(
            buyOrder,
            taker,
            erc721TokenId,
            orderHash
        );
    }

    // Core settlement logic for buying an ERC721 asset.
    function _buyERC721(
        LibNFTOrder.NFTSellOrder memory sellOrder,
        LibSignature.Signature memory signature,
        address taker,
        bytes memory takerData
    ) internal {
        require(taker != address(this), "_buyERC721/TAKER_CANNOT_SELF");
        if (taker == address(0)) {
            taker = msg.sender;
        }

        bytes32 orderHash;
        (sellOrder.erc20TokenAmount, orderHash) = _buyNFT(sellOrder, signature, 1, taker, takerData);
        _emitEventSellOrderFilled(
            sellOrder,
            taker,
            orderHash
        );
    }

    function _emitEventSellOrderFilled(
        LibNFTOrder.NFTSellOrder memory sellOrder,
        address taker,
        bytes32 orderHash
    ) internal {
        LibStructure.Fee[] memory fees = new LibStructure.Fee[](sellOrder.fees.length);
        for (uint256 i; i < fees.length; ) {
            fees[i].recipient = sellOrder.fees[i].recipient;
            fees[i].amount = sellOrder.fees[i].amount;
            sellOrder.erc20TokenAmount += fees[i].amount;
            unchecked { ++i; }
        }

        emit ERC721SellOrderFilled(
            orderHash,
            sellOrder.maker,
            taker,
            sellOrder.nonce,
            sellOrder.erc20Token,
            sellOrder.erc20TokenAmount,
            fees,
            sellOrder.nft,
            sellOrder.nftId
        );
    }

    function _emitEventBuyOrderFilled(
        LibNFTOrder.NFTBuyOrder memory buyOrder,
        address taker,
        uint256 nftId,
        bytes32 orderHash
    ) internal {
        uint256 orderAmount =
            (buyOrder.expiry >> 252 == LibStructure.ORDER_KIND_BATCH_OFFER_ERC721S) ?
            ((buyOrder.expiry >> 64) & 0xffffffff) : 1;

        LibStructure.Fee[] memory fees = new LibStructure.Fee[](buyOrder.fees.length);
        for (uint256 i; i < fees.length; ) {
            fees[i].recipient = buyOrder.fees[i].recipient;
            unchecked {
                fees[i].amount = buyOrder.fees[i].amount / orderAmount;
            }
            buyOrder.erc20TokenAmount += fees[i].amount;
            unchecked { ++i; }
        }

        emit ERC721BuyOrderFilled(
            orderHash,
            buyOrder.maker,
            taker,
            buyOrder.nonce,
            buyOrder.erc20Token,
            buyOrder.erc20TokenAmount,
            fees,
            buyOrder.nft,
            nftId
        );
    }

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 sell order. Reverts if not.
    /// @param order The ERC721 sell order.
    /// @param signature The signature to validate.
    function validateERC721SellOrderSignature(LibNFTOrder.NFTSellOrder memory order, LibSignature.Signature memory signature) external override view {
        _validateOrderSignature(getERC721SellOrderHash(order), signature, order.maker);
    }

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 sell order. Reverts if not.
    /// @param order The ERC721 sell order.
    /// @param signature The signature to validate.
    function validateERC721SellOrderSignature(
        LibNFTOrder.NFTSellOrder calldata order,
        LibSignature.Signature calldata signature,
        bytes calldata takerData
    ) external override view {
        if (
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK ||
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK_1271
        ) {
            (bytes32 hash, ) = _getBulkValidateHashAndExtraData(false, _getSellOrderStructHash(order), takerData);
            _validateOrderSignature(hash, signature, order.maker);
        } else {
            _validateOrderSignature(getERC721SellOrderHash(order), signature, order.maker);
        }
    }

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 buy order. Reverts if not.
    /// @param order The ERC721 buy order.
    /// @param signature The signature to validate.
    function validateERC721BuyOrderSignature(
        LibNFTOrder.NFTBuyOrder memory order,
        LibSignature.Signature memory signature
    ) external override view {
        _validateOrderSignature(getERC721BuyOrderHash(order), signature, order.maker);
    }

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 buy order. Reverts if not.
    /// @param order The ERC721 buy order.
    /// @param signature The signature to validate.
    function validateERC721BuyOrderSignature(
        LibNFTOrder.NFTBuyOrder memory order,
        LibSignature.Signature memory signature,
        bytes memory takerData
    ) external override view {
        if (
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK ||
            signature.signatureType == LibSignature.SignatureType.EIP712_BULK_1271
        ) {
            (bytes32 hash, ) = _getBulkValidateHashAndExtraData(true, _getBuyOrderStructHash(order), takerData);
            _validateOrderSignature(hash, signature, order.maker);
        } else {
            _validateOrderSignature(getERC721BuyOrderHash(order), signature, order.maker);
        }
    }

    function _isOrderPreSigned(bytes32 orderHash, address maker) internal override view returns(bool) {
        return LibERC721OrdersStorage.getStorage().preSigned[orderHash] ==
        LibCommonNftOrdersStorage.getStorage().hashNonces[maker] + 1;
    }

    /// @dev Transfers an NFT asset.
    /// @param token The address of the NFT contract.
    /// @param from The address currently holding the asset.
    /// @param to The address to transfer the asset to.
    /// @param tokenId The ID of the asset to transfer.
    function _transferNFTAssetFrom(address token, address from, address to, uint256 tokenId, uint256 /* amount */) internal override {
        _transferERC721AssetFrom(token, from, to, tokenId);
    }

    /// @dev Updates storage to indicate that the given order
    ///      has been filled by the given amount.
    /// @param order The order that has been filled.
    function _updateOrderState(LibNFTOrder.NFTSellOrder memory order, bytes32 /* orderHash */, uint128 /* fillAmount */) internal override {
        _setOrderStatusBit(order.maker, order.nonce);
    }

    /// @dev Updates storage to indicate that the given order
    ///      has been filled by the given amount.
    /// @param order The order that has been filled.
    function _updateOrderState(LibNFTOrder.NFTBuyOrder memory order, bytes32 orderHash, uint128 fillAmount) internal override {
        if (order.expiry >> 252 == LibStructure.ORDER_KIND_BATCH_OFFER_ERC721S) {
            LibERC721OrdersStorage.getStorage().filledAmount[orderHash] += fillAmount;
        } else {
            _setOrderStatusBit(order.maker, order.nonce);
        }
    }

    function _setOrderStatusBit(address maker, uint256 nonce) private {
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

    /// @dev Get the order info for an NFT sell order.
    /// @param order The NFT sell order.
    /// @return orderInfo Info about the order.
    function _getOrderInfo(LibNFTOrder.NFTSellOrder memory order) internal override view returns (LibNFTOrder.OrderInfoV2 memory orderInfo) {
        orderInfo.structHash = _getSellOrderStructHash(order);
        orderInfo.orderHash = _getEIP712Hash(orderInfo.structHash);
        orderInfo.orderAmount = 1;

        // Check if the order has been filled or cancelled.
        if (_isOrderFilledOrCancelled(order.maker, order.nonce)) {
            orderInfo.status = LibNFTOrder.OrderStatus.UNFILLABLE;
            return orderInfo;
        }

        // The `remainingAmount` should be set to 1 if the order is not filled.
        orderInfo.remainingAmount = 1;

        // Check for listingTime.
        if ((order.expiry >> 32) & 0xffffffff > block.timestamp) {
            orderInfo.status = LibNFTOrder.OrderStatus.INVALID;
            return orderInfo;
        }

        // Check for expiryTime.
        if (order.expiry & 0xffffffff <= block.timestamp) {
            orderInfo.status = LibNFTOrder.OrderStatus.EXPIRED;
            return orderInfo;
        }

        orderInfo.status = LibNFTOrder.OrderStatus.FILLABLE;
        return orderInfo;
    }

    /// @dev Get the order info for an NFT buy order.
    /// @param order The NFT buy order.
    /// @return orderInfo Info about the order.
    function _getOrderInfo(LibNFTOrder.NFTBuyOrder memory order) internal override view returns (LibNFTOrder.OrderInfoV2 memory orderInfo) {
        orderInfo.structHash = _getBuyOrderStructHash(order);
        orderInfo.orderHash = _getEIP712Hash(orderInfo.structHash);

        if (order.expiry >> 252 == LibStructure.ORDER_KIND_BATCH_OFFER_ERC721S) {
            orderInfo.orderAmount = uint128((order.expiry >> 64) & 0xffffffff);
            orderInfo.remainingAmount = orderInfo.orderAmount - LibERC721OrdersStorage.getStorage().filledAmount[orderInfo.orderHash];

            // Check if the order has been filled or cancelled.
            if (orderInfo.remainingAmount == 0 || _isOrderFilledOrCancelled(order.maker, order.nonce)) {
                orderInfo.status = LibNFTOrder.OrderStatus.UNFILLABLE;
                return orderInfo;
            }

            // Sell multiple nfts requires `nftId` == 0 and `nftProperties.length` > 0.
            if (order.nftId != 0 || order.nftProperties.length == 0) {
                orderInfo.status = LibNFTOrder.OrderStatus.INVALID;
                return orderInfo;
            }
        } else {
            orderInfo.orderAmount = 1;

            // Check if the order has been filled or cancelled.
            if (_isOrderFilledOrCancelled(order.maker, order.nonce)) {
                orderInfo.status = LibNFTOrder.OrderStatus.UNFILLABLE;
                return orderInfo;
            }

            // The `remainingAmount` should be set to 1 if the order is not filled.
            orderInfo.remainingAmount = 1;

            // Only buy orders with `nftId` == 0 can be propertyorders.
            if (order.nftProperties.length > 0 && order.nftId != 0) {
                orderInfo.status = LibNFTOrder.OrderStatus.INVALID;
                return orderInfo;
            }
        }

        // Buy orders cannot use ETH as the ERC20 token
        if (address(order.erc20Token) == NATIVE_TOKEN_ADDRESS) {
            orderInfo.status = LibNFTOrder.OrderStatus.INVALID;
            return orderInfo;
        }

        // Check for listingTime.
        if ((order.expiry >> 32) & 0xffffffff > block.timestamp) {
            orderInfo.status = LibNFTOrder.OrderStatus.INVALID;
            return orderInfo;
        }

        // Check for expiryTime.
        if (order.expiry & 0xffffffff <= block.timestamp) {
            orderInfo.status = LibNFTOrder.OrderStatus.EXPIRED;
            return orderInfo;
        }

        orderInfo.status = LibNFTOrder.OrderStatus.FILLABLE;
        return orderInfo;
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

    function _getBuyOrderStructHash(LibNFTOrder.NFTBuyOrder memory order) internal view returns(bytes32) {
        return LibNFTOrder.getNFTBuyOrderStructHash(
            order, LibCommonNftOrdersStorage.getStorage().hashNonces[order.maker]
        );
    }

    function _getSellOrderStructHash(LibNFTOrder.NFTSellOrder memory order) internal view returns(bytes32) {
        return LibNFTOrder.getNFTSellOrderStructHash(
            order, LibCommonNftOrdersStorage.getStorage().hashNonces[order.maker]
        );
    }

    function _getBulkBuyOrderTypeHash(uint256 height) internal override pure returns (bytes32) {
        return LibTypeHash.getBulkERC721BuyOrderTypeHash(height);
    }

    function _getBulkSellOrderTypeHash(uint256 height) internal override pure returns (bytes32) {
        return LibTypeHash.getBulkERC721SellOrderTypeHash(height);
    }

    /// @dev Get the EIP-712 hash of an ERC721 sell order.
    /// @param order The ERC721 sell order.
    /// @return orderHash The order hash.
    function getERC721SellOrderHash(LibNFTOrder.NFTSellOrder memory order) public override view returns (bytes32) {
        return _getEIP712Hash(_getSellOrderStructHash(order));
    }

    /// @dev Get the EIP-712 hash of an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return orderHash The order hash.
    function getERC721BuyOrderHash(LibNFTOrder.NFTBuyOrder memory order) public override view returns (bytes32) {
        return _getEIP712Hash(_getBuyOrderStructHash(order));
    }

    /// @dev Get the current status of an ERC721 sell order.
    /// @param order The ERC721 sell order.
    /// @return status The status of the order.
    function getERC721SellOrderStatus(LibNFTOrder.NFTSellOrder memory order) external override view returns (LibNFTOrder.OrderStatus) {
        return _getOrderInfo(order).status;
    }

    /// @dev Get the current status of an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return status The status of the order.
    function getERC721BuyOrderStatus(LibNFTOrder.NFTBuyOrder memory order) external override view returns (LibNFTOrder.OrderStatus) {
        return _getOrderInfo(order).status;
    }

    /// @dev Get the order info for an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return orderInfo Infor about the order.
    function getERC721BuyOrderInfo(LibNFTOrder.NFTBuyOrder memory order) external view returns (LibNFTOrder.OrderInfo memory orderInfo) {
        LibNFTOrder.OrderInfoV2 memory info = _getOrderInfo(order);
        orderInfo.status = info.status;
        orderInfo.remainingAmount = info.remainingAmount;
        orderInfo.orderAmount = info.orderAmount;
        orderInfo.orderHash = info.orderHash;
        return orderInfo;
    }

    /// @dev Get the order status bit vector for the given
    ///      maker address and nonce range.
    /// @param maker The maker of the order.
    /// @param nonceRange Order status bit vectors are indexed
    ///        by maker address and the upper 248 bits of the
    ///        order nonce. We define `nonceRange` to be these
    ///        248 bits.
    /// @return bitVector The order status bit vector for the
    ///         given maker and nonce range.
    function getERC721OrderStatusBitVector(address maker, uint248 nonceRange) external override view returns (uint256) {
        uint248 range = uint248(nonceRange & ORDER_NONCE_MASK);
        return LibERC721OrdersStorage.getStorage().orderStatusByMaker[maker][range];
    }

    function getHashNonce(address maker) external override view returns (uint256) {
        return LibCommonNftOrdersStorage.getStorage().hashNonces[maker];
    }

    /// Increment a particular maker's nonce, thereby invalidating all orders that were not signed
    /// with the original nonce.
    function incrementHashNonce() external override {
        uint256 newHashNonce = ++LibCommonNftOrdersStorage.getStorage().hashNonces[msg.sender];
        emit HashNonceIncremented(msg.sender, newHashNonce);
    }
}
