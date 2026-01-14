// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/CometMainInterface.sol";
import "../../contracts/CometExtInterface.sol";
import "../../contracts/CometCore.sol";
import "../../contracts/CometMath.sol";
import "../../contracts/CometStorage.sol";

contract CometHelper is CometMath {
    uint64 internal constant FACTOR_SCALE = 1e18;
    /// @dev The scale for base index (depends on time/rate scales, not base token)
    uint64 internal constant BASE_INDEX_SCALE = 1e15;

    /**
     * @notice Query the current borrowable base amount of an account
     * @param comet_ The comet contract address
     * @param account The account whose borrowable base amount to query
     * @return The borrowable base amount of the account
     */
    function getBorrowableBaseAmount(address comet_, address account) public view returns (uint256) {
        CometMainInterface comet = CometMainInterface(payable(comet_));

        CometExtInterface cometExt = CometExtInterface(comet_);

        CometStorage.TotalsBasic memory totalsBasic = cometExt.totalsBasic();

        uint64 baseSupplyIndex = totalsBasic.baseSupplyIndex;
        uint64 baseBorrowIndex = totalsBasic.baseBorrowIndex;
        (int104 principal, , , uint16 assetsIn, ) = comet.userBasic(account);

        int liquidity = signedMulPrice(
            presentValue(principal, baseSupplyIndex, baseBorrowIndex),
            comet.getPrice(comet.baseTokenPriceFeed()),
            uint64(comet.baseScale())
        );

        for (uint8 i = 0; i < comet.numAssets(); ) {
            if (isInAsset(assetsIn, i)) {
                CometCore.AssetInfo memory asset = comet.getAssetInfo(i);

                (uint128 balance, ) = comet.userCollateral(account, asset.asset);

                uint newAmount = mulPrice(balance, comet.getPrice(asset.priceFeed), asset.scale);
                liquidity += signed256(mulFactor(newAmount, asset.borrowCollateralFactor));
            }
            unchecked {
                i++;
            }
        }

        uint256 totalBaseValue = liquidity >= 0 ? uint256(liquidity) : 0;
        return divPrice(totalBaseValue, comet.getPrice(comet.baseTokenPriceFeed()), uint64(comet.baseScale()));
    }

    /**
     * @notice Gets the quote for a collateral asset in exchange for an amount of base asset
     * @param comet_ The comet contract address
     * @param asset The collateral asset to get the quote for
     * @param collateralAmount The amount of the collateral asset to get the quote for
     * @return baseAmount The amount of the base asset to get the quote for
     */
    function quoteBaseForCollateral(
        address comet_,
        address asset,
        uint collateralAmount
    ) public view returns (uint baseAmount) {
        CometMainInterface comet = CometMainInterface(payable(comet_));
        CometCore.AssetInfo memory assetInfo = comet.getAssetInfoByAddress(asset);
        uint256 assetPrice = comet.getPrice(assetInfo.priceFeed);
        // Store front discount is derived from the collateral asset's liquidationFactor and storeFrontPriceFactor
        // discount = storeFrontPriceFactor * (1e18 - liquidationFactor)
        uint256 discountFactor = mulFactor(comet.storeFrontPriceFactor(), FACTOR_SCALE - assetInfo.liquidationFactor);
        uint256 assetPriceDiscounted = mulFactor(assetPrice, FACTOR_SCALE - discountFactor);
        uint256 basePrice = comet.getPrice(comet.baseTokenPriceFeed());

        baseAmount = (collateralAmount * assetPriceDiscounted * comet.baseScale()) / basePrice / assetInfo.scale;
    }

    /**
     * @notice Gets the quote for a base asset in exchange for an amount of collateral asset without discount
     * @param comet_ The comet contract address
     * @param asset The collateral asset to get the quote for
     * @param collateralAmount The amount of the collateral asset to get the quote for
     * @return baseAmount The amount of the base asset to get the quote for
     */
    function quoteBaseForCollateralNoDiscount(
        address comet_,
        address asset,
        uint collateralAmount
    ) public view returns (uint baseAmount) {
        CometMainInterface comet = CometMainInterface(payable(comet_));
        CometCore.AssetInfo memory assetInfo = comet.getAssetInfoByAddress(asset);
        uint256 assetPrice = comet.getPrice(assetInfo.priceFeed);
        // Store front discount is derived from the collateral asset's liquidationFactor and storeFrontPriceFactor
        // discount = storeFrontPriceFactor * (1e18 - liquidationFactor)
        // uint256 discountFactor = mulFactor(comet.storeFrontPriceFactor(), FACTOR_SCALE - assetInfo.liquidationFactor);
        uint256 assetPriceDiscounted = mulFactor(assetPrice, FACTOR_SCALE - 0);
        uint256 basePrice = comet.getPrice(comet.baseTokenPriceFeed());

        baseAmount = (collateralAmount * assetPriceDiscounted * comet.baseScale()) / basePrice / assetInfo.scale;
    }

    /**
     * @notice Gets the quote for a base asset in exchange for an amount of collateral asset
     * @param comet_ The comet contract address
     * @param asset The collateral asset to get the quote for
     * @param baseAmount The amount of the base asset to get the quote for
     * @return collateralAmount The quote in terms of the collateral asset
     */
    function quoteCollateralForBase(
        address comet_,
        address asset,
        uint baseAmount
    ) public view returns (uint collateralAmount) {
        CometMainInterface comet = CometMainInterface(payable(comet_));
        return comet.quoteCollateral(asset, baseAmount);
    }

    function signedMulPrice(int n, uint price, uint64 fromScale) internal pure returns (int) {
        return (n * signed256(price)) / int256(uint256(fromScale));
    }
    function presentValue(
        int104 principalValue_,
        uint64 baseSupplyIndex_,
        uint64 baseBorrowIndex_
    ) internal pure returns (int256) {
        if (principalValue_ >= 0) {
            return signed256(presentValueSupply(baseSupplyIndex_, uint104(principalValue_)));
        } else {
            return -signed256(presentValueBorrow(baseBorrowIndex_, uint104(-principalValue_)));
        }
    }
    function isInAsset(uint16 assetsIn, uint8 assetOffset) internal pure returns (bool) {
        return (assetsIn & (uint16(1) << assetOffset) != 0);
    }
    function mulPrice(uint n, uint price, uint64 fromScale) internal pure returns (uint) {
        return (n * price) / fromScale;
    }

    function mulFactor(uint n, uint factor) internal pure returns (uint) {
        return (n * factor) / FACTOR_SCALE;
    }

    function divPrice(uint n, uint price, uint64 toScale) internal pure returns (uint) {
        return (n * toScale) / price;
    }

    function presentValueSupply(uint64 baseSupplyIndex_, uint104 principalValue_) internal pure returns (uint256) {
        return (uint256(principalValue_) * baseSupplyIndex_) / BASE_INDEX_SCALE;
    }

    /**
     * @dev The principal amount projected forward by the borrow index
     */
    function presentValueBorrow(uint64 baseBorrowIndex_, uint104 principalValue_) internal pure returns (uint256) {
        return (uint256(principalValue_) * baseBorrowIndex_) / BASE_INDEX_SCALE;
    }
}
