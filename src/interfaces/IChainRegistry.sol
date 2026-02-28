// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IChainRegistry {
    struct ChainRecord {
        uint256 chainId;
        uint64 selector;
        string name;
        address router;
        address linkToken;
        address wrappedNative;
        bool isActive;
        bool isTestnet;
    }

    struct LaneRecord {
        uint64 sourceSelector;
        uint64 destinationSelector;
        bool isActive;
        uint8 feeTokenMode;
    }

    struct LaneTokenRecord {
        uint64 sourceSelector;
        uint64 destinationSelector;
        address sourceToken;
        address destinationToken;
        uint8 decimals;
        bytes32 symbolHash;
        bool isActive;
    }

    struct ServiceBinding {
        uint64 chainSelector;
        bytes32 serviceKey;
        address contractAddress;
        bool isActive;
    }

    function isChainSupported(uint64 selector) external view returns (bool);

    function getChainBySelector(uint64 selector) external view returns (ChainRecord memory);

    function getSelectorByChainId(uint256 chainId) external view returns (uint64);

    function isLaneActive(uint64 sourceSelector, uint64 destinationSelector) external view returns (bool);

    function getLane(uint64 sourceSelector, uint64 destinationSelector) external view returns (LaneRecord memory);

    function resolveLaneToken(uint64 sourceSelector, uint64 destinationSelector, address sourceToken)
        external
        view
        returns (LaneTokenRecord memory);

    function isTokenTransferable(uint64 sourceSelector, uint64 destinationSelector, address sourceToken)
        external
        view
        returns (bool);

    function getServiceContract(uint64 chainSelector, bytes32 serviceKey) external view returns (address);

    function getSupportedChains(uint256 offset, uint256 limit) external view returns (ChainRecord[] memory);

    function getActiveLanes(uint256 offset, uint256 limit) external view returns (LaneRecord[] memory);

    function upsertChain(ChainRecord calldata record) external;

    function setLane(uint64 sourceSelector, uint64 destinationSelector, bool isActive, uint8 feeTokenMode) external;

    function setLaneToken(
        uint64 sourceSelector,
        uint64 destinationSelector,
        address sourceToken,
        address destinationToken,
        uint8 decimals,
        bytes32 symbolHash,
        bool isActive
    ) external;

    function setServiceContract(uint64 chainSelector, bytes32 serviceKey, address contractAddress, bool isActive)
        external;

    function setChainActive(uint64 selector, bool isActive) external;

    function setLaneActive(uint64 sourceSelector, uint64 destinationSelector, bool isActive) external;

    function setLaneTokenActive(uint64 sourceSelector, uint64 destinationSelector, address sourceToken, bool isActive)
        external;

    function setServiceActive(uint64 chainSelector, bytes32 serviceKey, bool isActive) external;
}
