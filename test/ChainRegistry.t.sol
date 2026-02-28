// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {IChainRegistry} from "../src/interfaces/IChainRegistry.sol";

contract ChainRegistryTest is Test {
    ChainRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    uint64 internal constant SRC_SELECTOR = 16015286601757825753;
    uint64 internal constant DST_SELECTOR = 16281711391670634445;

    uint256 internal constant SRC_CHAIN_ID = 11155111;
    uint256 internal constant DST_CHAIN_ID = 80002;

    address internal constant SRC_ROUTER = address(0x1001);
    address internal constant DST_ROUTER = address(0x1002);
    address internal constant SRC_LINK = address(0x2001);
    address internal constant DST_LINK = address(0x2002);

    address internal constant SRC_TOKEN = address(0x3001);
    address internal constant DST_TOKEN = address(0x3002);

    bytes32 internal constant SERVICE_KEY = keccak256("TOKEN_TRANSFER_SENDER");

    function setUp() external {
        vm.prank(owner);
        registry = new ChainRegistry();

        vm.startPrank(owner);
        _upsertChain(SRC_CHAIN_ID, SRC_SELECTOR, "Ethereum Sepolia", SRC_ROUTER, SRC_LINK);
        _upsertChain(DST_CHAIN_ID, DST_SELECTOR, "Polygon Amoy", DST_ROUTER, DST_LINK);
        vm.stopPrank();
    }

    function test_UpsertChainAndSelectorLookup() external view {
        assertEq(registry.getSelectorByChainId(SRC_CHAIN_ID), SRC_SELECTOR);
        assertEq(registry.getSelectorByChainId(DST_CHAIN_ID), DST_SELECTOR);

        IChainRegistry.ChainRecord memory src = registry.getChainBySelector(SRC_SELECTOR);
        assertEq(src.chainId, SRC_CHAIN_ID);
        assertEq(src.selector, SRC_SELECTOR);
        assertEq(src.router, SRC_ROUTER);
        assertEq(src.linkToken, SRC_LINK);
        assertTrue(src.isActive);
    }

    function test_UnauthorizedWritesRevert() external {
        IChainRegistry.ChainRecord memory record = IChainRegistry.ChainRecord({
            chainId: 421614,
            selector: 3478487238524512106,
            name: "Arbitrum Sepolia",
            router: address(0x4001),
            linkToken: address(0x5001),
            wrappedNative: address(0),
            isActive: true,
            isTestnet: true
        });

        vm.prank(user);
        vm.expectRevert();
        registry.upsertChain(record);
    }

    function test_SetLaneAndTokenTransferability() external {
        vm.startPrank(owner);
        registry.setLane(SRC_SELECTOR, DST_SELECTOR, true, 3);
        registry.setLaneToken(SRC_SELECTOR, DST_SELECTOR, SRC_TOKEN, DST_TOKEN, 18, keccak256("CCIP-BnM"), true);
        vm.stopPrank();

        assertTrue(registry.isLaneActive(SRC_SELECTOR, DST_SELECTOR));
        assertTrue(registry.isTokenTransferable(SRC_SELECTOR, DST_SELECTOR, SRC_TOKEN));

        IChainRegistry.LaneTokenRecord memory t = registry.resolveLaneToken(SRC_SELECTOR, DST_SELECTOR, SRC_TOKEN);
        assertEq(t.destinationToken, DST_TOKEN);
        assertEq(t.decimals, 18);
        assertTrue(t.isActive);
    }

    function test_SetServiceContractAndRead() external {
        vm.prank(owner);
        registry.setServiceContract(SRC_SELECTOR, SERVICE_KEY, address(0xBEEF), true);

        address bound = registry.getServiceContract(SRC_SELECTOR, SERVICE_KEY);
        assertEq(bound, address(0xBEEF));

        vm.prank(owner);
        registry.setServiceActive(SRC_SELECTOR, SERVICE_KEY, false);
        assertEq(registry.getServiceContract(SRC_SELECTOR, SERVICE_KEY), address(0));
    }

    function test_PaginationForChainsAndLanes() external {
        vm.startPrank(owner);
        registry.setLane(SRC_SELECTOR, DST_SELECTOR, true, 3);
        registry.setLane(DST_SELECTOR, SRC_SELECTOR, true, 3);
        vm.stopPrank();

        IChainRegistry.ChainRecord[] memory chains = registry.getSupportedChains(0, 10);
        assertEq(chains.length, 2);

        IChainRegistry.LaneRecord[] memory lanes = registry.getActiveLanes(0, 10);
        assertEq(lanes.length, 2);

        IChainRegistry.LaneRecord[] memory paged = registry.getActiveLanes(1, 1);
        assertEq(paged.length, 1);
    }

    function test_DuplicateUpsertIsDeterministic() external {
        vm.prank(owner);
        _upsertChain(SRC_CHAIN_ID, SRC_SELECTOR, "Ethereum Sepolia", SRC_ROUTER, SRC_LINK);

        IChainRegistry.ChainRecord memory src = registry.getChainBySelector(SRC_SELECTOR);
        assertEq(src.chainId, SRC_CHAIN_ID);
        assertEq(src.selector, SRC_SELECTOR);
    }

    function _upsertChain(uint256 chainId, uint64 selector, string memory name, address router, address link) internal {
        registry.upsertChain(
            IChainRegistry.ChainRecord({
                chainId: chainId,
                selector: selector,
                name: name,
                router: router,
                linkToken: link,
                wrappedNative: address(0),
                isActive: true,
                isTestnet: true
            })
        );
    }
}
