# Invoice Collateral Lending on Hedera

Small and medium businesses (SMEs) lock **tokenized invoices** as collateral, borrow **stablecoins**, and when the customer pays the invoice, lenders are repaid and the collateral is released automatically. Everything runs on **Hedera testnet**.

Built on two open-source Hedera toolkits:

- [Asset Tokenization Studio (ATS)](https://github.com/hashgraph/asset-tokenization-studio): invoice tokens (bond type), KYC and allowlists, holds (escrow), partial freeze.
- [Stablecoin Studio](https://github.com/hashgraph/stablecoin-studio): the stablecoin used for lending and repayment (HTS token with cash-in/burn roles).

Neither toolkit includes lending logic. The loan contract and the payment settlement are the custom parts of this project.

## Status

Early development. Nothing is deployed yet.

| Step | State |
|---|---|
| Testnet operator account | Done (ECDSA account, funded) |
| ATS and Stablecoin Studio cloned as references (`repos/`) | Done |
| ATS dependencies installed | In progress |
| ATS contracts built and deployed to testnet | Not started |
| Stablecoin Studio factory and stablecoin on testnet | Not started |
| Loan / escrow contract | Not started |
| Backend indexer | Not started |
| Web app (SME, lender, customer views) | Not started |

## How it works

```
 SME ──issues──▶ Invoice bond token (ATS) ──────────────┐
  │                                                      │ locked in an ATS hold
  │ opens loan                                           ▼
  ▼                                              ┌────────────────┐
 Loan contract ◀──── lenders fund pool ────────▶ │ Stablecoin pool │ (Stablecoin Studio token)
  │                                              └────────────────┘
  │ SME draws stablecoin
  ▼
 Customer pays invoice ──▶ Repayment escrow ──▶ Loan contract settles:
                                                 1. lenders get principal + interest
                                                 2. SME gets any surplus
                                                 3. ATS hold is released
 No payment by due date ──▶ lenders claim the collateral (hold is executed)
```

1. The SME issues an invoice as an ATS bond token. Only KYC-approved holders can own it.
2. The SME opens a loan. The invoice tokens go into an ATS hold controlled by the loan contract.
3. Lenders deposit stablecoin into the pool. The SME draws the loan.
4. The customer pays the stablecoin into the loan's repayment escrow.
5. Settlement is automatic and on-chain: lenders are repaid, any surplus goes to the SME, and the hold is released.
6. If the invoice is not paid by its due date, lenders can claim the collateral.

### Design decisions

- **Payment trigger:** payment into the on-chain repayment escrow. Confirming a payment made off-chain would need an oracle or attested operator, which would be added later as a pluggable adapter.
- **Collateral:** ATS bond tokens with holds, not plain NFTs, so compliance rules (KYC, allowlists) apply to invoice tokens.
- **Network:** testnet only. No real funds.

## Planned stack

- Solidity contracts with Hardhat
- TypeScript scripts and backend
- React web app
- Hedera Mirror Node for reads and event indexing

## Repository layout

```
.
├── README.md
├── .env                 # testnet credentials (gitignored, never commit)
├── repos/
│   ├── ats/             # Asset Tokenization Studio (reference clone)
│   └── sc/              # Stablecoin Studio (reference clone)
└── deployments/         # deployed testnet addresses (planned)
```

Application code (contracts, backend, web) will be added as the project progresses.

## Setup

Requirements: Node.js 20+, npm 10+ (provided by `corepack`), and a Hedera testnet account (get one at https://portal.hedera.com).

Create `.env` in the project root (gitignored):

```
HEDERA_NETWORK=testnet
OPERATOR_ID=0.0.xxxxxxx
OPERATOR_EVM_ADDRESS=0x...
OPERATOR_KEY=0x...        # ECDSA private key
RPC_URL=https://testnet.hashio.io/api
MIRROR_URL=https://testnet.mirrornode.hedera.com
```

ATS reads its own key from `repos/ats/packages/ats/contracts/.env` as `HEDERA_TESTNET_PRIVATE_KEY_0`.

Install and build ATS contracts:

```bash
cd repos/ats && npm ci
cd packages/ats/contracts && npm run build
```

Deploy ATS to testnet (spends testnet HBAR):

```bash
npm run deploy:newBlr:hedera:testnet
```

## Security

- Testnet keys only. Do not reuse a testnet key on mainnet.
- `.env` files are gitignored. Never commit private keys.
- The loan contract is unaudited. ATS includes powerful controller functions (forced transfer and redemption); see its README before granting those roles to any contract.

## License

Apache-2.0 (matching the upstream toolkits). Update this when the project's own license is decided.
