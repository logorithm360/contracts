// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IChainRegistry} from "./interfaces/IChainRegistry.sol";

/// @title ChainRegistry
/// @notice Canonical on-chain source of chain/lane/token/service routing configuration.
contract ChainRegistry is Ownable, IChainRegistry {
    error ZeroSelector();
    error ZeroChainId();
    error ZeroAddress();
    error InvalidMode();
    error UnknownChain(uint64 selector);
    error UnknownLane(uint64 sourceSelector, uint64 destinationSelector);
    error UnknownLaneToken(uint64 sourceSelector, uint64 destinationSelector, address sourceToken);
    error UnknownService(uint64 chainSelector, bytes32 serviceKey);
    error SelectorAlreadyMapped(uint64 selector, uint256 existingChainId);
    error ChainIdAlreadyMapped(uint256 chainId, uint64 existingSelector);

    event ChainUpserted(uint64 indexed selector, uint256 indexed chainId, bool isActive, bool isTestnet);
    event ChainActivationUpdated(uint64 indexed selector, bool isActive);

    event LaneUpdated(
        uint64 indexed sourceSelector, uint64 indexed destinationSelector, bool isActive, uint8 feeTokenMode
    );
    event LaneActivationUpdated(uint64 indexed sourceSelector, uint64 indexed destinationSelector, bool isActive);

    event LaneTokenUpdated(
        uint64 indexed sourceSelector,
        uint64 indexed destinationSelector,
        address indexed sourceToken,
        address destinationToken,
        uint8 decimals,
        bytes32 symbolHash,
        bool isActive
    );
    event LaneTokenActivationUpdated(
        uint64 indexed sourceSelector, uint64 indexed destinationSelector, address indexed sourceToken, bool isActive
    );

    event ServiceBindingUpdated(
        uint64 indexed chainSelector, bytes32 indexed serviceKey, address indexed contractAddress, bool isActive
    );
    event ServiceActivationUpdated(uint64 indexed chainSelector, bytes32 indexed serviceKey, bool isActive);

    mapping(uint64 => ChainRecord) private s_chainBySelector;
    mapping(uint64 => bool) private s_chainExists;
    mapping(uint256 => uint64) private s_selectorByChainId;

    mapping(bytes32 => LaneRecord) private s_laneByKey;
    mapping(bytes32 => bool) private s_laneExists;

    mapping(bytes32 => LaneTokenRecord) private s_laneTokenByKey;
    mapping(bytes32 => bool) private s_laneTokenExists;

    mapping(bytes32 => ServiceBinding) private s_serviceBindingByKey;
    mapping(bytes32 => bool) private s_serviceBindingExists;

    uint64[] private s_allChainSelectors;
    bytes32[] private s_laneKeys;
    bytes32[] private s_laneTokenKeys;
    bytes32[] private s_serviceBindingKeys;

    constructor() Ownable(msg.sender) {}

    function isChainSupported(uint64 selector) external view returns (bool) {
        return _isChainSupported(selector);
    }

    function getChainBySelector(uint64 selector) external view returns (ChainRecord memory) {
        if (!s_chainExists[selector]) revert UnknownChain(selector);
        return s_chainBySelector[selector];
    }

    function getSelectorByChainId(uint256 chainId) external view returns (uint64) {
        return s_selectorByChainId[chainId];
    }

    function isLaneActive(uint64 sourceSelector, uint64 destinationSelector) external view returns (bool) {
        bytes32 key = _laneKey(sourceSelector, destinationSelector);
        return s_laneExists[key] && s_laneByKey[key].isActive;
    }

    function getLane(uint64 sourceSelector, uint64 destinationSelector) external view returns (LaneRecord memory) {
        bytes32 key = _laneKey(sourceSelector, destinationSelector);
        if (!s_laneExists[key]) revert UnknownLane(sourceSelector, destinationSelector);
        return s_laneByKey[key];
    }

    function resolveLaneToken(uint64 sourceSelector, uint64 destinationSelector, address sourceToken)
        external
        view
        returns (LaneTokenRecord memory)
    {
        bytes32 key = _laneTokenKey(sourceSelector, destinationSelector, sourceToken);
        if (!s_laneTokenExists[key]) revert UnknownLaneToken(sourceSelector, destinationSelector, sourceToken);
        return s_laneTokenByKey[key];
    }

    function isTokenTransferable(uint64 sourceSelector, uint64 destinationSelector, address sourceToken)
        external
        view
        returns (bool)
    {
        if (!_isChainSupported(sourceSelector) || !_isChainSupported(destinationSelector)) return false;

        bytes32 laneKeyValue = _laneKey(sourceSelector, destinationSelector);
        if (!s_laneExists[laneKeyValue] || !s_laneByKey[laneKeyValue].isActive) return false;

        bytes32 tokenKeyValue = _laneTokenKey(sourceSelector, destinationSelector, sourceToken);
        if (!s_laneTokenExists[tokenKeyValue]) return false;

        return s_laneTokenByKey[tokenKeyValue].isActive;
    }

    function getServiceContract(uint64 chainSelector, bytes32 serviceKey) external view returns (address) {
        bytes32 key = _serviceKey(chainSelector, serviceKey);
        if (!s_serviceBindingExists[key]) return address(0);

        ServiceBinding memory binding = s_serviceBindingByKey[key];
        if (!binding.isActive) return address(0);
        return binding.contractAddress;
    }

    function getSupportedChains(uint256 offset, uint256 limit) external view returns (ChainRecord[] memory) {
        return _getSupportedChains(offset, limit);
    }

    function getActiveLanes(uint256 offset, uint256 limit) external view returns (LaneRecord[] memory) {
        return _getActiveLanes(offset, limit);
    }

    function upsertChain(ChainRecord calldata record) external onlyOwner {
        if (record.selector == 0) revert ZeroSelector();
        if (record.chainId == 0) revert ZeroChainId();
        if (bytes(record.name).length == 0) revert InvalidMode();
        if (record.router == address(0) || record.linkToken == address(0)) revert ZeroAddress();

        uint64 existingSelectorForChain = s_selectorByChainId[record.chainId];
        if (existingSelectorForChain != 0 && existingSelectorForChain != record.selector) {
            revert ChainIdAlreadyMapped(record.chainId, existingSelectorForChain);
        }

        if (s_chainExists[record.selector]) {
            uint256 existingChainId = s_chainBySelector[record.selector].chainId;
            if (existingChainId != 0 && existingChainId != record.chainId) {
                revert SelectorAlreadyMapped(record.selector, existingChainId);
            }
        } else {
            s_allChainSelectors.push(record.selector);
            s_chainExists[record.selector] = true;
        }

        s_chainBySelector[record.selector] = record;
        s_selectorByChainId[record.chainId] = record.selector;

        emit ChainUpserted(record.selector, record.chainId, record.isActive, record.isTestnet);
    }

    function setLane(uint64 sourceSelector, uint64 destinationSelector, bool isActive, uint8 feeTokenMode)
        external
        onlyOwner
    {
        if (sourceSelector == 0 || destinationSelector == 0) revert ZeroSelector();
        if (!s_chainExists[sourceSelector]) revert UnknownChain(sourceSelector);
        if (!s_chainExists[destinationSelector]) revert UnknownChain(destinationSelector);

        bytes32 key = _laneKey(sourceSelector, destinationSelector);
        if (!s_laneExists[key]) {
            s_laneExists[key] = true;
            s_laneKeys.push(key);
        }

        s_laneByKey[key] = LaneRecord({
            sourceSelector: sourceSelector,
            destinationSelector: destinationSelector,
            isActive: isActive,
            feeTokenMode: feeTokenMode
        });

        emit LaneUpdated(sourceSelector, destinationSelector, isActive, feeTokenMode);
    }

    function setLaneToken(
        uint64 sourceSelector,
        uint64 destinationSelector,
        address sourceToken,
        address destinationToken,
        uint8 decimals,
        bytes32 symbolHash,
        bool isActive
    ) external onlyOwner {
        if (sourceSelector == 0 || destinationSelector == 0) revert ZeroSelector();
        if (sourceToken == address(0) || destinationToken == address(0)) revert ZeroAddress();

        bytes32 laneKeyValue = _laneKey(sourceSelector, destinationSelector);
        if (!s_laneExists[laneKeyValue]) revert UnknownLane(sourceSelector, destinationSelector);

        bytes32 key = _laneTokenKey(sourceSelector, destinationSelector, sourceToken);
        if (!s_laneTokenExists[key]) {
            s_laneTokenExists[key] = true;
            s_laneTokenKeys.push(key);
        }

        s_laneTokenByKey[key] = LaneTokenRecord({
            sourceSelector: sourceSelector,
            destinationSelector: destinationSelector,
            sourceToken: sourceToken,
            destinationToken: destinationToken,
            decimals: decimals,
            symbolHash: symbolHash,
            isActive: isActive
        });

        emit LaneTokenUpdated(
            sourceSelector, destinationSelector, sourceToken, destinationToken, decimals, symbolHash, isActive
        );
    }

    function setServiceContract(uint64 chainSelector, bytes32 serviceKey, address contractAddress, bool isActive)
        external
        onlyOwner
    {
        if (chainSelector == 0) revert ZeroSelector();
        if (serviceKey == bytes32(0)) revert InvalidMode();
        if (!s_chainExists[chainSelector]) revert UnknownChain(chainSelector);
        if (contractAddress == address(0)) revert ZeroAddress();

        bytes32 key = _serviceKey(chainSelector, serviceKey);
        if (!s_serviceBindingExists[key]) {
            s_serviceBindingExists[key] = true;
            s_serviceBindingKeys.push(key);
        }

        s_serviceBindingByKey[key] = ServiceBinding({
            chainSelector: chainSelector, serviceKey: serviceKey, contractAddress: contractAddress, isActive: isActive
        });

        emit ServiceBindingUpdated(chainSelector, serviceKey, contractAddress, isActive);
    }

    function setChainActive(uint64 selector, bool isActive) external onlyOwner {
        if (!s_chainExists[selector]) revert UnknownChain(selector);
        s_chainBySelector[selector].isActive = isActive;
        emit ChainActivationUpdated(selector, isActive);
    }

    function setLaneActive(uint64 sourceSelector, uint64 destinationSelector, bool isActive) external onlyOwner {
        bytes32 key = _laneKey(sourceSelector, destinationSelector);
        if (!s_laneExists[key]) revert UnknownLane(sourceSelector, destinationSelector);
        s_laneByKey[key].isActive = isActive;
        emit LaneActivationUpdated(sourceSelector, destinationSelector, isActive);
    }

    function setLaneTokenActive(uint64 sourceSelector, uint64 destinationSelector, address sourceToken, bool isActive)
        external
        onlyOwner
    {
        bytes32 key = _laneTokenKey(sourceSelector, destinationSelector, sourceToken);
        if (!s_laneTokenExists[key]) revert UnknownLaneToken(sourceSelector, destinationSelector, sourceToken);
        s_laneTokenByKey[key].isActive = isActive;
        emit LaneTokenActivationUpdated(sourceSelector, destinationSelector, sourceToken, isActive);
    }

    function setServiceActive(uint64 chainSelector, bytes32 serviceKey, bool isActive) external onlyOwner {
        bytes32 key = _serviceKey(chainSelector, serviceKey);
        if (!s_serviceBindingExists[key]) revert UnknownService(chainSelector, serviceKey);
        s_serviceBindingByKey[key].isActive = isActive;
        emit ServiceActivationUpdated(chainSelector, serviceKey, isActive);
    }

    function _laneKey(uint64 sourceSelector, uint64 destinationSelector) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(sourceSelector, destinationSelector));
    }

    function _laneTokenKey(uint64 sourceSelector, uint64 destinationSelector, address sourceToken)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(sourceSelector, destinationSelector, sourceToken));
    }

    function _serviceKey(uint64 chainSelector, bytes32 serviceKey) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainSelector, serviceKey));
    }

    function _isChainSupported(uint64 selector) private view returns (bool) {
        return s_chainExists[selector] && s_chainBySelector[selector].isActive;
    }

    function _getSupportedChains(uint256 offset, uint256 limit) private view returns (ChainRecord[] memory) {
        if (limit == 0) return new ChainRecord[](0);

        uint256 activeCount;
        uint256 total = s_allChainSelectors.length;
        for (uint256 i = 0; i < total; i++) {
            if (s_chainBySelector[s_allChainSelectors[i]].isActive) {
                activeCount++;
            }
        }

        if (offset >= activeCount) return new ChainRecord[](0);

        uint256 remaining = activeCount - offset;
        uint256 outSize = remaining < limit ? remaining : limit;
        ChainRecord[] memory records = new ChainRecord[](outSize);

        uint256 seen;
        uint256 written;
        for (uint256 i = 0; i < total; i++) {
            ChainRecord memory record = s_chainBySelector[s_allChainSelectors[i]];
            if (!record.isActive) continue;

            if (seen >= offset) {
                records[written] = record;
                written++;
                if (written == outSize) break;
            }
            seen++;
        }

        return records;
    }

    function _getActiveLanes(uint256 offset, uint256 limit) private view returns (LaneRecord[] memory) {
        if (limit == 0) return new LaneRecord[](0);

        uint256 activeCount;
        uint256 total = s_laneKeys.length;
        for (uint256 i = 0; i < total; i++) {
            if (s_laneByKey[s_laneKeys[i]].isActive) {
                activeCount++;
            }
        }

        if (offset >= activeCount) return new LaneRecord[](0);

        uint256 remaining = activeCount - offset;
        uint256 outSize = remaining < limit ? remaining : limit;
        LaneRecord[] memory records = new LaneRecord[](outSize);

        uint256 seen;
        uint256 written;
        for (uint256 i = 0; i < total; i++) {
            LaneRecord memory record = s_laneByKey[s_laneKeys[i]];
            if (!record.isActive) continue;

            if (seen >= offset) {
                records[written] = record;
                written++;
                if (written == outSize) break;
            }
            seen++;
        }

        return records;
    }
}
