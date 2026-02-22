// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {SupportedNetworks} from "./utils/SupportedNetworks.sol";
import {AutomatedTrader} from "../src/AutomatedTrader.sol";
import {ProgrammableTokenReceiver} from "../src/ProgrammableTokenReceiver.sol";

/// @notice Deploys AutomatedTrader on Ethereum Sepolia and preconfigures destination/token allowlists.
contract DeployAutomatedTrader is Script {
    function run() external returns (AutomatedTrader traderContract) {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "DeployAutomatedTrader must run on Ethereum Sepolia"
        );

        address localRouter = vm.envAddress("LOCAL_CCIP_ROUTER");
        address localLink = vm.envAddress("LOCAL_LINK_TOKEN");
        address localBnm = vm.envOr("LOCAL_CCIP_BNM_TOKEN", address(0));
        address localLnm = vm.envOr("LOCAL_CCIP_LNM_TOKEN", address(0));

        uint256 destinationGasLimit = vm.envOr("AUTOMATED_DESTINATION_GAS_LIMIT", uint256(500_000));
        uint256 configuredMaxPriceAge = vm.envOr("AUTOMATED_MAX_PRICE_AGE", uint256(1 hours));
        address initialPriceFeed = vm.envOr("AUTOMATED_PRICE_FEED", address(0));

        console.log("Deploying AutomatedTrader on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("Router:", localRouter);
        console.log("LINK:", localLink);

        vm.startBroadcast();

        traderContract = new AutomatedTrader(localRouter, localLink);

        uint64 localSelector = SupportedNetworks.selectorByChainId(block.chainid);
        uint64[5] memory selectors = SupportedNetworks.allSelectors();
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] != localSelector) {
                traderContract.allowlistDestinationChain(selectors[i], true);
            }
        }

        traderContract.allowlistToken(localLink, true);
        if (localBnm != address(0)) {
            traderContract.allowlistToken(localBnm, true);
        }
        if (localLnm != address(0)) {
            traderContract.allowlistToken(localLnm, true);
        }
        if (initialPriceFeed != address(0)) {
            traderContract.allowlistPriceFeed(initialPriceFeed, true);
        }

        if (configuredMaxPriceAge > 0) {
            traderContract.setMaxPriceAge(configuredMaxPriceAge);
        }

        bytes memory nextExtraArgs = Client._argsToBytes(
            Client.GenericExtraArgsV2({gasLimit: destinationGasLimit, allowOutOfOrderExecution: false})
        );
        traderContract.updateExtraArgs(nextExtraArgs);

        vm.stopBroadcast();

        console.log("=============================================");
        console.log("AutomatedTrader deployed at:", address(traderContract));
        console.log("Configured gas limit:", destinationGasLimit);
        console.log("Configured maxPriceAge:", configuredMaxPriceAge);
        console.log("=============================================");
    }
}

/// @notice Sets the Chainlink Automation forwarder after upkeep registration.
contract SetAutomatedForwarder is Script {
    function run() external {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "SetAutomatedForwarder must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        address forwarder = vm.envAddress("AUTOMATION_FORWARDER_ADDRESS");
        require(traderAddr != address(0), "AUTOMATED_TRADER_CONTRACT not set");
        require(forwarder != address(0), "AUTOMATION_FORWARDER_ADDRESS not set");

        vm.startBroadcast();
        AutomatedTrader(payable(traderAddr)).setForwarder(forwarder);
        vm.stopBroadcast();

        console.log("Forwarder set on AutomatedTrader:", forwarder);
    }
}

/// @notice Configures programmable receiver to trust and manual-handle automated sender instructions.
contract ConfigureAutomatedSenderOnReceiver is Script {
    function run() external {
        require(SupportedNetworks.isSupportedChainId(block.chainid), "Unsupported destination chain");

        address receiverAddr = vm.envAddress("AUTOMATED_RECEIVER_CONTRACT");
        address automatedSender = vm.envAddress("AUTOMATED_TRADER_CONTRACT");

        uint64 sourceSelector =
            uint64(vm.envOr("AUTOMATED_SOURCE_SELECTOR", uint256(SupportedNetworks.ETHEREUM_SEPOLIA_SELECTOR)));
        bool enableManualActionMode = vm.envOr("AUTOMATED_ENABLE_MANUAL_ACTION_MODE", true);

        require(receiverAddr != address(0), "AUTOMATED_RECEIVER_CONTRACT not set");
        require(automatedSender != address(0), "AUTOMATED_TRADER_CONTRACT not set");

        vm.startBroadcast();

        ProgrammableTokenReceiver receiver = ProgrammableTokenReceiver(receiverAddr);
        receiver.allowlistSourceChain(sourceSelector, true);
        receiver.allowlistSender(sourceSelector, automatedSender, true);
        receiver.setManualActionSender(sourceSelector, automatedSender, enableManualActionMode);

        vm.stopBroadcast();

        console.log("Configured receiver:", receiverAddr);
        console.log("Source selector:", sourceSelector);
        console.log("Automated sender:", automatedSender);
        console.log("Manual action mode:", enableManualActionMode ? "enabled" : "disabled");
    }
}

/// @notice Creates TIME_BASED automated order.
contract CreateTimedOrder is Script {
    function run() external returns (uint256 orderId) {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "CreateTimedOrder must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        uint64 destinationSelector = uint64(vm.envUint("AUTOMATED_DESTINATION_SELECTOR"));
        address receiverAddr = vm.envAddress("AUTOMATED_RECEIVER_CONTRACT");
        address tokenAddr = vm.envAddress("AUTOMATED_TOKEN_ADDRESS");
        uint256 amount = vm.envUint("AUTOMATED_TOKEN_AMOUNT");
        address recipient = vm.envAddress("AUTOMATED_RECIPIENT");
        string memory action = vm.envString("AUTOMATED_ACTION");

        uint256 intervalSeconds = vm.envUint("AUTOMATED_INTERVAL_SECONDS");
        bool recurring = vm.envOr("AUTOMATED_RECURRING", true);
        uint256 maxExecutions = vm.envOr("AUTOMATED_MAX_EXECUTIONS", uint256(0));
        uint256 deadline = vm.envOr("AUTOMATED_DEADLINE", uint256(0));

        AutomatedTrader trader = AutomatedTrader(payable(traderAddr));
        _validateCommon(trader, destinationSelector, tokenAddr, receiverAddr, recipient, amount);

        vm.startBroadcast();
        orderId = trader.createTimedOrder(
            intervalSeconds,
            tokenAddr,
            amount,
            destinationSelector,
            receiverAddr,
            recipient,
            action,
            recurring,
            maxExecutions,
            deadline
        );
        vm.stopBroadcast();

        uint256 estimatedFee = trader.estimateFee(orderId);
        console.log("Timed order created:", orderId);
        console.log("Estimated LINK fee:", estimatedFee);
    }

    function _validateCommon(
        AutomatedTrader trader,
        uint64 destinationSelector,
        address tokenAddr,
        address receiverAddr,
        address recipient,
        uint256 amount
    ) internal view {
        require(address(trader) != address(0), "AUTOMATED_TRADER_CONTRACT not set");
        require(destinationSelector != 0, "AUTOMATED_DESTINATION_SELECTOR not set");
        require(tokenAddr != address(0), "AUTOMATED_TOKEN_ADDRESS not set");
        require(receiverAddr != address(0), "AUTOMATED_RECEIVER_CONTRACT not set");
        require(recipient != address(0), "AUTOMATED_RECIPIENT not set");
        require(amount > 0, "AUTOMATED_TOKEN_AMOUNT must be > 0");

        require(trader.allowlistedDestinationChains(destinationSelector), "Destination selector not allowlisted");
        require(trader.allowlistedTokens(tokenAddr), "Token not allowlisted");
    }
}

/// @notice Creates PRICE_THRESHOLD automated order.
contract CreatePriceOrder is Script {
    function run() external returns (uint256 orderId) {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "CreatePriceOrder must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        uint64 destinationSelector = uint64(vm.envUint("AUTOMATED_DESTINATION_SELECTOR"));
        address receiverAddr = vm.envAddress("AUTOMATED_RECEIVER_CONTRACT");
        address tokenAddr = vm.envAddress("AUTOMATED_TOKEN_ADDRESS");
        uint256 amount = vm.envUint("AUTOMATED_TOKEN_AMOUNT");
        address recipient = vm.envAddress("AUTOMATED_RECIPIENT");
        string memory action = vm.envString("AUTOMATED_ACTION");

        address priceFeed = vm.envAddress("AUTOMATED_PRICE_FEED");
        uint256 priceThreshold = vm.envUint("AUTOMATED_PRICE_THRESHOLD");
        bool executeAbove = vm.envOr("AUTOMATED_EXECUTE_ABOVE", true);
        bool recurring = vm.envOr("AUTOMATED_RECURRING", false);
        uint256 maxExecutions = vm.envOr("AUTOMATED_MAX_EXECUTIONS", uint256(1));
        uint256 deadline = vm.envOr("AUTOMATED_DEADLINE", uint256(0));

        AutomatedTrader trader = AutomatedTrader(payable(traderAddr));

        require(address(trader) != address(0), "AUTOMATED_TRADER_CONTRACT not set");
        require(destinationSelector != 0, "AUTOMATED_DESTINATION_SELECTOR not set");
        require(tokenAddr != address(0), "AUTOMATED_TOKEN_ADDRESS not set");
        require(receiverAddr != address(0), "AUTOMATED_RECEIVER_CONTRACT not set");
        require(recipient != address(0), "AUTOMATED_RECIPIENT not set");
        require(amount > 0, "AUTOMATED_TOKEN_AMOUNT must be > 0");
        require(priceFeed != address(0), "AUTOMATED_PRICE_FEED not set");

        require(trader.allowlistedDestinationChains(destinationSelector), "Destination selector not allowlisted");
        require(trader.allowlistedTokens(tokenAddr), "Token not allowlisted");
        require(trader.allowlistedPriceFeeds(priceFeed), "Price feed not allowlisted");

        vm.startBroadcast();
        orderId = trader.createPriceOrder(
            priceFeed,
            priceThreshold,
            executeAbove,
            tokenAddr,
            amount,
            destinationSelector,
            receiverAddr,
            recipient,
            action,
            recurring,
            maxExecutions,
            deadline
        );
        vm.stopBroadcast();

        uint256 estimatedFee = trader.estimateFee(orderId);
        console.log("Price order created:", orderId);
        console.log("Estimated LINK fee:", estimatedFee);
    }
}

/// @notice Creates BALANCE_TRIGGER automated order.
contract CreateBalanceOrder is Script {
    function run() external returns (uint256 orderId) {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "CreateBalanceOrder must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        uint64 destinationSelector = uint64(vm.envUint("AUTOMATED_DESTINATION_SELECTOR"));
        address receiverAddr = vm.envAddress("AUTOMATED_RECEIVER_CONTRACT");
        address tokenAddr = vm.envAddress("AUTOMATED_TOKEN_ADDRESS");
        uint256 amount = vm.envUint("AUTOMATED_TOKEN_AMOUNT");
        address recipient = vm.envAddress("AUTOMATED_RECIPIENT");
        string memory action = vm.envString("AUTOMATED_ACTION");

        uint256 balanceRequired = vm.envUint("AUTOMATED_BALANCE_REQUIRED");
        bool recurring = vm.envOr("AUTOMATED_RECURRING", false);
        uint256 maxExecutions = vm.envOr("AUTOMATED_MAX_EXECUTIONS", uint256(1));
        uint256 deadline = vm.envOr("AUTOMATED_DEADLINE", uint256(0));

        AutomatedTrader trader = AutomatedTrader(payable(traderAddr));

        require(address(trader) != address(0), "AUTOMATED_TRADER_CONTRACT not set");
        require(destinationSelector != 0, "AUTOMATED_DESTINATION_SELECTOR not set");
        require(tokenAddr != address(0), "AUTOMATED_TOKEN_ADDRESS not set");
        require(receiverAddr != address(0), "AUTOMATED_RECEIVER_CONTRACT not set");
        require(recipient != address(0), "AUTOMATED_RECIPIENT not set");
        require(amount > 0, "AUTOMATED_TOKEN_AMOUNT must be > 0");

        require(trader.allowlistedDestinationChains(destinationSelector), "Destination selector not allowlisted");
        require(trader.allowlistedTokens(tokenAddr), "Token not allowlisted");

        vm.startBroadcast();
        orderId = trader.createBalanceOrder(
            balanceRequired,
            tokenAddr,
            amount,
            destinationSelector,
            receiverAddr,
            recipient,
            action,
            recurring,
            maxExecutions,
            deadline
        );
        vm.stopBroadcast();

        uint256 estimatedFee = trader.estimateFee(orderId);
        console.log("Balance order created:", orderId);
        console.log("Estimated LINK fee:", estimatedFee);
    }
}

/// @notice Read-only status checker for AutomatedTrader upkeep readiness.
contract CheckAutomationStatus is Script {
    function run() external view {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "CheckAutomationStatus must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        require(traderAddr != address(0), "AUTOMATED_TRADER_CONTRACT not set");

        AutomatedTrader trader = AutomatedTrader(payable(traderAddr));
        (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");

        uint256[] memory readyIds = upkeepNeeded ? abi.decode(performData, (uint256[])) : new uint256[](0);

        console.log("=============================================");
        console.log("AutomatedTrader status on", SupportedNetworks.nameByChainId(block.chainid));
        console.log("=============================================");
        console.log("Contract:       ", traderAddr);
        console.log("Forwarder:      ", trader.s_forwarderAddress());
        console.log("Active orders:  ", trader.getActiveOrderCount());
        console.log("LINK balance:   ", trader.getLinkBalance());
        console.log("Max price age:  ", trader.maxPriceAge());
        console.log("Upkeep needed:  ", upkeepNeeded);
        console.log("Ready order IDs:", readyIds.length);

        for (uint256 i = 0; i < readyIds.length; i++) {
            AutomatedTrader.TradeOrder memory order = trader.getOrder(readyIds[i]);
            console.log("- order", readyIds[i]);
            console.log("  action:", order.action);
            console.log("  recipient:", order.recipient);
        }
        console.log("=============================================");
    }
}

/// @notice Owner-side manual upkeep trigger for live validation before forwarder registration.
contract TriggerAutomationUpkeep is Script {
    function run() external {
        require(
            block.chainid == SupportedNetworks.ETHEREUM_SEPOLIA_CHAIN_ID,
            "TriggerAutomationUpkeep must run on Ethereum Sepolia"
        );

        address traderAddr = vm.envAddress("AUTOMATED_TRADER_CONTRACT");
        require(traderAddr != address(0), "AUTOMATED_TRADER_CONTRACT not set");

        AutomatedTrader trader = AutomatedTrader(payable(traderAddr));
        (bool upkeepNeeded, bytes memory performData) = trader.checkUpkeep("");
        require(upkeepNeeded, "No upkeep needed");

        vm.startBroadcast();
        trader.performUpkeep(performData);
        vm.stopBroadcast();

        console.log("Triggered performUpkeep on AutomatedTrader:", traderAddr);
    }
}
