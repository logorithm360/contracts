// SPDX-License-Identifier: MIT
pragma solidity =0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IChainShieldGatewayFunding {
    function depositLink(uint256 amount) external;
    function getLinkBalance() external view returns (uint256);
}

/// @notice Approves Sepolia LINK and deposits it into the deployed ChainShield gateway.
/// @dev Required env:
///      - CHAINSHIELD_LINK_FUND_AMOUNT (in wei, e.g. 1000000000000000000 for 1 LINK)
/// @dev Optional env:
///      - PRIVATE_KEY (falls back to CRE_ETH_PRIVATE_KEY used elsewhere in this repo)
///      - CHAINSHIELD_GATEWAY (defaults to the Sepolia gateway already recorded in DEPLOYED_ADDRESSES.md)
contract FundChainShieldLink is Script {
    address internal constant LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address internal constant DEFAULT_GATEWAY = 0x8962652717Fa57fD8e53a1d91D00abF57E37fa5f;

    function run() external {
        uint256 privateKey;
        if (vm.envExists("PRIVATE_KEY")) {
            privateKey = vm.envUint("PRIVATE_KEY");
        } else {
            // Reuse the repo's existing deployer key name when PRIVATE_KEY is not exported.
            privateKey = vm.envUint("CRE_ETH_PRIVATE_KEY");
        }
        uint256 amount = vm.envUint("CHAINSHIELD_LINK_FUND_AMOUNT");
        address gateway = vm.envOr("CHAINSHIELD_GATEWAY", DEFAULT_GATEWAY);
        address funder = vm.addr(privateKey);

        uint256 linkBefore = IChainShieldGatewayFunding(gateway).getLinkBalance();
        uint256 walletLink = IERC20(LINK_TOKEN).balanceOf(funder);

        console.log("Funding wallet:      ", funder);
        console.log("Gateway:             ", gateway);
        console.log("Sepolia LINK token:  ", LINK_TOKEN);
        console.log("Wallet LINK balance: ", walletLink);
        console.log("Gateway LINK before: ", linkBefore);
        console.log("Funding amount:      ", amount);

        vm.startBroadcast(privateKey);
        IERC20(LINK_TOKEN).approve(gateway, amount);
        IChainShieldGatewayFunding(gateway).depositLink(amount);
        vm.stopBroadcast();

        uint256 linkAfter = IChainShieldGatewayFunding(gateway).getLinkBalance();

        console.log("Gateway LINK after:  ", linkAfter);
        console.log("Added LINK:          ", linkAfter - linkBefore);
    }
}
