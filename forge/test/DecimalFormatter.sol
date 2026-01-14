// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

library DecimalFormatter {
    /// @notice Format a raw value to a string with a given number of decimals and display decimals
    /// @param rawValue 1600000
    /// @param decimals 6
    /// @param displayDecimals 2
    /// @return "1.60"
    function formatToString(
        uint256 rawValue,
        uint8 decimals,
        uint8 displayDecimals
    ) public pure returns (string memory) {
        uint256 integerPart = rawValue / (10 ** decimals);

        uint256 remainder = rawValue % (10 ** decimals);
        uint256 fractionalPart = remainder / (10 ** (decimals - displayDecimals));

        string memory fractionalStr = _fractionalToString(fractionalPart, displayDecimals);

        return string(abi.encodePacked(_uintToString(integerPart), ".", fractionalStr));
    }

    function _fractionalToString(uint256 fractional, uint8 width) internal pure returns (string memory) {
        string memory str = _uintToString(fractional);
        uint256 len = bytes(str).length;

        if (len >= width) return str;

        bytes memory leadingZeros = new bytes(width - len);
        for (uint256 i = 0; i < width - len; i++) {
            leadingZeros[i] = "0";
        }

        return string(abi.encodePacked(leadingZeros, str));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;

        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
