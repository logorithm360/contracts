// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/ccip/CCIPLocalSimulator.sol";

import {MessagingSender} from "../src/MessageSender.sol";
import {TokenTransferSender} from "../src/TokenTransferSender.sol";
import {ProgrammableTokenSender} from "../src/ProgrammableTokenSender.sol";
import {SecurityManager} from "../src/SecurityManager.sol";
import {TokenVerifier} from "../src/TokenVerifier.sol";

contract Feature6IntegrationTest is Test {
    CCIPLocalSimulator internal simulator;
    IRouterClient internal router;
    LinkToken internal linkToken;
    BurnMintERC677Helper internal bnm;
    uint64 internal selector;

    MessagingSender internal messageSender;
    TokenTransferSender internal tokenSender;
    ProgrammableTokenSender internal programmableSender;
    SecurityManager internal security;
    TokenVerifier internal verifier;

    address internal alice = makeAddr("alice");
    address internal receiver = makeAddr("receiver");

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (selector, router,,, linkToken, bnm,) = simulator.configuration();

        security = new SecurityManager();
        verifier = new TokenVerifier();

        messageSender = new MessagingSender(address(router), address(linkToken), true);
        tokenSender = new TokenTransferSender(address(router), address(linkToken), true);
        programmableSender = new ProgrammableTokenSender(address(router), address(linkToken), true);

        messageSender.allowlistDestinationChain(selector, true);
        tokenSender.allowlistDestinationChain(selector, true);
        programmableSender.allowlistDestinationChain(selector, true);

        tokenSender.allowlistToken(address(bnm), true);
        programmableSender.allowlistToken(address(bnm), true);

        messageSender.configureSecurity(address(security), address(verifier));
        tokenSender.configureSecurity(address(security), address(verifier));
        programmableSender.configureSecurity(address(security), address(verifier));

        security.authoriseCaller(address(messageSender), true);
        security.authoriseCaller(address(tokenSender), true);
        security.authoriseCaller(address(programmableSender), true);

        verifier.setAuthorisedCaller(address(tokenSender), true);
        verifier.setAuthorisedCaller(address(programmableSender), true);

        verifier.addToAllowlist(address(bnm), true);
    }

    function test_messageBlockedWhenPausedAndEnforceMode() public {
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);
        security.pause("PAUSED");

        vm.expectRevert(SecurityManager.SystemPaused.selector);
        messageSender.sendMessagePayLink(selector, receiver, "hi");
    }

    function test_tokenTransferBlockedByVerifierInEnforceMode() public {
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);
        verifier.addToAllowlist(address(bnm), false);
        verifier.addToBlocklist(address(bnm), "BLOCK");

        vm.prank(alice);
        vm.expectRevert();
        tokenSender.transferTokensPayLink(selector, receiver, address(bnm), 1 ether);
    }

    function test_programmableTransferBlockedByVerifierInEnforceMode() public {
        security.setEnforcementMode(SecurityManager.EnforcementMode.ENFORCE);
        verifier.addToAllowlist(address(bnm), false);
        verifier.addToBlocklist(address(bnm), "BLOCK");

        ProgrammableTokenSender.TransferPayload memory payload = ProgrammableTokenSender.TransferPayload({
            recipient: receiver, action: "transfer", extraData: "", deadline: block.timestamp + 1 days
        });

        vm.prank(alice);
        vm.expectRevert();
        programmableSender.sendPayLink(selector, receiver, address(bnm), 1 ether, payload);
    }
}
