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

import "./features/interfaces/IOwnableFeature.sol";
import "./features/interfaces/ISimpleFunctionRegistryFeature.sol";
import "./storage/LibProxyStorage.sol";
import "./storage/LibSimpleFunctionRegistryStorage.sol";
import "./storage/LibOwnableStorage.sol";

/// @dev An extensible proxy contract that serves as a universal entry point for
///      interacting with the 0x protocol.
contract ElementEx {

    constructor(address registryFeature, address ownableFeature) {
        // Initialize RegistryFeature.
        _extend(ISimpleFunctionRegistryFeature.registerMethods.selector, registryFeature);
        _extend(ISimpleFunctionRegistryFeature.extend.selector, registryFeature);
        _extend(ISimpleFunctionRegistryFeature.rollback.selector, registryFeature);
        _extend(ISimpleFunctionRegistryFeature.getRollbackLength.selector, registryFeature);
        _extend(ISimpleFunctionRegistryFeature.getRollbackEntryAtIndex.selector, registryFeature);

        // Initialize OwnableFeature.
        _extend(IOwnableFeature.transferOwnership.selector, ownableFeature);
        _extend(IOwnableFeature.owner.selector, ownableFeature);

        // Transfer ownership to the real owner.
        LibOwnableStorage.getStorage().owner = msg.sender;
    }

    /// @dev Forwards calls to the appropriate implementation contract.
    fallback() external payable {
        address impl = LibProxyStorage.getStorage().impls[msg.sig];
        assembly {
            if impl {
                calldatacopy(0, 0, calldatasize())
                if delegatecall(gas(), impl, 0, calldatasize(), 0, 0) {
                // Success, copy the returned data and return.
                    returndatacopy(0, 0, returndatasize())
                    return(0, returndatasize())
                }

            // Failed, copy the returned data and revert.
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        revert("METHOD_NOT_IMPLEMENTED");
    }

    /// @dev Fallback for just receiving ether.
    receive() external payable {}

    /// @dev Get the implementation contract of a registered function.
    /// @param selector The function selector.
    /// @return impl The implementation contract address.
    function getFunctionImplementation(bytes4 selector) public view returns (address impl) {
        return LibProxyStorage.getStorage().impls[selector];
    }

    event ProxyFunctionUpdated(bytes4 indexed selector, address oldImpl, address newImpl);

    function _extend(bytes4 selector, address impl) private {
        LibSimpleFunctionRegistryStorage.Storage storage stor = LibSimpleFunctionRegistryStorage.getStorage();
        LibProxyStorage.Storage storage proxyStor = LibProxyStorage.getStorage();

        address oldImpl = proxyStor.impls[selector];
        address[] storage history = stor.implHistory[selector];
        history.push(oldImpl);
        proxyStor.impls[selector] = impl;
        emit ProxyFunctionUpdated(selector, oldImpl, impl);
    }
}
