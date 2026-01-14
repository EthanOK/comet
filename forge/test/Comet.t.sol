// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./CometHelper.sol";
import "./DecimalFormatter.sol";
import "../../contracts/Comet.sol";
import "../../contracts/CometExt.sol";
import "../../contracts/CometProxy.sol";
import "../../contracts/CometFactory.sol";
import "../../contracts/Configurator.sol";
import "../../contracts/test/Comp.sol";
import "../../contracts/test/FaucetToken.sol";
import "../../contracts/test/SimplePriceFeed.sol";
import "../../contracts/CometProxyAdmin.sol";
import "../../contracts/ConfiguratorProxy.sol";
import "../../contracts/CometConfiguration.sol";
import {CometExtAssetList} from "../../contracts/CometExtAssetList.sol";
import {AssetListFactory} from "../../contracts/AssetListFactory.sol";
import {IERC20Metadata} from "../../contracts/IERC20Metadata.sol";

contract TempCometImpl {}

contract CometTest is Test {
    address owner = makeAddr("owner");
    address governor = makeAddr("governor");
    address pauseGuardian = makeAddr("pauseGuardian");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address absorber = makeAddr("absorber");

    FaucetToken public usdc;
    SimplePriceFeed public usdcPriceFeed;
    Comp public comp;
    SimplePriceFeed public compPriceFeed;
    FaucetToken public weth;
    SimplePriceFeed public wethPriceFeed;

    Comet public cUSDCv3;
    CometExt public cUSDCv3CometExt;
    CometProxy public cometProxy;
    CometFactory public cometFactory;
    CometProxyAdmin public cometProxyAdmin;
    ConfiguratorProxy public configuratorProxy;

    CometHelper public cometHelper = new CometHelper();

    function setUp() public {
        usdc = new FaucetToken(10_000_000 * 1e6, "USDC", 6, "USDC");
        usdcPriceFeed = new SimplePriceFeed(1e8, 8);

        weth = new FaucetToken(10_000_000 * 1e18, "WETH", 18, "WETH");
        wethPriceFeed = new SimplePriceFeed(333756000000, 8);

        comp = new Comp(owner);
        compPriceFeed = new SimplePriceFeed(2708407587, 8);

        // Faucet baseToken
        deal(address(usdc), alice, 1_000_000 * 1e6);
        deal(address(usdc), charlie, 1_000_000 * 1e6);
        // Faucet assets
        deal(address(comp), bob, 100_000 * 1e18);
        deal(address(weth), bob, 10_000 * 1e18);

        cUSDCv3CometExt = new CometExt(
            CometConfiguration.ExtConfiguration({name32: "Compound USDC", symbol32: "cUSDCv3"})
        );

        cometProxyAdmin = new CometProxyAdmin(owner);

        TempCometImpl tempCometImpl = new TempCometImpl();
        cometProxy = new CometProxy(address(tempCometImpl), address(cometProxyAdmin), "");

        Configurator configuratorImpl = new Configurator();

        configuratorProxy = new ConfiguratorProxy(
            address(configuratorImpl),
            address(cometProxyAdmin),
            abi.encodeWithSelector(Configurator.initialize.selector, governor)
        );

        cometFactory = new CometFactory();

        Configurator configurator = Configurator(address(configuratorProxy));

        vm.startPrank(governor);
        configurator.setFactory(address(cometProxy), address(cometFactory));

        CometConfiguration.AssetConfig[] memory assetConfigs = new CometConfiguration.AssetConfig[](2);
        assetConfigs[0] = CometConfiguration.AssetConfig({
            asset: address(comp),
            priceFeed: address(compPriceFeed),
            decimals: 18,
            borrowCollateralFactor: 500000000000000000,
            liquidateCollateralFactor: 700000000000000000,
            liquidationFactor: 750000000000000000,
            supplyCap: 100000000000000000000000
        });

        assetConfigs[1] = CometConfiguration.AssetConfig({
            asset: address(weth),
            priceFeed: address(wethPriceFeed),
            decimals: 18,
            borrowCollateralFactor: 825000000000000000,
            liquidateCollateralFactor: 880000000000000000,
            liquidationFactor: 930000000000000000,
            supplyCap: 500000000000000000000000
        });

        configurator.setConfiguration(
            address(cometProxy),
            CometConfiguration.Configuration({
                governor: governor,
                pauseGuardian: pauseGuardian,
                baseToken: address(usdc),
                baseTokenPriceFeed: address(usdcPriceFeed),
                extensionDelegate: address(cUSDCv3CometExt),
                supplyKink: 900000000000000000,
                supplyPerYearInterestRateBase: 0,
                supplyPerYearInterestRateSlopeLow: 1141552511,
                supplyPerYearInterestRateSlopeHigh: 101344495180,
                borrowKink: 900000000000000000,
                borrowPerYearInterestRateBase: 475646879,
                borrowPerYearInterestRateSlopeLow: 880834601,
                borrowPerYearInterestRateSlopeHigh: 114155251141,
                storeFrontPriceFactor: 600000000000000000,
                trackingIndexScale: 1000000000000000,
                baseTrackingSupplySpeed: 636574074074,
                baseTrackingBorrowSpeed: 636574074074,
                baseMinForRewards: 1000000000000,
                baseBorrowMin: 100000000,
                targetReserves: 20000000000000,
                assetConfigs: assetConfigs
            })
        );

        vm.stopPrank();

        CometConfiguration.Configuration memory config = configurator.getConfiguration(address(cometProxy));

        require(config.assetConfigs.length > 0, "Asset configs are not set");

        vm.startPrank(owner);
        cometProxyAdmin.deployUpgradeToAndCall(
            Deployable(address(configuratorProxy)),
            cometProxy,
            abi.encodeWithSelector(Comet.initializeStorage.selector)
        );
        vm.stopPrank();

        cUSDCv3 = Comet(payable(address(cometProxy)));

        vm.warp(block.timestamp + 60 minutes);

        // alice supply Base asset usdc
        vm.startPrank(alice);
        usdc.approve(address(cUSDCv3), 1_000_000 * 1e6);
        cUSDCv3.supply(address(usdc), 1_000_000 * 1e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 60 minutes);

        // bob supply Collateral asset comp
        vm.startPrank(bob);
        comp.approve(address(cUSDCv3), 10_000 * 1e18);
        cUSDCv3.supply(address(comp), 10_000 * 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 60 minutes);
    }

    function test_AfterDeploymentCometInfos() public {
        _log_comet_infos();
    }

    function _log_comet_infos() internal view {
        console.log("reserves", (cUSDCv3.getReserves()));
        uint256 utilization = cUSDCv3.getUtilization();
        console.log("utilization", utilization);
        console.log("supplyRate", cUSDCv3.getSupplyRate(utilization));
        console.log("borrowRate", cUSDCv3.getBorrowRate(utilization));
        console.log("totalSupply", cUSDCv3.totalSupply());
        console.log("totalBorrow", cUSDCv3.totalBorrow());
        console.log("`````````````````````````````");
    }

    function test_RevertIfBorrowBaseTokenLessThanBaseBorrowMin() public {
        uint256 baseBorrowMin = cUSDCv3.baseBorrowMin();
        vm.expectRevert(abi.encodeWithSelector(CometMainInterface.BorrowTooSmall.selector));
        vm.startPrank(bob);
        cUSDCv3.withdraw(address(usdc), baseBorrowMin - 1);
        vm.stopPrank();
    }

    function test_BorrowBaseToken() public {
        console.log("borrowableBaseAmount", cometHelper.getBorrowableBaseAmount(address(cUSDCv3), bob));

        vm.startPrank(bob);

        console.log("borrowing ......");
        cUSDCv3.withdraw(address(usdc), 100_000 * 1e6);
        vm.stopPrank();

        console.log("borrowedBaseAmount", cUSDCv3.borrowBalanceOf(bob));

        console.log("borrowableBaseAmount", cometHelper.getBorrowableBaseAmount(address(cUSDCv3), bob));

        _log_comet_infos();
    }

    function test_Liquidate() public {
        test_BorrowBaseToken();

        vm.warp(block.timestamp + 60 minutes);

        (, int price, , , ) = compPriceFeed.latestRoundData();

        compPriceFeed.setRoundData(1, (price * 50) / 100, block.timestamp, block.timestamp, 1);

        require(cUSDCv3.isLiquidatable(bob), "bob is not liquidatable");

        uint256 balance_before = cUSDCv3.balanceOf(bob);

        console.log("liquidating ......");

        vm.startPrank(absorber);
        address[] memory accounts = new address[](1);
        accounts[0] = bob;
        cUSDCv3.absorb(absorber, accounts);
        vm.stopPrank();

        uint256 balance_after = cUSDCv3.balanceOf(bob);
        uint256 refund_liquidation = balance_after - balance_before;

        console.log(
            "Refund: %s %s as Supply",
            DecimalFormatter.formatToString(refund_liquidation, IERC20Metadata(address(cUSDCv3)).decimals(), 6),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        _log_comet_infos();
    }

    function test_BuyCollateral() public {
        test_Liquidate();

        vm.warp(block.timestamp + 10 minutes);

        uint256 collateralReserves = cUSDCv3.getCollateralReserves(address(comp));

        console.log("collateralReserves", collateralReserves);

        uint256 baseAmount = cometHelper.quoteBaseForCollateral(address(cUSDCv3), address(comp), collateralReserves);
        console.log("baseAmount", baseAmount);

        uint256 collateralAmount = cometHelper.quoteCollateralForBase(address(cUSDCv3), address(comp), baseAmount);

        console.log("collateralAmount", collateralAmount);

        uint256 minAmount = (collateralAmount * 99) / 100;

        console.log("buyCollateral ......");

        console.log(
            "Pay: %s %s",
            DecimalFormatter.formatToString(baseAmount, IERC20Metadata(cUSDCv3.baseToken()).decimals(), 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );

        uint256 balance_before = comp.balanceOf(charlie);

        vm.startPrank(charlie);
        usdc.approve(address(cUSDCv3), type(uint256).max);
        cUSDCv3.buyCollateral(address(comp), minAmount, baseAmount, charlie);
        vm.stopPrank();

        uint256 balance_after = comp.balanceOf(charlie);

        uint256 received_comp = balance_after - balance_before;
        uint256 receivedValue = cometHelper.quoteBaseForCollateralNoDiscount(
            address(cUSDCv3),
            address(comp),
            received_comp
        );

        console.log(
            "Received: %s %s",
            DecimalFormatter.formatToString(received_comp, IERC20Metadata(address(comp)).decimals(), 6),
            IERC20Metadata(address(comp)).symbol()
        );

        console.log(
            "Received Value: %s %s",
            DecimalFormatter.formatToString(receivedValue, IERC20Metadata(cUSDCv3.baseToken()).decimals(), 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );

        uint256 profit = receivedValue - baseAmount;
        console.log(
            "Profit: %s %s",
            DecimalFormatter.formatToString(profit, IERC20Metadata(cUSDCv3.baseToken()).decimals(), 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );

        _log_comet_infos();
    }
}
