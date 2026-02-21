/* eslint-disable no-console */
const hre = require("hardhat");

function assertAddress(label, value) {
  try {
    return hre.ethers.getAddress(value);
  } catch (e) {
    throw new Error(`${label} is not a valid address: ${value}`);
  }
}

async function main() {
  const { ethers, network } = hre;

  const initialOwnerRaw = process.env.INITIAL_OWNER;
  const btxAddressRaw = process.env.BTX_ADDRESS;

  if (!initialOwnerRaw) throw new Error("Missing env: INITIAL_OWNER");
  if (!btxAddressRaw) throw new Error("Missing env: BTX_ADDRESS");

  const initialOwner = assertAddress("INITIAL_OWNER", initialOwnerRaw);
  const btxAddress = assertAddress("BTX_ADDRESS", btxAddressRaw);

  console.log(`Network: ${network.name} (chainId: ${network.config.chainId || "unknown"})`);
  console.log(`Initial Owner: ${initialOwner}`);
  console.log(`BTX Token:     ${btxAddress}`);

  const Factory = await ethers.getContractFactory("VestingSettlementVault");
  const contract = await Factory.deploy(initialOwner, btxAddress);

  await contract.waitForDeployment();
  const addr = await contract.getAddress();

  console.log(`Deployed VestingSettlementVault: ${addr}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
