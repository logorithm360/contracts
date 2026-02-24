// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {TokenVerifier} from "../src/TokenVerifier.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1_000_000 ether;
}

contract BadDecimalsToken {
    string public name = "Bad";
    string public symbol = "BAD";
    uint8 public decimals = 0;
    uint256 public totalSupply = 100;
}

contract ZeroSupplyToken {
    string public name = "Zero";
    string public symbol = "ZERO";
    uint8 public decimals = 18;
    uint256 public totalSupply = 0;
}

contract NoInterfaceToken {
    uint256 public x = 1;
}

contract AuthorisedCaller {
    TokenVerifier internal verifier;

    constructor(address verifier_) {
        verifier = TokenVerifier(verifier_);
    }

    function check(address token, uint256 amount) external returns (bool) {
        return verifier.isTransferSafe(token, amount);
    }
}

contract TokenVerifierTest is Test {
    TokenVerifier internal verifier;
    MockERC20 internal goodToken;
    BadDecimalsToken internal badDecimals;
    ZeroSupplyToken internal zeroSupply;
    NoInterfaceToken internal noInterface;
    AuthorisedCaller internal caller;

    function setUp() public {
        verifier = new TokenVerifier();
        goodToken = new MockERC20();
        badDecimals = new BadDecimalsToken();
        zeroSupply = new ZeroSupplyToken();
        noInterface = new NoInterfaceToken();
        caller = new AuthorisedCaller(address(verifier));
        verifier.setAuthorisedCaller(address(caller), true);
    }

    function test_allowlistedTokenPasses() public {
        verifier.addToAllowlist(address(goodToken), true);
        assertEq(uint8(verifier.getStatus(address(goodToken))), uint8(TokenVerifier.VerificationStatus.ALLOWLISTED));
        assertTrue(caller.check(address(goodToken), 1 ether));
    }

    function test_blocklistedTokenFails() public {
        verifier.addToBlocklist(address(goodToken), "BLOCK");
        assertFalse(caller.check(address(goodToken), 1 ether));
    }

    function test_revertWhenCallerNotAuthorised() public {
        vm.expectRevert(abi.encodeWithSelector(TokenVerifier.NotAuthorisedCaller.selector, address(this)));
        verifier.isTransferSafe(address(goodToken), 1 ether);
    }

    function test_layer1RejectsBadTokenShapes() public {
        vm.expectRevert(abi.encodeWithSelector(TokenVerifier.InvalidDecimals.selector, address(badDecimals), uint8(0)));
        verifier.verifyTokenLayer1(address(badDecimals));

        vm.expectRevert(abi.encodeWithSelector(TokenVerifier.ZeroTotalSupply.selector, address(zeroSupply)));
        verifier.verifyTokenLayer1(address(zeroSupply));

        vm.expectRevert(abi.encodeWithSelector(TokenVerifier.InvalidERC20.selector, address(noInterface)));
        verifier.verifyTokenLayer1(address(noInterface));
    }

    function test_limitBlocksAmount() public {
        verifier.setMaxTransferLimit(address(goodToken), 10);
        assertFalse(caller.check(address(goodToken), 11));
        assertTrue(caller.check(address(goodToken), 9));
    }
}
