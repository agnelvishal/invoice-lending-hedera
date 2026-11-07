// Deploys InvoiceLending to Hedera testnet and records the address in ../deployments/testnet.json
// Usage: STABLECOIN_ADDRESS=0x... [COLLATERAL_RECEIVER=0x...] \
//   NODE_OPTIONS="--require ../scripts/slow-network-patch.cjs" pnpm hardhat run scripts/deploy-lending.ts --network hedera-testnet
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const FILE = path.resolve(__dirname, "../../deployments/testnet.json");

async function main() {
  const [deployer] = await ethers.getSigners();
  const stablecoin = process.env.STABLECOIN_ADDRESS;
  if (!stablecoin || !ethers.isAddress(stablecoin)) throw new Error("Set STABLECOIN_ADDRESS to the stablecoin's EVM address");
  const receiver = process.env.COLLATERAL_RECEIVER || deployer.address;

  console.log(`network=${network.name} deployer=${deployer.address}`);
  const lending = await ethers.deployContract("InvoiceLending", [stablecoin, deployer.address, receiver]);
  await lending.waitForDeployment();
  const address = await lending.getAddress();
  console.log("InvoiceLending:", address);

  console.log("Associating the contract with the stablecoin (HTS)...");
  await (await lending.associateStablecoin()).wait();

  const existing = fs.existsSync(FILE) ? JSON.parse(fs.readFileSync(FILE, "utf8")) : {};
  existing.network = "hedera-testnet";
  existing.invoiceLending = { address, stablecoin, collateralReceiver: receiver, deployer: deployer.address, deployedAt: new Date().toISOString() };
  fs.writeFileSync(FILE, JSON.stringify(existing, null, 2) + "\n");
  console.log("Saved", FILE);
}

main().catch((e) => { console.error(e); process.exit(1); });
