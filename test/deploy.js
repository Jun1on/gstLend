const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);
  GHALend = await ethers.getContractFactory("GHALend");

  USDCLend = await GHALend.deploy(0, 16);
  console.log("USDCLend deployed to:", USDCLend.address);

  await verify(USDCLend.address, [0, 16])
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

async function verify(contract, params) {
  await run("verify:verify", {
    address: contract,
    constructorArguments: params
  }).then(console.log).catch(console.log)
  console.log("VERIFIED")
}