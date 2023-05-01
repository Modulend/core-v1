// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.19;

import "lib/tractor/Tractor.sol";
import "src/LibUtil.sol";

import {Order, Fill, Agreement, LibBookkeeper} from "src/bookkeeper/LibBookkeeper.sol";
import {C} from "src/C.sol";
import "src/modules/oracle/IOracle.sol";
import {IAccount} from "src/modules/account/IAccount.sol";
import {IPosition} from "src/terminal/IPosition.sol";
import {ITerminal} from "src/terminal/ITerminal.sol";
import {ILiquidator} from "src/modules/liquidator/ILiquidator.sol";
import {Utils} from "src/LibUtil.sol";

// NOTE bookkeeper will be far more difficult to update / fix / expand than any of the modules. For this reason
//      simplicity should be aggressively pursued.
//      It should also *not* have any asset transfer logic, bc then it requires compatibility with any assets that
//      modules might implement.

// NOTE enabling partial fills would benefit from on-chain validation of orders so that each taker does not need
//      to pay gas to independently verify. Verified orders could be signed by Tractor.

/**
 * @notice An Order is a standing offer to take one side of a position within a set of parameters. Orders can
 *  represent both lenders and borrowers. Capital to back an order is held in an Account, though the Account may
 *  not have enough assets.
 *
 *  An Order can be created at no cost by signing a transaction with the signature of the Order. An Operator can
 *  create a compatible Position between two compatible Orders, which will be verified at Position creation.
 */
contract Bookkeeper is Tractor {
    enum BlueprintDataType {
        ORDER,
        AGREEMENT
    }

    string constant PROTOCOL_NAME = "modulus";
    string constant PROTOCOL_VERSION = "1.0.0";

    event OrderFilled(Agreement agreement, bytes32 blueprintHash, address operator);
    event LiquidationKicked(address liquidator, address position);

    constructor() Tractor(PROTOCOL_NAME, PROTOCOL_VERSION) {}

    function fillOrder(
        Fill calldata fill,
        SignedBlueprint calldata orderBlueprint,
        ModuleReference calldata takerAccount
    ) external verifySignature(orderBlueprint) {
        // decode order blueprint data and ensure blueprint metadata is valid pairing with embedded data
        (bytes1 blueprintDataType, bytes memory blueprintData) = decodeDataField(orderBlueprint.blueprint.data);
        require(uint8(blueprintDataType) == uint8(BlueprintDataType.ORDER));
        Order memory order = abi.decode(blueprintData, (Order));
        require(orderBlueprint.blueprint.publisher == Utils.getAccountOwner(order.account));
        if (order.takers.length > 0) {
            require(order.takers[fill.takerIdx] == msg.sender, "Bookkeeper: Invalid taker");
        }

        Agreement memory agreement = agreementFromOrder(fill, order);
        if (order.isOffer) {
            agreement.lenderAccount = order.account;
            agreement.borrowerAccount = takerAccount;
            agreement.collateralAmount = fill.loanAmount * fill.borrowerConfig.initCollateralRatio / C.RATIO_FACTOR; // NOTE rounding?
            agreement.position.parameters = fill.borrowerConfig.positionParameters;
        } else {
            agreement.lenderAccount = takerAccount;
            agreement.borrowerAccount = order.account;
            agreement.collateralAmount = fill.loanAmount * order.borrowerConfig.initCollateralRatio / C.RATIO_FACTOR; // NOTE rounding?
            agreement.position.parameters = order.borrowerConfig.positionParameters;
        }
        // Set Position data that cannot be computed off chain by caller.
        agreement.deploymentTime = block.timestamp;
        agreement.positionAddr = ITerminal(agreement.position.addr).createPosition(
            agreement.loanAsset, agreement.loanAmount, agreement.position.parameters
        );

        emit OrderFilled(agreement, orderBlueprint.blueprintHash, msg.sender);
        signPublishAgreement(agreement);
    }

    function kick(SignedBlueprint calldata agreementBlueprint) external verifySignature(agreementBlueprint) {
        (bytes1 blueprintDataType, bytes memory blueprintData) = decodeDataField(agreementBlueprint.blueprint.data);
        require(blueprintDataType == bytes1(uint8(BlueprintDataType.AGREEMENT)), "BKKIBDT");
        Agreement memory agreement = abi.decode(blueprintData, (Agreement));
        IPosition position = IPosition(agreement.positionAddr);

        // Cannot liquidate if not owned by protocol (liquidating/liquidated/exited).
        require(position.hasRole(C.CONTROLLER_ROLE, address(this)), "Position not owned by protocol");

        require(LibBookkeeper.isLiquidatable(agreement), "Bookkeeper: Position is not liquidatable");
        // Transfer ownership of the position to the liquidator, which includes collateral.
        position.transferContract(agreement.liquidator.addr);
        // Kick the position to begin liquidation.
        // ILiquidator(agreement.liquidator.addr).takeKick(agreementBlueprint.blueprintHash);
        emit LiquidationKicked(agreement.liquidator.addr, agreement.positionAddr);
    }

    // NOTE This puts the assets back into circulating via accounts. Should implement an option to send assets to
    //      a static account.
    function exitPosition(SignedBlueprint calldata agreementBlueprint) external verifySignature(agreementBlueprint) {
        (bytes1 blueprintDataType, bytes memory blueprintData) = decodeDataField(agreementBlueprint.blueprint.data);
        require(
            blueprintDataType == bytes1(uint8(BlueprintDataType.AGREEMENT)), "Bookkeeper: Invalid blueprint data type"
        );
        Agreement memory agreement = abi.decode(blueprintData, (Agreement));
        require(
            msg.sender == IAccount(agreement.borrowerAccount.addr).getOwner(agreement.borrowerAccount.parameters),
            "Bookkeeper: Only borrower can exit position without liquidation"
        );

        uint256 unpaidAmount = IPosition(agreement.positionAddr).exit(agreement, agreement.position.parameters);

        // Borrower must pay difference directly if there is not enough value to pay Lender.
        if (unpaidAmount > 0) {
            // Requires sender to have already approved account contract to use necessary assets.
            IAccount(payable(agreement.borrowerAccount.addr)).addAssetBookkeeper{
                value: Utils.isEth(agreement.loanAsset) ? unpaidAmount : 0
            }(msg.sender, agreement.loanAsset, unpaidAmount, agreement.lenderAccount.parameters);
        }
    }

    /// @dev assumes compatibility between match, offer, and request already verified.
    function agreementFromOrder(Fill calldata fill, Order memory order)
        private
        pure
        returns (Agreement memory agreement)
    {
        // NOTE this is prly not gas efficient bc of zero -> non-zero changes...
        agreement.maxDuration = order.maxDuration;
        agreement.assessor = order.assessor;
        agreement.liquidator = order.liquidator;

        agreement.loanAsset = order.loanAssets[fill.loanAssetIdx];
        agreement.loanOracle = order.loanOracles[fill.loanOracleIdx];
        agreement.collateralAsset = order.collateralAssets[fill.collateralAssetIdx];
        agreement.collateralOracle = order.collateralOracles[fill.collateralOracleIdx];
        agreement.position.addr = order.terminals[fill.terminalIdx];

        require(fill.loanAmount >= order.minLoanAmounts[fill.loanAssetIdx], "Bookkeeper: fill loan amount too small");
        agreement.loanAmount = fill.loanAmount;
    }

    function signPublishAgreement(Agreement memory agreement) private {
        // Create blueprint to store signed Agreement off chain via events.
        SignedBlueprint memory signedBlueprint;
        signedBlueprint.blueprint.publisher = address(this);
        signedBlueprint.blueprint.data =
            encodeDataField(bytes1(uint8(BlueprintDataType.AGREEMENT)), abi.encode(agreement));
        signedBlueprint.blueprint.endTime = type(uint256).max;
        signedBlueprint.blueprintHash = getBlueprintHash(signedBlueprint.blueprint);
        // NOTE: Security: Is is possible to intentionally manufacture a blueprint with different data that creates the same hash?
        signBlueprint(signedBlueprint.blueprintHash);
        publishBlueprint(signedBlueprint); // These verifiable blueprints will be used to interact with positions.
    }
}
