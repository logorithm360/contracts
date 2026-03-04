// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {TokenTransferReceiver} from "../src/TokenTransferReceiver.sol";
import {ChainRegistry} from "../src/ChainRegistry.sol";
import {IChainRegistry} from "../src/interfaces/IChainRegistry.sol";

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

contract ChainResolverIntegrationTest is Test {
    CCIPLocalSimulator internal simulator;
    IRouterClient internal sourceRouter;
    IRouterClient internal destRouter;
    LinkToken internal linkToken;
    BurnMintERC677Helper internal ccipBnM;
    uint64 internal chainSelector;

    TokenTransferSender internal sender;
    TokenTransferReceiver internal receiver;
    ChainRegistry internal registry;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant TOKEN_SENDER_KEY = keccak256("TOKEN_TRANSFER_SENDER");
    bytes32 internal constant TOKEN_RECEIVER_KEY = keccak256("TOKEN_TRANSFER_RECEIVER");

    uint256 internal constant LINK_FUND = 10 ether;

    function setUp() external {
        simulator = new CCIPLocalSimulator();
        (
            uint64 _selector,
            IRouterClient _sourceRouter,
            IRouterClient _destRouter,,
            LinkToken _linkToken,
            BurnMintERC677Helper _ccipBnM,
        ) = simulator.configuration();

        chainSelector = _selector;
        sourceRouter = _sourceRouter;
        destRouter = _destRouter;
        linkToken = _linkToken;
        ccipBnM = _ccipBnM;

        vm.startPrank(owner);
        sender = new TokenTransferSender(address(sourceRouter), address(linkToken), true);
        receiver = new TokenTransferReceiver(address(destRouter));

        sender.allowlistDestinationChain(chainSelector, true);
        sender.allowlistToken(address(ccipBnM), true);
        sender.allowlistToken(address(linkToken), true);
        sender.updateExtraArgs(
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: false}))
        );

        receiver.allowlistSourceChain(chainSelector, true);
        receiver.allowlistSender(chainSelector, address(sender), true);

        registry = new ChainRegistry();
        vm.stopPrank();

        simulator.requestLinkFromFaucet(address(sender), LINK_FUND);
        ccipBnM.drip(alice);
        IFeeConfigurableRouter(address(sourceRouter)).setFee(0.01 ether);
    }

    function test_DisabledMode_UsesLegacyAllowlistFlow() external {
        _seedRegistry(address(receiver), true);

        vm.prank(owner);
        sender.configureChainRegistry(address(registry), 0);

        uint256 amount = 1e17;
        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        bytes32 messageId = sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();

        assertNotEq(messageId, bytes32(0));
    }

    function test_MonitorMode_EmitsViolationAndContinues() external {
        address mismatchedReceiver = makeAddr("mismatchedReceiver");
        _seedRegistry(mismatchedReceiver, true);

        vm.prank(owner);
        sender.configureChainRegistry(address(registry), 1); // MONITOR

        uint256 amount = 1e17;

        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        vm.expectEmit(true, true, true, true, address(sender));
        emit TokenTransferSender.RegistryPolicyViolation(
            keccak256("DESTINATION_SERVICE_NOT_BOUND"),
            chainSelector,
            chainSelector,
            address(ccipBnM),
            address(receiver)
        );
        bytes32 messageId = sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();

        assertNotEq(messageId, bytes32(0));
        assertEq(receiver.getTransferCount(), 1);
    }

    function test_EnforceMode_BlocksOnServiceMismatch() external {
        _seedRegistry(makeAddr("wrongReceiver"), true);

        vm.prank(owner);
        sender.configureChainRegistry(address(registry), 2); // ENFORCE

        uint256 amount = 1e17;
        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransferSender.RegistryPolicyBlocked.selector, keccak256("DESTINATION_SERVICE_NOT_BOUND")
            )
        );
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();
    }

    function test_EnforceMode_BlocksWhenTokenNotTransferable() external {
        _seedRegistry(address(receiver), false);

        vm.prank(owner);
        sender.configureChainRegistry(address(registry), 2); // ENFORCE

        uint256 amount = 1e17;
        vm.startPrank(alice);
        ccipBnM.approve(address(sender), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenTransferSender.RegistryPolicyBlocked.selector, keccak256("TOKEN_NOT_TRANSFERABLE")
            )
        );
        sender.transferTokensPayLink(chainSelector, address(receiver), address(ccipBnM), amount);
        vm.stopPrank();
    }

    function _seedRegistry(address destinationServiceContract, bool tokenActive) internal {
        vm.startPrank(owner);
        registry.upsertChain(
            IChainRegistry.ChainRecord({
                chainId: block.chainid,
                selector: chainSelector,
                name: "Local Source",
                router: address(sourceRouter),
                linkToken: address(linkToken),
                wrappedNative: address(0),
                isActive: true,
                isTestnet: true
            })
        );

        registry.setLane(chainSelector, chainSelector, true, 3);
        registry.setLaneToken(
            chainSelector, chainSelector, address(ccipBnM), address(ccipBnM), 18, keccak256("CCIP-BnM"), tokenActive
        );

        registry.setServiceContract(chainSelector, TOKEN_SENDER_KEY, address(sender), true);
        registry.setServiceContract(chainSelector, TOKEN_RECEIVER_KEY, destinationServiceContract, true);
        vm.stopPrank();
    }
}
