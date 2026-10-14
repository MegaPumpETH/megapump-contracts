// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

bytes4 constant MAGIC = 0x1626ba7e;


contract Valid1271 {
    address public immutable sessionKey;
    constructor(address _key) { sessionKey = _key; }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(hash, sig) == sessionKey ? MAGIC : bytes4(0);
    }
    receive() external payable {}
}


contract AlwaysValid1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return MAGIC;
    }
    receive() external payable {}
}


contract Reverting1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("nope");
    }
}


contract Malleable1271 {
    address public immutable sessionKey;
    constructor(address _key) { sessionKey = _key; }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (bytes memory realSig, ) = abi.decode(sig, (bytes, uint256));
        return ECDSA.recover(hash, realSig) == sessionKey ? MAGIC : bytes4(0);
    }
    receive() external payable {}
}


contract ReturndataBomb1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        assembly { return(0, 1000000) }
    }
}