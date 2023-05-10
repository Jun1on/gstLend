const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe('Tests', () => {
  beforeEach(async () => {
    [owner, signer2, signer3, signer4, signer5] = await ethers.getSigners();

    const USDC_WHALE = "0x0fd6f65d35cf13ae51795036d0ae9af42f3cbcb4"
    const USDC_ADDRESS = "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8"

    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [USDC_WHALE],
    });
  
    whale = await ethers.getSigner(USDC_WHALE);
    usdc = await ethers.getContractAt("contracts/GMDvault.sol:IERC20", USDC_ADDRESS);
    gmdUSDC = await ethers.getContractAt("contracts/GMDvault.sol:IERC20", "0x3DB4B7DA67dd5aF61Cb9b3C70501B1BdB24b2C22");
    
    GstLend = await ethers.getContractFactory("GSTLend");
    USDCLend = await GstLend.deploy();
    await USDCLend.initialize(0);
    //ETHLend = await GstLend.deploy();
    //await ETHLend.initialize(1);

    await usdc.connect(whale).approve(USDCLend.address, e("1000", 6));
    await gmdUSDC.connect(whale).approve(USDCLend.address, e("1000", 18));
    });


    describe("gstLend", function () {
        it("Should work with one account", async function () {
          // deposit 2 gmdUSDC
          await USDCLend.connect(whale).depositGmd(e("2", 18))
          let gmdDeposits = await USDCLend.gmdDeposits(whale.address)
          expect(gmdDeposits).to.equal(e("2", 18))
          // withdraw 1 gmdUSDC
          await USDCLend.connect(whale).withdrawGmd(e("1", 18))
          gmdDeposits = await USDCLend.gmdDeposits(whale.address)
          expect(gmdDeposits).to.equal(e("1", 18))

          // deposit 2 USDC
          await USDCLend.connect(whale).deposit(e("2", 6))
          let xdeposits = await USDCLend.xdeposits(whale.address)
          expect(xdeposits).to.equal(e("2", 18))
          // withdraw 1 USDC
          await USDCLend.connect(whale).withdraw(e("1", 6))
          xdeposits = await USDCLend.xdeposits(whale.address)
          expect(xdeposits).to.equal(e("1", 18))

          // borrow 0.8 USDC
          await USDCLend.connect(whale).borrow(e("0.8", 6))
          logBlock()
          let xborrows = await USDCLend.xborrows(whale.address)
          expect(xborrows).to.equal(e("0.8", 18))
          
          // utilization ratio is 80%
          expect(await USDCLend.totalBorrows()).to.equal(e("0.8", 17)+1)
          expect(await USDCLend.totalDeposits()).to.equal(e("1", 17)+1)
          // borrow APR is 10%
          await expect(await USDCLend.borrowAPR()).to.equal(e("0.1", 18))

          // borrow 0.05 USDC
          await USDCLend.connect(whale).borrow(e("0.05", 6))
          // borrowing 0.05 USDC fails
          await expect(USDCLend.connect(whale).borrow(e("0.05", 6))).to.be.revertedWith("GSTLend: Insufficient collateral")

          // utilization ratio is 85% => borrow APR is 15% (slightly above 15% bc of interest)
          // borrow APR is now min(gmdUSDC APR, APR)
          console.log("APR: "+await USDCLend.borrowAPR())

          await USDCLend.connect(whale).repay(e("0.8", 6))

          // utilization ratio is 5% => borrow APR is 2.5% (slightly above bc of interest)
          console.log("APR: "+await USDCLend.borrowAPR())

          console.log("TB",await USDCLend.totalBorrows())
          // repay all
          await USDCLend.connect(whale).repay(e("99999", 6))

          // utilization ratio is 0% => borrow APR is 2%
          console.log("APR: "+await USDCLend.borrowAPR())

          logBlock()
          console.log("TB",await USDCLend.totalBorrows())
          console.log("TxB",await USDCLend.totalxBorrows())

          // zero borrows
          xborrows = await USDCLend.xborrows(whale.address)
          expect(xborrows).to.equal(0)

          // treasury accrues fees
          console.log("Treasury fees: "+await USDCLend.xdeposits("0x03851F30cC29d86EE87a492f037B16642838a357"))
        });
    });
})

function e(amount, decimals) {
  return ethers.utils.parseUnits(amount, decimals)
}
async function logBlock() {
  console.log("block #"+await time.latestBlock());
}