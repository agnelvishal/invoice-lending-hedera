import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const PART = ethers.zeroPadValue("0x01", 32);
const U = (n: number) => BigInt(Math.round(n * 1e6));
const DAY = 86400;

describe("InvoiceLending", () => {
  async function setup() {
    const [admin, lender, lender2, sme, customer, treasury, other] = await ethers.getSigners();
    const usd = await ethers.deployContract("MockStable");
    const ats = await ethers.deployContract("MockAtsToken");
    const lending = await ethers.deployContract("InvoiceLending", [await usd.getAddress(), admin.address, treasury.address]);
    for (const s of [lender, lender2, customer]) await usd.mint(s.address, U(1_000_000));
    for (const s of [lender, lender2, customer]) await usd.connect(s).approve(await lending.getAddress(), ethers.MaxUint256);
    await ats.mint(PART, sme.address, 100n);
    return { admin, lender, lender2, sme, customer, treasury, other, usd, ats, lending };
  }

  async function holdAndRequest(ctx: Awaited<ReturnType<typeof setup>>, opts: { face?: number; principal?: number; amount?: bigint; days?: number; expiryExtra?: number } = {}) {
    const { ats, lending, sme, customer } = ctx;
    const days = opts.days ?? 30;
    const due = (await time.latest()) + days * DAY;
    const expiry = due + 3 * DAY + DAY + (opts.expiryExtra ?? 10);
    await ats.connect(sme).createHoldByPartition(PART, opts.amount ?? 100n, expiry, await lending.getAddress(), ethers.ZeroAddress);
    const tx = lending.connect(sme).requestLoan(await ats.getAddress(), PART, 1, customer.address, U(opts.face ?? 10_000), U(opts.principal ?? 8_000), due);
    return { tx, due };
  }

  it("runs the happy path: fund, customer pays, lenders repaid, collateral released", async () => {
    const ctx = await setup();
    const { lending, lender, sme, customer, usd, ats, admin } = ctx;
    await lending.connect(lender).deposit(U(50_000));
    const { tx } = await holdAndRequest(ctx);
    await tx;
    expect((await lending.loans(1)).status).to.equal(1n);

    await expect(lending.connect(admin).fund(1)).to.emit(lending, "LoanFunded").withArgs(1, U(8_000), U(240));
    expect(await usd.balanceOf(sme.address)).to.equal(U(8_000));
    expect(await lending.idleCash()).to.equal(U(42_000));
    expect(await lending.outstandingPrincipal()).to.equal(U(8_000));

    // customer pays full invoice face 10,000: lenders get 8,240, SME gets surplus 1,760
    await expect(lending.connect(customer).payInvoice(1, U(10_000)))
      .to.emit(lending, "InvoicePaid").withArgs(1, customer.address, U(10_000), U(8_240), U(1_760))
      .and.to.emit(lending, "CollateralReleased").withArgs(1);

    expect((await lending.loans(1)).status).to.equal(3n); // Repaid
    expect(await lending.outstandingPrincipal()).to.equal(0n);
    expect(await lending.idleCash()).to.equal(U(50_240));
    expect(await usd.balanceOf(sme.address)).to.equal(U(8_000 + 1_760));
    expect(await ats.balanceOfByPartition(PART, sme.address)).to.equal(100n); // collateral back

    // lender withdraws with profit
    const shares = await lending.sharesOf(lender.address);
    await lending.connect(lender).withdraw(shares);
    expect(await usd.balanceOf(lender.address)).to.equal(U(1_000_000 + 240));
  });

  it("applies partial payments to lenders first and releases collateral only when repaid", async () => {
    const ctx = await setup();
    const { lending, lender, customer, admin, ats, sme } = ctx;
    await lending.connect(lender).deposit(U(50_000));
    await (await holdAndRequest(ctx)).tx;
    await lending.connect(admin).fund(1);

    await lending.connect(customer).payInvoice(1, U(5_000));
    expect((await lending.loans(1)).status).to.equal(2n); // still Active
    expect(await lending.outstandingPrincipal()).to.equal(U(3_000));
    expect(await ats.balanceOfByPartition(PART, sme.address)).to.equal(0n);

    await lending.connect(customer).payInvoice(1, U(3_240));
    expect((await lending.loans(1)).status).to.equal(3n);
    expect(await lending.outstandingPrincipal()).to.equal(0n);
    expect(await ats.balanceOfByPartition(PART, sme.address)).to.equal(100n);
  });

  it("only the designated payer can pay", async () => {
    const ctx = await setup();
    const { lending, lender, other, admin } = ctx;
    await lending.connect(lender).deposit(U(50_000));
    await (await holdAndRequest(ctx)).tx;
    await lending.connect(admin).fund(1);
    await expect(lending.connect(other).payInvoice(1, U(1))).to.be.revertedWithCustomError(lending, "NotPayer");
  });

  it("liquidates after due date + grace, seizes collateral and writes off principal", async () => {
    const ctx = await setup();
    const { lending, lender, customer, admin, ats, treasury, other } = ctx;
    await lending.connect(lender).deposit(U(50_000));
    const { due } = await holdAndRequest(ctx).then(async r => (await r.tx, r));
    await lending.connect(admin).fund(1);
    await lending.connect(customer).payInvoice(1, U(1_000)); // partial

    await expect(lending.connect(other).liquidate(1)).to.be.revertedWithCustomError(lending, "TooEarly");
    await time.increaseTo(due + 3 * DAY + 1);
    await expect(lending.connect(other).liquidate(1)).to.emit(lending, "LoanDefaulted").withArgs(1, U(7_000), treasury.address);

    expect((await lending.loans(1)).status).to.equal(4n);
    expect(await ats.balanceOfByPartition(PART, treasury.address)).to.equal(100n);
    expect(await lending.outstandingPrincipal()).to.equal(0n);
    // pool: 42,000 idle + 1,000 repaid = 43,000 (7,000 loss)
    expect(await lending.totalAssets()).to.equal(U(43_000));
  });

  it("rejects bad requests", async () => {
    const ctx = await setup();
    const { lending, ats, sme, customer } = ctx;
    // advance too high (90% > 80%)
    await ats.connect(sme).createHoldByPartition(PART, 100n, (await time.latest()) + 60 * DAY, await lending.getAddress(), ethers.ZeroAddress);
    const due = (await time.latest()) + 30 * DAY;
    await expect(lending.connect(sme).requestLoan(await ats.getAddress(), PART, 1, customer.address, U(10_000), U(9_000), due)).to.be.revertedWithCustomError(lending, "AdvanceTooHigh");
    // hold with wrong escrow
    await ats.mint(PART, sme.address, 10n);
    await ats.connect(sme).createHoldByPartition(PART, 10n, (await time.latest()) + 60 * DAY, sme.address, ethers.ZeroAddress);
    await expect(lending.connect(sme).requestLoan(await ats.getAddress(), PART, 2, customer.address, U(10_000), U(8_000), due)).to.be.revertedWithCustomError(lending, "InvalidHold");
    // hold expiring too early
    await ats.mint(PART, sme.address, 10n);
    await ats.connect(sme).createHoldByPartition(PART, 10n, due, await lending.getAddress(), ethers.ZeroAddress);
    await expect(lending.connect(sme).requestLoan(await ats.getAddress(), PART, 3, customer.address, U(10_000), U(8_000), due)).to.be.revertedWithCustomError(lending, "InvalidHold");
    // nonexistent hold
    await expect(lending.connect(sme).requestLoan(await ats.getAddress(), PART, 99, customer.address, U(10_000), U(8_000), due)).to.be.revertedWithCustomError(lending, "InvalidHold");
  });

  it("does not allow the same hold to back two loans", async () => {
    const ctx = await setup();
    const { lending, ats, sme, customer } = ctx;
    const { tx, due } = await holdAndRequest(ctx);
    await tx;
    await expect(lending.connect(sme).requestLoan(await ats.getAddress(), PART, 1, customer.address, U(10_000), U(8_000), due)).to.be.revertedWithCustomError(lending, "HoldAlreadyUsed");
  });

  it("only underwriters can fund; funding needs liquidity", async () => {
    const ctx = await setup();
    const { lending, lender, sme, admin } = ctx;
    await (await holdAndRequest(ctx)).tx;
    await expect(lending.connect(sme).fund(1)).to.be.reverted; // no role
    await expect(lending.connect(admin).fund(1)).to.be.revertedWithCustomError(lending, "InsufficientLiquidity");
    await lending.connect(lender).deposit(U(8_000));
    await lending.connect(admin).fund(1);
  });

  it("cancelling a request releases the collateral", async () => {
    const ctx = await setup();
    const { lending, sme, ats } = ctx;
    await (await holdAndRequest(ctx)).tx;
    await lending.connect(sme).cancelRequest(1);
    expect(await ats.balanceOfByPartition(PART, sme.address)).to.equal(100n);
    expect((await lending.loans(1)).status).to.equal(5n);
  });

  it("associateStablecoin is a harmless no-op without the HTS precompile", async () => {
    const { lending } = await setup();
    await lending.associateStablecoin();
  });

  it("splits pool value fairly between lenders (shares)", async () => {
    const ctx = await setup();
    const { lending, lender, lender2, customer, admin } = ctx;
    await lending.connect(lender).deposit(U(30_000));
    await (await holdAndRequest(ctx)).tx;
    await lending.connect(admin).fund(1);
    await lending.connect(customer).payInvoice(1, U(10_000)); // +240 profit on 30,000
    await lending.connect(lender2).deposit(U(30_240)); // joins after profit at fair price
    expect(await lending.sharesOf(lender2.address)).to.equal(U(30_000));
  });
});
