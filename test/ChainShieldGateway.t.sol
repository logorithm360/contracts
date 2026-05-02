// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/ccip/CCIPLocalSimulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SecurityManager} from "../src/SecurityManager.sol";
import {TokenVerifier} from "../src/TokenVerifier.sol";
import {SwapAdapter} from "../src/SwapAdapter.sol";
import {ChainShieldGateway} from "../src/ChainShieldGateway.sol";

interface IFeeConfigurableRouter {
    function setFee(uint256 feeAmount) external;
}

contract MockMintableToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSwapRouter {
    using SafeERC20 for IERC20;

    struct SwapCall {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    SwapCall public lastSwap;

    function exactInputSingle(SwapCall calldata params) external returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, params.amountIn);
        lastSwap = params;
        return params.amountIn;
    }

    function getLastSwap() external view returns (SwapCall memory) {
        return lastSwap;
    }
}

contract ChainShieldGatewayTest is Test {
    CCIPLocalSimulator internal simulator;
    IRouterClient internal router;
    LinkToken internal linkToken;
    BurnMintERC677Helper internal ccipBnM;
    uint64 internal chainSelector;

    SecurityManager internal security;
    TokenVerifier internal verifier;
    MockSwapRouter internal mockSwapRouter;
    SwapAdapter internal swapAdapter;
    ChainShieldGateway internal gateway;
    MockMintableToken internal tokenIn;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant LINK_FUND = 10 ether;
    uint256 internal constant CCIP_FEE = 0.01 ether;

    function setUp() public {
        simulator = new CCIPLocalSimulator();
        (chainSelector, router,,, linkToken, ccipBnM,) = simulator.configuration();

        security = new SecurityManager();
        verifier = new TokenVerifier();
        mockSwapRouter = new MockSwapRouter();
        swapAdapter = new SwapAdapter(address(mockSwapRouter), address(this));
        gateway = new ChainShieldGateway(address(router), address(linkToken), address(this));
        tokenIn = new MockMintableToken("Mock Input", "MIN");

        gateway.configureContracts(address(security), address(verifier), address(swapAdapter));
        security.authoriseCaller(address(gateway), true);
        verifier.setAuthorisedCaller(address(gateway), true);
        swapAdapter.authoriseCaller(address(gateway), true);

        simulator.requestLinkFromFaucet(address(gateway), LINK_FUND);
        ccipBnM.drip(alice);
        ccipBnM.drip(address(mockSwapRouter));
        tokenIn.mint(alice, 5 ether);

        IFeeConfigurableRouter(address(router)).setFee(CCIP_FEE);
    }

    function test_initiateTransfer_passthroughBridge_succeeds() public {
        uint256 amount = 0.5 ether;
        uint256 aliceBefore = ccipBnM.balanceOf(alice);
        uint256 linkBefore = linkToken.balanceOf(address(gateway));

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(gateway), amount);
        bytes32 messageId =
            gateway.initiateTransfer(address(ccipBnM), address(ccipBnM), amount, bob, chainSelector, 50, 0);
        vm.stopPrank();

        assertNotEq(messageId, bytes32(0), "messageId should be non-zero");
        assertEq(ccipBnM.balanceOf(alice), aliceBefore - amount, "alice balance should decrease");
        assertEq(ccipBnM.balanceOf(bob), amount, "bob should receive bridged tokens");
        assertEq(gateway.nonces(alice), 1, "nonce should increment");
        assertLt(linkToken.balanceOf(address(gateway)), linkBefore, "gateway should pay CCIP fee in LINK");
    }

    function test_initiateTransfer_swapThenBridge_succeeds() public {
        uint256 amount = 0.5 ether;

        vm.startPrank(alice);
        tokenIn.approve(address(gateway), amount);
        bytes32 messageId =
            gateway.initiateTransfer(address(tokenIn), address(ccipBnM), amount, bob, chainSelector, 50, 3000);
        vm.stopPrank();

        MockSwapRouter.SwapCall memory swapCall = mockSwapRouter.getLastSwap();

        assertNotEq(messageId, bytes32(0), "messageId should be non-zero");
        assertEq(tokenIn.balanceOf(alice), 4.5 ether, "alice input token balance should decrease");
        assertEq(ccipBnM.balanceOf(bob), amount, "bob should receive swapped output token");
        assertEq(swapCall.tokenIn, address(tokenIn), "swap tokenIn mismatch");
        assertEq(swapCall.tokenOut, address(ccipBnM), "swap tokenOut mismatch");
        assertEq(swapCall.amountIn, amount, "swap amount mismatch");
        assertEq(swapCall.recipient, address(gateway), "swap recipient should be gateway");
    }

    function test_revertWhen_gatewayNotAuthorisedInTokenVerifier() public {
        ChainShieldGateway unauthorisedGateway =
            new ChainShieldGateway(address(router), address(linkToken), address(this));
        unauthorisedGateway.configureContracts(address(security), address(verifier), address(swapAdapter));
        security.authoriseCaller(address(unauthorisedGateway), true);
        swapAdapter.authoriseCaller(address(unauthorisedGateway), true);
        simulator.requestLinkFromFaucet(address(unauthorisedGateway), LINK_FUND);

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(unauthorisedGateway), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(TokenVerifier.NotAuthorisedCaller.selector, address(unauthorisedGateway)));
        unauthorisedGateway.initiateTransfer(address(ccipBnM), address(ccipBnM), 0.1 ether, bob, chainSelector, 50, 0);
        vm.stopPrank();
    }

    function test_revertWhen_securityPaused() public {
        security.pause("PAUSED");

        vm.startPrank(alice);
        IERC20(address(ccipBnM)).approve(address(gateway), 0.1 ether);
        vm.expectRevert(ChainShieldGateway.SystemPaused.selector);
        gateway.initiateTransfer(address(ccipBnM), address(ccipBnM), 0.1 ether, bob, chainSelector, 50, 0);
        vm.stopPrank();
    }
}
