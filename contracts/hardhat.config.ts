import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";
import * as path from "path";

dotenv.config({ path: path.resolve(__dirname, "../.env") });

const key = process.env.OPERATOR_KEY;

const config: HardhatUserConfig = {
  solidity: { version: "0.8.24", settings: { viaIR: true, optimizer: { enabled: true, runs: 200 } } },
  networks: {
    "hedera-testnet": {
      url: process.env.RPC_URL || "https://testnet.hashio.io/api",
      chainId: 296,
      accounts: key ? [key] : [],
      timeout: 180_000,
    },
  },
};
export default config;
