// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IAtsHold } from "./interfaces/IAtsHold.sol";

/// @title InvoiceLending
/// @notice SMEs borrow a stablecoin against invoice tokens held in an ATS hold. The customer
///         (payer) pays the invoice into this contract; payments are applied to lenders first,
///         the surplus goes to the SME, and the ATS hold is released automatically once lenders
///         are fully repaid. If the loan is not repaid by due date + grace, the collateral can
///         be seized (hold executed) and the loss is written off against the lender pool.
///
/// Flow
///  1. SME creates a hold on the ATS invoice token naming THIS contract as `escrow`.
///  2. SME calls `requestLoan` (records the hold, invoice face value, payer, due date, principal).
///  3. Underwriter calls `fund` after off-chain/KYC checks; principal moves to the SME.
///  4. Customer calls `payInvoice`; waterfall repays the pool and releases the hold.
///  5. Anyone calls `liquidate` after due date + grace if still unpaid.
///
/// Lender pool accounting: depositors hold shares. Pool value = idle cash + outstanding
/// principal (at cost). Interest raises idle cash on repayment; defaults write off principal.
contract InvoiceLending is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant UNDERWRITER_ROLE = keccak256("UNDERWRITER_ROLE");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");

    uint256 public constant BPS = 10_000;

    enum Status {
        None,
        Requested,
        Active,
        Repaid,
        Defaulted,
        Cancelled
    }

    struct Loan {
        address borrower; // SME, holder of the invoice tokens
        address payer; // customer who owes the invoice
        address invoiceToken; // ATS token (diamond)
        bytes32 partition;
        uint256 holdId;
        uint256 collateralAmount; // tokens locked in the hold
        uint256 faceAmount; // invoice value in stablecoin units
        uint256 principal;
        uint256 interest; // flat fee fixed at funding
        uint256 repaidToLenders;
        uint256 paidByPayer;
        uint64 dueDate;
        uint64 fundedAt;
        Status status;
    }

    IERC20 public immutable stablecoin;

    // risk parameters
    uint16 public maxAdvanceBps = 8_000; // principal <= 80% of invoice face value
    uint16 public interestBps = 300; // flat fee on principal per loan
    uint64 public graceSeconds = 3 days;
    uint64 public minHoldBuffer = 1 days; // hold must outlive due date + grace by this much
    address public collateralReceiver; // receives seized collateral on default

    // lender pool
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    uint256 public idleCash;
    uint256 public outstandingPrincipal;

    // loans
    uint256 public loanCount;
    mapping(uint256 => Loan) public loans;
    mapping(bytes32 => bool) public holdInUse;

    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 amount, uint256 shares);
    event LoanRequested(uint256 indexed loanId, address indexed borrower, address indexed payer, uint256 principal, uint256 faceAmount, uint64 dueDate);
    event LoanFunded(uint256 indexed loanId, uint256 principal, uint256 interest);
    event LoanCancelled(uint256 indexed loanId);
    event InvoicePaid(uint256 indexed loanId, address indexed payer, uint256 amount, uint256 toLenders, uint256 toBorrower);
    event LoanRepaid(uint256 indexed loanId);
    event CollateralReleased(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId, uint256 writtenOff, address collateralReceiver);
    event RiskParamsUpdated(uint16 maxAdvanceBps, uint16 interestBps, uint64 graceSeconds, uint64 minHoldBuffer, address collateralReceiver);

    error ZeroAmount();
    error InvalidStatus();
    error InvalidHold();
    error HoldAlreadyUsed();
    error AdvanceTooHigh();
    error InsufficientLiquidity();
    error NotBorrower();
    error NotPayer();
    error TooEarly();
    error InvalidParams();

    constructor(address stablecoin_, address admin, address collateralReceiver_) {
        if (stablecoin_ == address(0) || admin == address(0) || collateralReceiver_ == address(0)) revert InvalidParams();
        stablecoin = IERC20(stablecoin_);
        collateralReceiver = collateralReceiver_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RISK_ADMIN_ROLE, admin);
        _grantRole(UNDERWRITER_ROLE, admin);
    }

    // ---------------------------------------------------------------- lender pool

    function totalAssets() public view returns (uint256) {
        return idleCash + outstandingPrincipal;
    }

    function previewDeposit(uint256 amount) public view returns (uint256) {
        uint256 assets = totalAssets();
        return (totalShares == 0 || assets == 0) ? amount : (amount * totalShares) / assets;
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        shares = previewDeposit(amount);
        if (shares == 0) revert ZeroAmount();
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        idleCash += amount;
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Burn `shares` for stablecoin. Limited by idle cash (the rest is lent out).
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0) revert ZeroAmount();
        amount = (shares * totalAssets()) / totalShares;
        if (amount > idleCash) revert InsufficientLiquidity();
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        idleCash -= amount;
        stablecoin.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    // ---------------------------------------------------------------- loan lifecycle

    /// @notice SME requests a loan against a hold it has already created on the invoice token.
    function requestLoan(
        address invoiceToken,
        bytes32 partition,
        uint256 holdId,
        address payer,
        uint256 faceAmount,
        uint256 principal,
        uint64 dueDate
    ) external whenNotPaused returns (uint256 loanId) {
        if (payer == address(0) || faceAmount == 0 || principal == 0 || dueDate <= block.timestamp) revert InvalidParams();
        if (principal > (faceAmount * maxAdvanceBps) / BPS) revert AdvanceTooHigh();

        bytes32 key = keccak256(abi.encode(invoiceToken, partition, msg.sender, holdId));
        if (holdInUse[key]) revert HoldAlreadyUsed();

        (uint256 amount, uint256 expiry, address escrow, , , , ) = IAtsHold(invoiceToken).getHoldForByPartition(
            IAtsHold.HoldIdentifier(partition, msg.sender, holdId)
        );
        if (amount == 0 || escrow != address(this) || expiry < uint256(dueDate) + graceSeconds + minHoldBuffer) revert InvalidHold();

        holdInUse[key] = true;
        loanId = ++loanCount;
        loans[loanId] = Loan({
            borrower: msg.sender,
            payer: payer,
            invoiceToken: invoiceToken,
            partition: partition,
            holdId: holdId,
            collateralAmount: amount,
            faceAmount: faceAmount,
            principal: principal,
            interest: 0,
            repaidToLenders: 0,
            paidByPayer: 0,
            dueDate: dueDate,
            fundedAt: 0,
            status: Status.Requested
        });
        emit LoanRequested(loanId, msg.sender, payer, principal, faceAmount, dueDate);
    }

    function cancelRequest(uint256 loanId) external {
        Loan storage l = loans[loanId];
        if (l.status != Status.Requested) revert InvalidStatus();
        if (msg.sender != l.borrower && !hasRole(UNDERWRITER_ROLE, msg.sender)) revert NotBorrower();
        l.status = Status.Cancelled;
        holdInUse[keccak256(abi.encode(l.invoiceToken, l.partition, l.borrower, l.holdId))] = false;
        // Release the collateral back to the SME. Safe: the hold was verified at request time.
        IAtsHold(l.invoiceToken).releaseHoldByPartition(
            IAtsHold.HoldIdentifier(l.partition, l.borrower, l.holdId),
            l.collateralAmount
        );
        emit LoanCancelled(loanId);
    }

    /// @notice Underwriter approves and funds a requested loan from the pool.
    function fund(uint256 loanId) external nonReentrant whenNotPaused onlyRole(UNDERWRITER_ROLE) {
        Loan storage l = loans[loanId];
        if (l.status != Status.Requested) revert InvalidStatus();
        if (l.dueDate <= block.timestamp) revert InvalidParams();
        if (l.principal > idleCash) revert InsufficientLiquidity();

        // re-verify the hold is still intact
        (uint256 amount, uint256 expiry, address escrow, , , , ) = IAtsHold(l.invoiceToken).getHoldForByPartition(
            IAtsHold.HoldIdentifier(l.partition, l.borrower, l.holdId)
        );
        if (amount != l.collateralAmount || escrow != address(this) || expiry < uint256(l.dueDate) + graceSeconds + minHoldBuffer) revert InvalidHold();

        l.interest = (l.principal * interestBps) / BPS;
        l.status = Status.Active;
        l.fundedAt = uint64(block.timestamp);
        idleCash -= l.principal;
        outstandingPrincipal += l.principal;
        stablecoin.safeTransfer(l.borrower, l.principal);
        emit LoanFunded(loanId, l.principal, l.interest);
    }

    /// @notice The customer pays the invoice. Anything the lenders are owed is applied first; the
    ///         surplus goes to the SME. When lenders are fully repaid the collateral is released.
    function payInvoice(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage l = loans[loanId];
        if (l.status != Status.Active) revert InvalidStatus();
        if (msg.sender != l.payer) revert NotPayer();
        if (amount == 0) revert ZeroAmount();

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        l.paidByPayer += amount;

        uint256 owed = l.principal + l.interest - l.repaidToLenders;
        uint256 toLenders = amount < owed ? amount : owed;
        uint256 toBorrower = amount - toLenders;

        if (toLenders > 0) {
            l.repaidToLenders += toLenders;
            // principal is returned first, then interest
            uint256 principalOutstanding = l.principal > (l.repaidToLenders - toLenders) ? l.principal - (l.repaidToLenders - toLenders) : 0;
            uint256 principalPart = toLenders < principalOutstanding ? toLenders : principalOutstanding;
            outstandingPrincipal -= principalPart;
            idleCash += toLenders; // principal + interest both become pool cash
        }
        if (toBorrower > 0) stablecoin.safeTransfer(l.borrower, toBorrower);
        emit InvoicePaid(loanId, msg.sender, amount, toLenders, toBorrower);

        if (l.repaidToLenders >= l.principal + l.interest) {
            l.status = Status.Repaid;
            holdInUse[keccak256(abi.encode(l.invoiceToken, l.partition, l.borrower, l.holdId))] = false;
            IAtsHold(l.invoiceToken).releaseHoldByPartition(
                IAtsHold.HoldIdentifier(l.partition, l.borrower, l.holdId),
                l.collateralAmount
            );
            emit LoanRepaid(loanId);
            emit CollateralReleased(loanId);
        }
    }

    /// @notice After due date + grace, anyone can seize the collateral of an unpaid loan.
    ///         Unrecovered principal is written off against the pool.
    function liquidate(uint256 loanId) external nonReentrant {
        Loan storage l = loans[loanId];
        if (l.status != Status.Active) revert InvalidStatus();
        if (block.timestamp <= uint256(l.dueDate) + graceSeconds) revert TooEarly();

        l.status = Status.Defaulted;
        uint256 principalRepaid = l.repaidToLenders > l.principal ? l.principal : l.repaidToLenders;
        uint256 writtenOff = l.principal - principalRepaid;
        outstandingPrincipal -= writtenOff;
        holdInUse[keccak256(abi.encode(l.invoiceToken, l.partition, l.borrower, l.holdId))] = false;

        IAtsHold(l.invoiceToken).executeHoldByPartition(
            IAtsHold.HoldIdentifier(l.partition, l.borrower, l.holdId),
            collateralReceiver,
            l.collateralAmount
        );
        emit LoanDefaulted(loanId, writtenOff, collateralReceiver);
    }

    // ---------------------------------------------------------------- admin

    function setRiskParams(
        uint16 maxAdvanceBps_,
        uint16 interestBps_,
        uint64 graceSeconds_,
        uint64 minHoldBuffer_,
        address collateralReceiver_
    ) external onlyRole(RISK_ADMIN_ROLE) {
        if (maxAdvanceBps_ > BPS || interestBps_ > BPS || collateralReceiver_ == address(0)) revert InvalidParams();
        maxAdvanceBps = maxAdvanceBps_;
        interestBps = interestBps_;
        graceSeconds = graceSeconds_;
        minHoldBuffer = minHoldBuffer_;
        collateralReceiver = collateralReceiver_;
        emit RiskParamsUpdated(maxAdvanceBps_, interestBps_, graceSeconds_, minHoldBuffer_, collateralReceiver_);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
