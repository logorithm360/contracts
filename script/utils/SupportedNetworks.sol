// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

library SupportedNetworks {
    uint256 internal constant ETHEREUM_SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant POLYGON_AMOY_CHAIN_ID = 80002;
    uint256 internal constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant OP_SEPOLIA_CHAIN_ID = 11155420;

    uint64 internal constant ETHEREUM_SEPOLIA_SELECTOR = 16015286601757825753;
    uint64 internal constant POLYGON_AMOY_SELECTOR = 16281711391670634445;
    uint64 internal constant ARBITRUM_SEPOLIA_SELECTOR = 3478487238524512106;
    uint64 internal constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;
    uint64 internal constant OP_SEPOLIA_SELECTOR = 5224473277236331295;

    function isSupportedChainId(uint256 chainId) internal pure returns (bool) {
        return chainId == ETHEREUM_SEPOLIA_CHAIN_ID
            || chainId == POLYGON_AMOY_CHAIN_ID
            || chainId == ARBITRUM_SEPOLIA_CHAIN_ID
            || chainId == BASE_SEPOLIA_CHAIN_ID
            || chainId == OP_SEPOLIA_CHAIN_ID;
    }

    function selectorByChainId(uint256 chainId) internal pure returns (uint64) {
        if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) return ETHEREUM_SEPOLIA_SELECTOR;
        if (chainId == POLYGON_AMOY_CHAIN_ID) return POLYGON_AMOY_SELECTOR;
        if (chainId == ARBITRUM_SEPOLIA_CHAIN_ID) return ARBITRUM_SEPOLIA_SELECTOR;
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return BASE_SEPOLIA_SELECTOR;
        if (chainId == OP_SEPOLIA_CHAIN_ID) return OP_SEPOLIA_SELECTOR;
        revert("Unsupported chain");
    }

    function nameByChainId(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ETHEREUM_SEPOLIA_CHAIN_ID) return "Ethereum Sepolia";
        if (chainId == POLYGON_AMOY_CHAIN_ID) return "Polygon Amoy";
        if (chainId == ARBITRUM_SEPOLIA_CHAIN_ID) return "Arbitrum Sepolia";
        if (chainId == BASE_SEPOLIA_CHAIN_ID) return "Base Sepolia";
        if (chainId == OP_SEPOLIA_CHAIN_ID) return "OP Sepolia";
        return "Unsupported";
    }

    function allSelectors() internal pure returns (uint64[5] memory selectors) {
        selectors = [
            ETHEREUM_SEPOLIA_SELECTOR,
            POLYGON_AMOY_SELECTOR,
            ARBITRUM_SEPOLIA_SELECTOR,
            BASE_SEPOLIA_SELECTOR,
            OP_SEPOLIA_SELECTOR
        ];
    }
}
