// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts-ccip/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {AutomatedTrader}         from "../src/AutomatedTrader.sol";
import {AutomatedTraderReceiver} from "../src/AutomatedTraderReceiver.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT A — Deploy AutomatedTrader on Ethereum Sepolia
// ─────────────────────────────────────────────────────────────────────────────
//  Simulate:
//    forge script script/DeployAutomation.s.sol:DeployAutomatedTrader \
//      --rpc-url sepolia -vvvv
//
//  Deploy + verify:
//    forge script script/DeployAutomation.s.sol:DeployAutomatedTrader \
//      --rpc-url sepolia --account deployer --broadcast --verify -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract DeployAutomatedTrader is Script {

    // Ethereum Sepolia — verified addresses
    address constant SEPOLIA_ROUTER     = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant SEPOLIA_LINK       = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant SEPOLIA_CCIP_BNM   = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;
    address constant SEPOLIA_CCIP_LNM   = 0x466D489b6d36E7E3b824ef491C225F5830Be5EBA;

    uint64 constant AMOY_CHAIN_SELECTOR = 16281711391670634445;

    function run() public returns (AutomatedTrader traderContract) {
        require(block.chainid == 11155111, "Must run on Ethereum Sepolia");

        console.log("Deploying AutomatedTrader on Ethereum Sepolia");

        vm.startBroadcast();

        traderContract = new AutomatedTrader(SEPOLIA_ROUTER, SEPOLIA_LINK);

        traderContract.allowlistDestinationChain(AMOY_CHAIN_SELECTOR, true);
        traderContract.allowlistToken(SEPOLIA_CCIP_BNM, true);
        traderContract.allowlistToken(SEPOLIA_CCIP_LNM, true);

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("AutomatedTrader deployed:", address(traderContract));
        console.log("Amoy chain allowlisted:  ", traderContract.allowlistedDestinationChains(AMOY_CHAIN_SELECTOR));
        console.log("CCIP-BnM allowlisted:    ", traderContract.allowlistedTokens(SEPOLIA_CCIP_BNM));
        console.log("=============================================");
        console.log("NEXT STEPS:");
        console.log("1. Fund with LINK (for CCIP fees):  transfer LINK to", address(traderContract));
        console.log("2. Fund with CCIP-BnM tokens:       transfer tokens to", address(traderContract));
        console.log("3. Register price feeds (REQUIRED for PRICE_THRESHOLD orders):");
        console.log("   setPriceFeed(CCIP_BNM, ETH_USD_FEED)");
        console.log("   ETH/USD feed on Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306");
        console.log("   BTC/USD feed on Sepolia: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43");
        console.log("   LINK/USD feed on Sepolia: 0xc59E3633BAAC79493d908e63626716e204A45EdF");
        console.log("4. Deploy AutomatedTraderReceiver on Amoy");
        console.log("5. Register upkeep at:              https://automation.chain.link");
        console.log("6. After registration, set forwarder address via SetForwarder script");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT B — Deploy AutomatedTraderReceiver on Polygon Amoy
// ─────────────────────────────────────────────────────────────────────────────
//  Simulate:
//    TRADER_ADDRESS=0x... forge script script/DeployAutomation.s.sol:DeployAutomatedReceiver \
//      --rpc-url amoy -vvvv
//
//  Deploy:
//    TRADER_ADDRESS=0x... forge script script/DeployAutomation.s.sol:DeployAutomatedReceiver \
//      --rpc-url amoy --account deployer --broadcast -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract DeployAutomatedReceiver is Script {

    address constant AMOY_ROUTER            = 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2;
    uint64  constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;

    function run() public returns (AutomatedTraderReceiver receiverContract) {
        require(block.chainid == 80002, "Must run on Polygon Amoy");

        address traderAddress = vm.envAddress("TRADER_ADDRESS");
        require(traderAddress != address(0), "TRADER_ADDRESS env var not set");

        console.log("Deploying AutomatedTraderReceiver on Polygon Amoy");
        console.log("Trader address:", traderAddress);

        vm.startBroadcast();

        receiverContract = new AutomatedTraderReceiver(AMOY_ROUTER);
        receiverContract.allowlistSourceChain(SEPOLIA_CHAIN_SELECTOR, true);
        receiverContract.allowlistSender(traderAddress, true);

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("AutomatedTraderReceiver deployed:", address(receiverContract));
        console.log("Sepolia chain allowlisted:        ", receiverContract.allowlistedSourceChains(SEPOLIA_CHAIN_SELECTOR));
        console.log("Trader allowlisted:               ", receiverContract.allowlistedSenders(traderAddress));
        console.log("=============================================");
        console.log("NEXT STEPS:");
        console.log("1. Run CreateOrder script to create your first automated trade");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT C — Set the Automation Forwarder address AFTER upkeep registration
// ─────────────────────────────────────────────────────────────────────────────
//  After registering your upkeep at automation.chain.link:
//    1. Open your upkeep details
//    2. Copy the "Forwarder address" shown in the details panel
//    3. Run this script to lock down performUpkeep to that forwarder
//
//  Run:
//    TRADER_ADDRESS=0x... FORWARDER_ADDRESS=0x... \
//    forge script script/DeployAutomation.s.sol:SetForwarder \
//      --rpc-url sepolia --account deployer --broadcast -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract SetForwarder is Script {
    function run() public {
        require(block.chainid == 11155111, "Must run on Ethereum Sepolia");

        address traderAddr    = vm.envAddress("TRADER_ADDRESS");
        address forwarderAddr = vm.envAddress("FORWARDER_ADDRESS");

        require(traderAddr    != address(0), "TRADER_ADDRESS not set");
        require(forwarderAddr != address(0), "FORWARDER_ADDRESS not set");

        console.log("Setting Automation forwarder on AutomatedTrader");
        console.log("Trader:    ", traderAddr);
        console.log("Forwarder: ", forwarderAddr);

        vm.startBroadcast();
        AutomatedTrader(payable(traderAddr)).setForwarder(forwarderAddr);
        vm.stopBroadcast();

        console.log("Forwarder set. performUpkeep is now locked to:", forwarderAddr);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT D — Create a TIME_BASED order
// ─────────────────────────────────────────────────────────────────────────────
//  Required env vars:
//    TRADER_ADDRESS     — AutomatedTrader on Sepolia
//    RECEIVER_ADDRESS   — AutomatedTraderReceiver on Amoy
//    TOKEN_ADDRESS      — ERC20 token to send (Sepolia address)
//    TOKEN_AMOUNT       — Amount per execution (in wei)
//    INTERVAL_SECONDS   — Seconds between executions (e.g. 3600 = 1hr)
//    RECIPIENT          — Beneficiary address on Amoy
//    ACTION             — "transfer" | "stake" | "swap" | "deposit"
//    RECURRING          — "true" | "false"
//    MAX_EXECUTIONS     — 0 = unlimited
//    DEADLINE           — 0 = no deadline (unix timestamp)
//
//  Run:
//    TRADER_ADDRESS=0x... RECEIVER_ADDRESS=0x... TOKEN_ADDRESS=0x... \
//    TOKEN_AMOUNT=1000000000000000000 INTERVAL_SECONDS=3600 RECIPIENT=0x... \
//    ACTION=transfer RECURRING=true MAX_EXECUTIONS=0 DEADLINE=0 \
//    forge script script/DeployAutomation.s.sol:CreateTimedOrder \
//      --rpc-url sepolia --account deployer --broadcast -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract CreateTimedOrder is Script {

    uint64 constant AMOY_CHAIN_SELECTOR = 16281711391670634445;

    function run() public returns (uint256 orderId) {
        require(block.chainid == 11155111, "Must run on Ethereum Sepolia");

        address traderAddr   = vm.envAddress("TRADER_ADDRESS");
        address receiverAddr = vm.envAddress("RECEIVER_ADDRESS");
        address tokenAddr    = vm.envAddress("TOKEN_ADDRESS");
        uint256 amount       = vm.envUint("TOKEN_AMOUNT");
        uint256 interval     = vm.envUint("INTERVAL_SECONDS");
        address recipient    = vm.envAddress("RECIPIENT");
        string  memory action = vm.envString("ACTION");
        bool    recurring    = vm.envOr("RECURRING", true);
        uint256 maxExec      = vm.envOr("MAX_EXECUTIONS", uint256(0));
        uint256 deadline     = vm.envOr("DEADLINE", uint256(0));

        require(traderAddr   != address(0), "TRADER_ADDRESS not set");
        require(receiverAddr != address(0), "RECEIVER_ADDRESS not set");
        require(tokenAddr    != address(0), "TOKEN_ADDRESS not set");
        require(amount > 0,                  "TOKEN_AMOUNT must be > 0");
        require(interval > 0,               "INTERVAL_SECONDS must be > 0");
        require(recipient    != address(0), "RECIPIENT not set");

        AutomatedTrader t = AutomatedTrader(payable(traderAddr));

        // Pre-flight
        require(t.allowlistedDestinationChains(AMOY_CHAIN_SELECTOR), "Amoy not allowlisted");
        require(t.allowlistedTokens(tokenAddr), "Token not allowlisted — call allowlistToken first");

        console.log("Token balance in trader:", IERC20(tokenAddr).balanceOf(traderAddr));
        console.log("LINK balance in trader: ", t.getLinkBalance());

        vm.startBroadcast();
        orderId = t.createTimedOrder(
            interval, tokenAddr, amount,
            AMOY_CHAIN_SELECTOR, receiverAddr, recipient,
            action, recurring, maxExec, deadline
        );
        vm.stopBroadcast();

        // Estimate fee AFTER creation — order now exists with a valid ID
        uint256 estFee = t.estimateFee(orderId);
        console.log("Estimated LINK fee per execution:", estFee);

        AutomatedTrader.TradeOrder memory order = t.getOrder(orderId);
        console.log("=============================================");
        console.log("Timed order created!");
        console.log("Order ID:       ", orderId);
        console.log("Token:          ", tokenAddr);
        console.log("Amount:         ", amount);
        console.log("Interval:       ", interval, "seconds");
        console.log("Action:         ", action);
        console.log("Recipient:      ", recipient);
        console.log("Recurring:      ", recurring);
        console.log("Max executions: ", maxExec == 0 ? "unlimited" : vm.toString(maxExec));
        console.log("Active orders:  ", t.getActiveOrderCount());
        console.log("=============================================");
        console.log("Chainlink Automation will now monitor and execute this order.");
        console.log("Track at: https://automation.chain.link");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT E — Check upkeep status and active orders (read-only)
// ─────────────────────────────────────────────────────────────────────────────
//  Run:
//    TRADER_ADDRESS=0x... forge script script/DeployAutomation.s.sol:CheckStatus \
//      --rpc-url sepolia -vv
// ─────────────────────────────────────────────────────────────────────────────
contract CheckStatus is Script {
    function run() public {
        require(block.chainid == 11155111, "Must run on Ethereum Sepolia");

        address traderAddr = vm.envAddress("TRADER_ADDRESS");
        AutomatedTrader t  = AutomatedTrader(payable(traderAddr));

        (bool upkeepNeeded, bytes memory performData) = t.checkUpkeep("");
        uint256[] memory readyIds = upkeepNeeded
            ? abi.decode(performData, (uint256[]))
            : new uint256[](0);

        console.log("=============================================");
        console.log("AutomatedTrader Status");
        console.log("=============================================");
        console.log("Contract:      ", traderAddr);
        console.log("Active orders: ", t.getActiveOrderCount());
        console.log("LINK balance:  ", t.getLinkBalance());
        console.log("Forwarder:     ", t.s_forwarderAddress());
        console.log("Upkeep needed: ", upkeepNeeded);
        console.log("Ready orders:  ", readyIds.length);

        for (uint256 i = 0; i < readyIds.length; i++) {
            AutomatedTrader.TradeOrder memory order = t.getOrder(readyIds[i]);
            console.log("  Order", readyIds[i], ":", order.action, "->", order.recipient);
        }
        console.log("=============================================");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT F — Register Chainlink Data Feeds for PRICE_THRESHOLD orders
// ─────────────────────────────────────────────────────────────────────────────
//  MUST run after deploying AutomatedTrader and BEFORE creating price orders.
//  Without registered feeds, PRICE_THRESHOLD orders are silently skipped.
//
//  This script registers three feeds in one transaction:
//    ETH/USD  → for ETH-correlated tokens
//    BTC/USD  → for BTC-correlated tokens
//    LINK/USD → for LINK token
//
//  Run:
//    TRADER_ADDRESS=0x... forge script script/DeployAutomation.s.sol:SetPriceFeeds \
//      --rpc-url sepolia --account deployer --broadcast -vvvv
//
//  To register a custom token/feed pair:
//    TRADER_ADDRESS=0x... TOKEN_ADDRESS=0x... FEED_ADDRESS=0x... \
//    forge script script/DeployAutomation.s.sol:SetCustomFeed \
//      --rpc-url sepolia --account deployer --broadcast -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract SetPriceFeeds is Script {

    // Ethereum Sepolia — verified Chainlink Data Feed addresses
    // Source: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1
    address constant SEPOLIA_ETH_USD_FEED  = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant SEPOLIA_BTC_USD_FEED  = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    address constant SEPOLIA_LINK_USD_FEED = 0xc59E3633BAAC79493d908e63626716e204A45EdF;
    address constant SEPOLIA_USDC_USD_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    // Sepolia token addresses
    address constant SEPOLIA_WETH       = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81;
    address constant SEPOLIA_LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant SEPOLIA_CCIP_BNM   = 0xFd57b4ddBf88a4e07fF4e34C487b99af2Fe82a05;

    function run() public {
        require(block.chainid == 11155111, "Must run on Ethereum Sepolia");

        address traderAddr = vm.envAddress("TRADER_ADDRESS");
        require(traderAddr != address(0), "TRADER_ADDRESS not set");

        AutomatedTrader t = AutomatedTrader(payable(traderAddr));

        console.log("Registering Chainlink Data Feeds on AutomatedTrader");
        console.log("Trader:", traderAddr);

        vm.startBroadcast();

        // WETH → ETH/USD feed
        t.setPriceFeed(SEPOLIA_WETH, SEPOLIA_ETH_USD_FEED);
        console.log("Set WETH    → ETH/USD feed:", SEPOLIA_ETH_USD_FEED);

        // LINK → LINK/USD feed
        t.setPriceFeed(SEPOLIA_LINK_TOKEN, SEPOLIA_LINK_USD_FEED);
        console.log("Set LINK    → LINK/USD feed:", SEPOLIA_LINK_USD_FEED);

        // CCIP-BnM → ETH/USD feed (test token, proxied to ETH price for demo)
        t.setPriceFeed(SEPOLIA_CCIP_BNM, SEPOLIA_ETH_USD_FEED);
        console.log("Set CCIP-BnM → ETH/USD feed:", SEPOLIA_ETH_USD_FEED);

        vm.stopBroadcast();

        // Verify reads
        console.log("=============================================");
        console.log("Verifying feed registrations...");
        (address feed1, int256 price1,, bool stale1) = t.getPriceFeedData(SEPOLIA_WETH);
        console.log("WETH/USD feed:", feed1, "| price:", uint256(price1), "| stale:", stale1);

        (address feed2, int256 price2,, bool stale2) = t.getPriceFeedData(SEPOLIA_LINK_TOKEN);
        console.log("LINK/USD feed:", feed2, "| price:", uint256(price2), "| stale:", stale2);

        (address feed3, int256 price3,, bool stale3) = t.getPriceFeedData(SEPOLIA_CCIP_BNM);
        console.log("BnM/USD feed:", feed3,  "| price:", uint256(price3), "| stale:", stale3);
        console.log("=============================================");
        console.log("All feeds registered. PRICE_THRESHOLD orders will now use real prices.");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  SCRIPT G — Register a single custom token/feed pair
// ─────────────────────────────────────────────────────────────────────────────
//  Run:
//    TRADER_ADDRESS=0x... TOKEN_ADDRESS=0x... FEED_ADDRESS=0x... \
//    forge script script/DeployAutomation.s.sol:SetCustomFeed \
//      --rpc-url sepolia --account deployer --broadcast -vvvv
// ─────────────────────────────────────────────────────────────────────────────
contract SetCustomFeed is Script {
    function run() public {
        address traderAddr = vm.envAddress("TRADER_ADDRESS");
        address tokenAddr  = vm.envAddress("TOKEN_ADDRESS");
        address feedAddr   = vm.envAddress("FEED_ADDRESS");

        require(traderAddr != address(0), "TRADER_ADDRESS not set");
        require(tokenAddr  != address(0), "TOKEN_ADDRESS not set");
        require(feedAddr   != address(0), "FEED_ADDRESS not set");

        AutomatedTrader t = AutomatedTrader(payable(traderAddr));

        console.log("Registering custom price feed");
        console.log("Token:", tokenAddr);
        console.log("Feed: ", feedAddr);

        vm.startBroadcast();
        t.setPriceFeed(tokenAddr, feedAddr);
        vm.stopBroadcast();

        // Verify
        (address registeredFeed, int256 price, uint256 updatedAt, bool isStale) =
            t.getPriceFeedData(tokenAddr);

        console.log("Feed registered:", registeredFeed);
        console.log("Current price:  ", uint256(price));
        console.log("Updated at:     ", updatedAt);
        console.log("Is stale:       ", isStale);
    }
}
