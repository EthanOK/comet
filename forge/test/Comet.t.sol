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
import "../../contracts/bulkers/MainnetBulker.sol";
import {CometExtAssetList} from "../../contracts/CometExtAssetList.sol";
import {AssetListFactory} from "../../contracts/AssetListFactory.sol";
import {IERC20Metadata} from "../../contracts/IERC20Metadata.sol";
import {IERC20} from "../../contracts/IERC20.sol";

contract TempCometImpl {}

contract CometTest is Test {
    uint64 internal constant SECONDS_PER_YEAR = 31_536_000;

    address USDC_ADDRESS = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant WETH_ADDRESS = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant WSTETH_ADDRESS = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    address owner = makeAddr("owner");
    address governor = makeAddr("governor");
    address pauseGuardian = makeAddr("pauseGuardian");

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address absorber = makeAddr("absorber");

    IERC20 public usdc;
    SimplePriceFeed public usdcPriceFeed;
    Comp public comp;
    SimplePriceFeed public compPriceFeed;
    IWETH9 public weth;
    SimplePriceFeed public wethPriceFeed;

    Comet public cUSDCv3;
    CometExt public cUSDCv3CometExt;
    CometProxy public cometProxy;
    CometFactory public cometFactory;
    CometProxyAdmin public cometProxyAdmin;
    ConfiguratorProxy public configuratorProxy;
    MainnetBulker public bulker;

    CometHelper public cometHelper;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_QUICKNODE_LINK"));

        usdc = IERC20(USDC_ADDRESS);
        usdcPriceFeed = new SimplePriceFeed(1e8, 8);

        weth = IWETH9(payable(WETH_ADDRESS));
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
                supplyPerYearInterestRateSlopeLow: 1141552511 * SECONDS_PER_YEAR,
                supplyPerYearInterestRateSlopeHigh: 101344495180 * SECONDS_PER_YEAR,
                borrowKink: 900000000000000000,
                borrowPerYearInterestRateBase: 475646879 * SECONDS_PER_YEAR,
                borrowPerYearInterestRateSlopeLow: 880834601 * SECONDS_PER_YEAR,
                borrowPerYearInterestRateSlopeHigh: 114155251141 * SECONDS_PER_YEAR,
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

        bulker = new MainnetBulker(owner, payable(WETH_ADDRESS), WSTETH_ADDRESS);

        cometHelper = new CometHelper();

        vm.warp(block.timestamp + 2 days);

        // alice supply Base asset usdc
        vm.startPrank(alice);
        usdc.approve(address(cUSDCv3), 200_000 * 1e6);
        cUSDCv3.supply(address(usdc), 200_000 * 1e6);
        vm.stopPrank();

        console.log(
            "Alice Balance: %s %s",
            DecimalFormatter.formatToString(cUSDCv3.balanceOf(alice), IERC20Metadata(address(cUSDCv3)).decimals(), 6),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        vm.warp(block.timestamp + 2 days);
    }

    function test_AfterDeploymentCometInfos() public view {
        _log_comet_infos();
    }

    function _log_comet_infos() internal view {
        uint8 baseTokenDecimals = IERC20Metadata(cUSDCv3.baseToken()).decimals();
        console.log(
            "reserves: %s %s",
            DecimalFormatter.formatToString(cUSDCv3.getReserves(), baseTokenDecimals, 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );
        uint256 utilization = cUSDCv3.getUtilization();
        console.log("utilization:", DecimalFormatter.formatToString(utilization, 18, 6));
        console.log(
            "supplyRate Per Year:",
            DecimalFormatter.formatToString(cUSDCv3.getSupplyRate(utilization) * SECONDS_PER_YEAR, 18, 6)
        );
        console.log(
            "borrowRate Per Year:",
            DecimalFormatter.formatToString(cUSDCv3.getBorrowRate(utilization) * SECONDS_PER_YEAR, 18, 6)
        );
        console.log(
            "totalSupply: %s %s",
            DecimalFormatter.formatToString(cUSDCv3.totalSupply(), baseTokenDecimals, 6),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );
        console.log(
            "totalBorrow: %s %s",
            DecimalFormatter.formatToString(cUSDCv3.totalBorrow(), baseTokenDecimals, 6),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );
        console.log(
            "Alice Balance: %s %s",
            DecimalFormatter.formatToString(cUSDCv3.balanceOf(alice), IERC20Metadata(address(cUSDCv3)).decimals(), 6),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        console.log("`````````````````````````````");
    }

    function test_RevertIfBorrowBaseTokenLessThanBaseBorrowMin() public {
        uint256 baseBorrowMin = cUSDCv3.baseBorrowMin();
        vm.expectRevert(abi.encodeWithSelector(CometMainInterface.BorrowTooSmall.selector));
        vm.startPrank(bob);
        cUSDCv3.withdraw(address(usdc), baseBorrowMin - 1);
        vm.stopPrank();
    }

    function test_CollateralAndBorrowBaseToken() public {
        // 1: bob supply Collateral asset comp
        vm.startPrank(bob);
        console.log(" collateralizing ......");
        comp.approve(address(cUSDCv3), 10_000 * 1e18);
        cUSDCv3.supply(address(comp), 10_000 * 1e18);
        vm.stopPrank();

        console.log(
            "borrowableBaseAmount: %s %s",
            DecimalFormatter.formatToString(
                cometHelper.getBorrowableBaseAmount(address(cUSDCv3), bob),
                IERC20Metadata(address(cUSDCv3)).decimals(),
                6
            ),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );
        // 2: bob borrow base token usdc
        vm.startPrank(bob);
        console.log("borrowing ......");
        cUSDCv3.withdraw(address(usdc), 100_000 * 1e6);
        vm.stopPrank();

        console.log(
            "borrowedBaseAmount: %s %s",
            DecimalFormatter.formatToString(
                cUSDCv3.borrowBalanceOf(bob),
                IERC20Metadata(address(cUSDCv3)).decimals(),
                6
            ),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        console.log(
            "borrowableBaseAmount: %s %s",
            DecimalFormatter.formatToString(
                cometHelper.getBorrowableBaseAmount(address(cUSDCv3), bob),
                IERC20Metadata(address(cUSDCv3)).decimals(),
                6
            ),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        _log_comet_infos();

        vm.warp(block.timestamp + 2 days);

        // 3: bob collateral COMP and borrow base token usdc in single transaction

        vm.startPrank(bob);
        console.log("collateralizing and borrowing ......");
        bytes32[] memory actions = new bytes32[](2);
        actions[0] = bulker.ACTION_SUPPLY_ASSET();
        actions[1] = bulker.ACTION_WITHDRAW_ASSET();

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encode(address(cUSDCv3), bob, address(comp), 10_000 * 1e18);
        datas[1] = abi.encode(address(cUSDCv3), bob, address(usdc), 100_000 * 1e6);

        vm.startPrank(bob);
        // allow bulker to manage bob's account
        CometExt(address(cUSDCv3)).allow(address(bulker), true);
        comp.approve(address(cUSDCv3), 10_000 * 1e18);

        bulker.invoke(actions, datas);
        vm.stopPrank();
        console.log(
            "borrowedBaseAmount: %s %s",
            DecimalFormatter.formatToString(
                cUSDCv3.borrowBalanceOf(bob),
                IERC20Metadata(address(cUSDCv3)).decimals(),
                6
            ),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        console.log(
            "borrowableBaseAmount: %s %s",
            DecimalFormatter.formatToString(
                cometHelper.getBorrowableBaseAmount(address(cUSDCv3), bob),
                IERC20Metadata(address(cUSDCv3)).decimals(),
                6
            ),
            IERC20Metadata(address(cUSDCv3)).symbol()
        );

        _log_comet_infos();
    }

    function test_Liquidate_Refunded() public {
        test_CollateralAndBorrowBaseToken();

        vm.warp(block.timestamp + 2 days);

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

    function test_BuyCollateral_WhenLiquidatedRefunded() public {
        test_Liquidate_Refunded();

        vm.warp(block.timestamp + 2 days);

        uint256 collateralReserves = cUSDCv3.getCollateralReserves(address(comp));

        console.log(
            "collateralReserves: %s %s",
            DecimalFormatter.formatToString(collateralReserves, IERC20Metadata(address(comp)).decimals(), 6),
            IERC20Metadata(address(comp)).symbol()
        );

        uint256 baseAmount = cometHelper.quoteBaseForCollateral(address(cUSDCv3), address(comp), collateralReserves);
        console.log(
            "need to pay baseAmount: %s %s",
            DecimalFormatter.formatToString(baseAmount, IERC20Metadata(cUSDCv3.baseToken()).decimals(), 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );

        uint256 collateralAmount = cometHelper.quoteCollateralForBase(address(cUSDCv3), address(comp), baseAmount);

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

    function test_Liquidate_NotRefunded() public {
        test_CollateralAndBorrowBaseToken();

        vm.warp(block.timestamp + 2 days);

        (, int price, , , ) = compPriceFeed.latestRoundData();

        // Comp stocks plummeted, collateral failed to cover loans
        compPriceFeed.setRoundData(1, (price * 40) / 100, block.timestamp, block.timestamp, 1);

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

    function test_BuyCollateral_WhenLiquidatedNotRefunded() public {
        test_Liquidate_NotRefunded();

        vm.warp(block.timestamp + 2 days);

        uint256 collateralReserves = cUSDCv3.getCollateralReserves(address(comp));

        console.log(
            "collateralReserves: %s %s",
            DecimalFormatter.formatToString(collateralReserves, IERC20Metadata(address(comp)).decimals(), 6),
            IERC20Metadata(address(comp)).symbol()
        );

        uint256 baseAmount = cometHelper.quoteBaseForCollateral(address(cUSDCv3), address(comp), collateralReserves);
        console.log(
            "need to pay baseAmount: %s %s",
            DecimalFormatter.formatToString(baseAmount, IERC20Metadata(cUSDCv3.baseToken()).decimals(), 6),
            IERC20Metadata(cUSDCv3.baseToken()).symbol()
        );

        uint256 collateralAmount = cometHelper.quoteCollateralForBase(address(cUSDCv3), address(comp), baseAmount);

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

// forge test --match-contract CometTest --match-test test_BuyCollateral -vvv
// forge test --match-contract CometTest -vvv
