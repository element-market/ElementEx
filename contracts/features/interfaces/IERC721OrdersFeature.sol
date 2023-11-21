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
import "../libs/LibSignature.sol";
import "../libs/LibStructure.sol";
import "./IERC721OrdersEvent.sol";


/// @dev Feature for interacting with ERC721 orders.
interface IERC721OrdersFeature is IERC721OrdersEvent {

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
        LibNFTOrder.NFTBuyOrder calldata buyOrder,
        LibSignature.Signature calldata signature,
        uint256 erc721TokenId,
        bool unwrapNativeToken,
        bytes calldata takerData
    ) external;

    /// @dev Sells multiple ERC721 assets by filling the
    ///      given orders.
    /// @param datas The encoded `sellERC721` calldatas.
    /// @param revertIfIncomplete If true, reverts if this
    ///        function fails to fill any individual order.
    function batchSellERC721s(bytes[] calldata datas, bool revertIfIncomplete) external;

    /// @dev Buys an ERC721 asset by filling the given order.
    /// @param sellOrder The ERC721 sell order.
    /// @param signature The order signature.
    /// @param taker The address to receive ERC721. If this parameter
    ///         is zero, transfer ERC721 to `msg.sender`.
    function buyERC721Ex(
        LibNFTOrder.NFTSellOrder calldata sellOrder,
        LibSignature.Signature calldata signature,
        address taker,
        bytes calldata takerData
    ) external payable;

    /// @dev Cancel a single ERC721 order by its nonce. The caller
    ///      should be the maker of the order. Silently succeeds if
    ///      an order with the same nonce has already been filled or
    ///      cancelled.
    /// @param orderNonce The order nonce.
    function cancelERC721Order(uint256 orderNonce) external;

    /// @dev Cancel multiple ERC721 orders by their nonces. The caller
    ///      should be the maker of the orders. Silently succeeds if
    ///      an order with the same nonce has already been filled or
    ///      cancelled.
    /// @param orderNonces The order nonces.
    function batchCancelERC721Orders(uint256[] calldata orderNonces) external;

    /// @dev Buys multiple ERC721 assets by filling the
    ///      given orders.
    /// @param sellOrders The ERC721 sell orders.
    /// @param signatures The order signatures.
    /// @param takers The address to receive ERC721.
    /// @param takerDatas The data (if any) to pass to the taker
    ///        callback for each order. Refer to the `takerData`
    ///        parameter to for `buyERC721`.
    /// @param revertIfIncomplete If true, reverts if this
    ///        function fails to fill any individual order.
    /// @return successes An array of booleans corresponding to whether
    ///         each order in `orders` was successfully filled.
    function batchBuyERC721sEx(
        LibNFTOrder.NFTSellOrder[] calldata sellOrders,
        LibSignature.Signature[] calldata signatures,
        address[] calldata takers,
        bytes[] calldata takerDatas,
        bool revertIfIncomplete
    ) external payable returns (bool[] memory successes);

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
        LibNFTOrder.NFTSellOrder calldata sellOrder,
        LibNFTOrder.NFTBuyOrder calldata buyOrder,
        LibSignature.Signature calldata sellOrderSignature,
        LibSignature.Signature calldata buyOrderSignature,
        bytes calldata sellTakerData,
        bytes calldata buyTakerData
    ) external returns (uint256 profit);

    /// @dev Callback for the ERC721 `safeTransferFrom` function.
    ///      This callback can be used to sell an ERC721 asset if
    ///      a valid ERC721 order, signature and `unwrapNativeToken`
    ///      are encoded in `data`. This allows takers to sell their
    ///      ERC721 asset without first calling `setApprovalForAll`.
    /// @param operator The address which called `safeTransferFrom`.
    /// @param from The address which previously owned the token.
    /// @param tokenId The ID of the asset being transferred.
    /// @param data Additional data with no specified format. If a
    ///        valid ERC721 order, signature and `unwrapNativeToken`
    ///        are encoded in `data`, this function will try to fill
    ///        the order using the received asset.
    /// @return success The selector of this function (0x150b7a02),
    ///         indicating that the callback succeeded.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4 success);

    /// @dev Approves an ERC721 sell order on-chain. After pre-signing
    ///      the order, the `PRESIGNED` signature type will become
    ///      valid for that order and signer.
    /// @param order An ERC721 sell order.
    function preSignERC721SellOrder(LibNFTOrder.NFTSellOrder calldata order) external;

    /// @dev Approves an ERC721 buy order on-chain. After pre-signing
    ///      the order, the `PRESIGNED` signature type will become
    ///      valid for that order and signer.
    /// @param order An ERC721 buy order.
    function preSignERC721BuyOrder(LibNFTOrder.NFTBuyOrder calldata order) external;

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 sell order. Reverts if not.
    /// @param order The ERC721 sell order.
    /// @param signature The signature to validate.
    function validateERC721SellOrderSignature(
        LibNFTOrder.NFTSellOrder calldata order,
        LibSignature.Signature calldata signature
    ) external view;

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 sell order. Reverts if not.
    /// @param order The ERC721 sell order.
    /// @param signature The signature to validate.
    function validateERC721SellOrderSignature(
        LibNFTOrder.NFTSellOrder calldata order,
        LibSignature.Signature calldata signature,
        bytes calldata takerData
    ) external view;

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 buy order. Reverts if not.
    /// @param order The ERC721 buy order.
    /// @param signature The signature to validate.
    function validateERC721BuyOrderSignature(
        LibNFTOrder.NFTBuyOrder calldata order,
        LibSignature.Signature calldata signature
    ) external view;

    /// @dev Checks whether the given signature is valid for the
    ///      the given ERC721 buy order. Reverts if not.
    /// @param order The ERC721 buy order.
    /// @param signature The signature to validate.
    function validateERC721BuyOrderSignature(
        LibNFTOrder.NFTBuyOrder calldata order,
        LibSignature.Signature calldata signature,
        bytes calldata takerData
    ) external view;

    /// @dev Get the current status of an ERC721 sell order.
    /// @param order The ERC721 sell order.
    /// @return status The status of the order.
    function getERC721SellOrderStatus(
        LibNFTOrder.NFTSellOrder calldata order
    ) external view returns (LibNFTOrder.OrderStatus);

    /// @dev Get the current status of an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return status The status of the order.
    function getERC721BuyOrderStatus(
        LibNFTOrder.NFTBuyOrder calldata order
    ) external view returns (LibNFTOrder.OrderStatus);

    /// @dev Get the order info for an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return orderInfo Infor about the order.
    function getERC721BuyOrderInfo(
        LibNFTOrder.NFTBuyOrder calldata order
    ) external view returns (LibNFTOrder.OrderInfo memory);

    /// @dev Get the EIP-712 hash of an ERC721 sell order.
    /// @param order The ERC721 sell order.
    /// @return orderHash The order hash.
    function getERC721SellOrderHash(
        LibNFTOrder.NFTSellOrder calldata order
    ) external view returns (bytes32);

    /// @dev Get the EIP-712 hash of an ERC721 buy order.
    /// @param order The ERC721 buy order.
    /// @return orderHash The order hash.
    function getERC721BuyOrderHash(
        LibNFTOrder.NFTBuyOrder calldata order
    ) external view returns (bytes32);

    /// @dev Get the order status bit vector for the given
    ///      maker address and nonce range.
    /// @param maker The maker of the order.
    /// @param nonceRange Order status bit vectors are indexed
    ///        by maker address and the upper 248 bits of the
    ///        order nonce. We define `nonceRange` to be these
    ///        248 bits.
    /// @return bitVector The order status bit vector for the
    ///         given maker and nonce range.
    function getERC721OrderStatusBitVector(address maker, uint248 nonceRange) external view returns (uint256);

    function getHashNonce(address maker) external view returns (uint256);

    /// Increment a particular maker's nonce, thereby invalidating all orders that were not signed
    /// with the original nonce.
    function incrementHashNonce() external;
}
